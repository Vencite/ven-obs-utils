import Foundation

enum OBSConnectionCommand: Equatable {
    case identify(rpcVersion: Int, authentication: String?)
    case requestBaseline(requestId: String)
    case connected(scene: String)
    case transition(ProgramSceneTransition)
    case authenticationRequired
}

struct OBSConnectionStateMachine {
    private var tracker = OBSProgramSceneTracker()
    private var baselineRequestId: String?
    private var baselineReady = false

    mutating func resetForReconnect() {
        tracker.resetForReconnect()
        baselineRequestId = nil
        baselineReady = false
    }

    mutating func handle(
        _ message: OBSProtocolMessage,
        password: String,
        breakPattern: String
    ) throws -> [OBSConnectionCommand] {
        switch message {
        case .hello(let rpcVersion, let challenge, let salt):
            if let challenge, let salt {
                guard !password.isEmpty else {
                    return [.authenticationRequired]
                }
                let authentication = OBSProtocolCodec.authentication(
                    password: password,
                    salt: salt,
                    challenge: challenge
                )
                return [.identify(rpcVersion: rpcVersion, authentication: authentication)]
            }
            return [.identify(rpcVersion: rpcVersion, authentication: nil)]

        case .identified:
            let requestId = "baseline-\(UUID().uuidString)"
            baselineRequestId = requestId
            baselineReady = false
            tracker.resetForReconnect()
            return [.requestBaseline(requestId: requestId)]

        case .requestResponse(let requestType, let requestId, let success, let responseData):
            guard requestType == "GetCurrentProgramScene",
                  requestId == baselineRequestId,
                  success,
                  let scene = OBSProtocolCodec.programSceneName(from: responseData) else {
                return []
            }
            _ = try tracker.receive(scene: scene, pattern: breakPattern)
            baselineReady = true
            return [.connected(scene: scene)]

        case .programSceneChanged(let scene):
            guard baselineReady else { return [] }
            guard let transition = try tracker.receive(scene: scene, pattern: breakPattern) else {
                return []
            }
            return [.transition(transition)]

        case .ignored:
            return []
        }
    }
}
