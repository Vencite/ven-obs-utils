import Foundation

private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

final class ServiceController {
    private(set) var process: Process?
    var onStarted: (() -> Void)?
    private var restartRequested = false
    var environment: [String: String] = [:]
    private var shouldRun = true
    private let serviceURL: URL
    private let configURL: URL
    private let logURL: URL
    private let servicePort: Int
    private let onFailure: (Int32) -> Void
    private let onStaleHelperStopped: (Int32) -> Void

    init(
        serviceURL: URL,
        configURL: URL,
        logURL: URL,
        servicePort: Int,
        onFailure: @escaping (Int32) -> Void,
        onStaleHelperStopped: @escaping (Int32) -> Void
    ) {
        self.serviceURL = serviceURL
        self.configURL = configURL
        self.logURL = logURL
        self.servicePort = servicePort
        self.onFailure = onFailure
        self.onStaleHelperStopped = onStaleHelperStopped
    }

    func start() {
        shouldRun = true
        guard process?.isRunning != true else { return }

        if let stalePID = StaleHelperCleanup.terminateManagedHelperListening(
            on: servicePort,
            configURL: configURL
        ) {
            onStaleHelperStopped(stalePID)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        let command = "exec python3 \(shellQuote(serviceURL.path)) --config \(shellQuote(configURL.path)) >> \(shellQuote(logURL.path)) 2>&1"
        process.arguments = ["-lc", command]
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            DispatchQueue.main.async {
                guard self.process === process else { return }
                self.process = nil
                if self.restartRequested && self.shouldRun {
                    self.restartRequested = false
                    self.start()
                } else if ServiceRestartPolicy.shouldRestart(
                    shouldRun: self.shouldRun,
                    terminationStatus: process.terminationStatus
                ) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        guard self.shouldRun, self.process == nil else { return }
                        self.start()
                    }
                } else if self.shouldRun {
                    self.onFailure(process.terminationStatus)
                }
            }
        }

        do {
            try process.run()
            self.process = process
            onStarted?()
        } catch {
            self.process = nil
        }
    }

    func restart() {
        shouldRun = true
        if let process, process.isRunning {
            restartRequested = true
            process.terminate()
        } else {
            restartRequested = false
            self.process = nil
            start()
        }
    }

    func stop() {
        restartRequested = false
        shouldRun = false
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
    }
}
