import Foundation

enum OBSWebSocketEndpointError: LocalizedError {
    case invalidHost

    var errorDescription: String? {
        switch self {
        case .invalidHost: return "OBS host is invalid"
        }
    }
}

enum OBSWebSocketEndpoint {
    static func makeURL(host: String, port: Int) throws -> URL {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OBSWebSocketEndpointError.invalidHost }

        var components = URLComponents()
        components.scheme = "ws"
        components.host = trimmed
        components.port = port
        guard let url = components.url else { throw OBSWebSocketEndpointError.invalidHost }
        return url
    }
}

enum OntimeAutomationRoute {
    static func path(
        for action: SceneTransitionAction,
        enterEnabled: Bool,
        leaveEnabled: Bool
    ) -> String? {
        switch action {
        case .enterBreak:
            return enterEnabled ? "/ontime/break" : nil
        case .leaveBreak:
            return leaveEnabled ? "/ontime/leave-break" : nil
        case .ignore:
            return nil
        }
    }
}

enum OBSConnectionStatus: Equatable {
    case disconnected
    case connecting
    case connected
    case authenticationRequired
}

struct OBSWebSocketSettings {
    let host: String
    let port: Int
    let password: String
    let breakPattern: String
    let reconnectSeconds: Double
}

@MainActor
final class OBSWebSocketClient {
    var onStatusChange: ((OBSConnectionStatus) -> Void)?
    var onProgramScene: ((String) -> Void)?
    var onTransition: ((ProgramSceneTransition) -> Void)?
    var onError: ((String) -> Void)?

    private var settings: OBSWebSocketSettings?
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var stateMachine = OBSConnectionStateMachine()
    private var generation = 0
    private var shouldRun = false

    func start(settings: OBSWebSocketSettings) {
        stop()
        self.settings = settings
        shouldRun = true
        connect()
    }

    func stop() {
        shouldRun = false
        generation += 1
        reconnectTask?.cancel()
        reconnectTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        stateMachine.resetForReconnect()
        onStatusChange?(.disconnected)
    }

    private func connect() {
        guard shouldRun, let settings else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        stateMachine.resetForReconnect()

        let url: URL
        do {
            url = try OBSWebSocketEndpoint.makeURL(host: settings.host, port: settings.port)
        } catch {
            onError?(error.localizedDescription)
            onStatusChange?(.disconnected)
            scheduleReconnect()
            return
        }

        generation += 1
        let currentGeneration = generation
        onStatusChange?(.connecting)

        var request = URLRequest(url: url)
        request.setValue("obswebsocket.json", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        let socket = URLSession.shared.webSocketTask(with: request)
        self.socket = socket
        socket.resume()

        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let message = try await socket.receive()
                    guard self.generation == currentGeneration, self.shouldRun else { return }
                    switch message {
                    case .string(let text):
                        try self.handleMessage(text, generation: currentGeneration)
                    case .data(let data):
                        guard let text = String(data: data, encoding: .utf8) else {
                            throw OBSProtocolError.invalidMessage("OBS sent non-UTF8 binary data")
                        }
                        try self.handleMessage(text, generation: currentGeneration)
                    @unknown default:
                        throw OBSProtocolError.invalidMessage("OBS sent an unsupported WebSocket message")
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard self.generation == currentGeneration, self.shouldRun else { return }
                    self.handleDisconnect(error.localizedDescription, generation: currentGeneration)
                    return
                }
            }
        }
    }

    private func handleMessage(_ text: String, generation: Int) throws {
        guard self.generation == generation, let settings else { return }
        let message = try OBSProtocolCodec.parse(text)
        let commands = try stateMachine.handle(
            message,
            password: settings.password,
            breakPattern: settings.breakPattern
        )
        execute(commands, generation: generation)
    }

    private func execute(_ commands: [OBSConnectionCommand], generation: Int) {
        guard self.generation == generation else { return }
        for command in commands {
            switch command {
            case .identify(let rpcVersion, let authentication):
                do {
                    let text = try OBSProtocolCodec.identifyJSON(
                        rpcVersion: rpcVersion,
                        authentication: authentication
                    )
                    send(text, generation: generation)
                } catch {
                    handleDisconnect(error.localizedDescription, generation: generation)
                    return
                }

            case .requestBaseline(let requestId):
                do {
                    let text = try OBSProtocolCodec.requestJSON(
                        requestType: "GetCurrentProgramScene",
                        requestId: requestId
                    )
                    send(text, generation: generation)
                } catch {
                    handleDisconnect(error.localizedDescription, generation: generation)
                    return
                }

            case .connected(let scene):
                onStatusChange?(.connected)
                onProgramScene?(scene)

            case .transition(let transition):
                onProgramScene?(transition.current)
                onTransition?(transition)

            case .authenticationRequired:
                onStatusChange?(.authenticationRequired)
                onError?("OBS WebSocket requires a password")
                receiveTask?.cancel()
                receiveTask = nil
                socket?.cancel(with: .policyViolation, reason: nil)
                socket = nil
                generation += 1
                return
            }
        }
    }

    private func send(_ text: String, generation: Int) {
        guard let socket, self.generation == generation else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await socket.send(.string(text))
            } catch {
                guard self.generation == generation, self.shouldRun else { return }
                self.handleDisconnect(error.localizedDescription, generation: generation)
            }
        }
    }

    private func handleDisconnect(_ message: String, generation: Int) {
        guard self.generation == generation else { return }
        self.generation += 1
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        stateMachine.resetForReconnect()
        onStatusChange?(.disconnected)
        onError?(message)
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard shouldRun, let settings else { return }
        reconnectTask?.cancel()
        let delay = max(0.25, settings.reconnectSeconds)
        reconnectTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }
            guard let self, self.shouldRun else { return }
            self.connect()
        }
    }
}
