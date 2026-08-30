import AppKit
import Foundation

private let appName = "VEN OBS Utils"
private let defaultPort = 8765

private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

final class ServiceController {
    private(set) var process: Process?
    private var shouldRun = true
    private let serviceURL: URL
    private let configURL: URL
    private let logURL: URL

    init(serviceURL: URL, configURL: URL, logURL: URL) {
        self.serviceURL = serviceURL
        self.configURL = configURL
        self.logURL = logURL
    }

    func start() {
        shouldRun = true
        guard process?.isRunning != true else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        let command = "exec python3 \(shellQuote(serviceURL.path)) --config \(shellQuote(configURL.path)) >> \(shellQuote(logURL.path)) 2>&1"
        process.arguments = ["-lc", command]
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async {
                self.process = nil
                if self.shouldRun {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        self.start()
                    }
                }
            }
        }

        do {
            try process.run()
            self.process = process
        } catch {
            self.process = nil
        }
    }

    func restart() {
        shouldRun = false
        if let process, process.isRunning {
            process.terminate()
        }
        self.process = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.shouldRun = true
            self.start()
        }
    }

    func stop() {
        shouldRun = false
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var service: ServiceController?
    private let obsClient = OBSWebSocketClient()
    private var settingsController: SettingsWindowController?
    private var currentConfig: AppConfig?
    private var automationRequests = AutomationRequestSequence()

    private var obsConnected = false
    private var ontimeConnected = false
    private var currentOntimeCue: String?
    private var transientIconActive = false
    private var transientIconGeneration = 0

    private let serviceStatusItem = NSMenuItem(title: "Service: starting…", action: nil, keyEquivalent: "")
    private let obsStatusItem = NSMenuItem(title: "OBS: connecting…", action: nil, keyEquivalent: "")
    private let ontimeStatusItem = NSMenuItem(title: "Ontime: checking…", action: nil, keyEquivalent: "")
    private let modeItem = NSMenuItem(title: "Mode: -", action: nil, keyEquivalent: "")
    private let programItem = NSMenuItem(title: "Program: -", action: nil, keyEquivalent: "")
    private let ontimeEventItem = NSMenuItem(title: "Ontime event: -", action: nil, keyEquivalent: "")
    private let lastActionItem = NSMenuItem(title: "Last action: -", action: nil, keyEquivalent: "")

    private lazy var supportDirectory: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(appName, isDirectory: true)
    }()

    private var configURL: URL { supportDirectory.appendingPathComponent("config.json") }
    private var logURL: URL { supportDirectory.appendingPathComponent("ven-obs-utils.log") }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupMenu()
        setupOBSCallbacks()

        do {
            try prepareSupportFiles()
            currentConfig = try AppConfig.load(from: configURL)
        } catch {
            serviceStatusItem.title = "Service: setup error"
            lastActionItem.title = "Last action: config error"
            appendLog("startup config error=\(error.localizedDescription)")
            updateBaseIcon()
            return
        }

        guard
            let serviceURL = Bundle.main.resourceURL?.appendingPathComponent("services/ontime_break_sync.py"),
            FileManager.default.fileExists(atPath: serviceURL.path)
        else {
            serviceStatusItem.title = "Service: file missing"
            appendLog("startup service_file_missing")
            updateBaseIcon()
            return
        }

        service = ServiceController(serviceURL: serviceURL, configURL: configURL, logURL: logURL)

        do {
            _ = try currentConfig?.validated()
            service?.start()
            configureOBS()
        } catch {
            serviceStatusItem.title = "Service: config invalid"
            lastActionItem.title = "Last action: fix Settings"
            appendLog("startup validation_error=\(error.localizedDescription)")
        }

        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshStatus()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.refreshStatus()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        obsClient.stop()
        service?.stop()
    }

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setIcon(state: .warning, tooltip: appName)

        let menu = NSMenu()
        let header = NSMenuItem(title: appName, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        for item in [serviceStatusItem, obsStatusItem, ontimeStatusItem, modeItem, programItem, ontimeEventItem, lastActionItem] {
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Restart Service", action: #selector(restartService), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Open Logs", action: #selector(openLogs), keyEquivalent: "l"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit VEN OBS Utils", action: #selector(quitApp), keyEquivalent: "q"))

        for item in menu.items where item.action != nil {
            item.target = self
        }
        statusItem.menu = menu
    }

    private func setupOBSCallbacks() {
        obsClient.onStatusChange = { [weak self] status in
            guard let self else { return }
            switch status {
            case .connected:
                self.obsConnected = true
                self.obsStatusItem.title = "OBS: connected"
            case .connecting:
                self.obsConnected = false
                self.obsStatusItem.title = "OBS: connecting…"
                self.programItem.title = "Program: waiting…"
            case .disconnected:
                self.obsConnected = false
                self.obsStatusItem.title = "OBS: disconnected"
                self.programItem.title = "Program: unavailable"
            case .authenticationRequired:
                self.obsConnected = false
                self.obsStatusItem.title = "OBS: password required"
                self.programItem.title = "Program: unavailable"
            }
            self.updateBaseIcon()
        }

        obsClient.onProgramScene = { [weak self] scene in
            self?.programItem.title = "Program: \(scene)"
        }

        obsClient.onTransition = { [weak self] transition in
            self?.handleOBSProgramTransition(transition)
        }

        obsClient.onError = { [weak self] message in
            self?.appendLog("obs error=\(message)")
        }
    }

    private func prepareSupportFiles() throws {
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)

        if !FileManager.default.fileExists(atPath: configURL.path) {
            guard let defaultConfig = Bundle.main.resourceURL?.appendingPathComponent("default-config.json") else {
                throw NSError(domain: "VENOBSUtils", code: 1)
            }
            try FileManager.default.copyItem(at: defaultConfig, to: configURL)
        }

        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
    }

    private func configureOBS() {
        guard let config = currentConfig else { return }
        let password: String
        do {
            password = try KeychainStore.obsPassword.read() ?? ""
        } catch {
            obsStatusItem.title = "OBS: Keychain error"
            appendLog("keychain read_error=\(error.localizedDescription)")
            obsConnected = false
            updateBaseIcon()
            return
        }

        obsClient.start(settings: OBSWebSocketSettings(
            host: config.obsHost,
            port: config.obsPort,
            password: password,
            breakPattern: config.obsBreakSceneRegex,
            reconnectSeconds: config.obsReconnectSeconds
        ))
    }

    private func handleOBSProgramTransition(_ transition: ProgramSceneTransition) {
        guard let config = currentConfig else { return }
        appendLog(
            "obs_transition previous=\(transition.previous) current=\(transition.current) action=\(transition.action.rawValue) eventNow=\(currentOntimeCue ?? "unknown")"
        )

        guard let path = OntimeAutomationRoute.path(
            for: transition.action,
            enterEnabled: config.enterBreakEnabled,
            leaveEnabled: config.leaveBreakEnabled
        ) else {
            appendLog("automation ignored reason=no_route_or_disabled")
            return
        }

        triggerOntime(path: path, transition: transition)
    }

    private func triggerOntime(path: String, transition: ProgramSceneTransition) {
        let request = AutomationRequest(path: path, transition: transition)
        if let next = automationRequests.enqueue(request) {
            startAutomationRequest(next)
        } else {
            appendLog(
                "automation queued from_scene=\(transition.previous) to_scene=\(transition.current) action=\(transition.action.rawValue)"
            )
        }
    }

    private func startAutomationRequest(_ queued: AutomationRequest) {
        guard let config = currentConfig,
              let url = URL(string: "http://127.0.0.1:\(config.serverPort)\(queued.path)") else {
            lastActionItem.title = "Last action: invalid local helper URL"
            appendLog("automation result=error reason=invalid_local_helper_url")
            flashIcon(state: .failure, duration: 2.0)
            finishAutomationRequest()
            return
        }

        showWorkingIcon()
        var request = URLRequest(url: url)
        request.timeoutInterval = max(1.0, config.requestTimeoutSeconds + 0.5)
        request.cachePolicy = .reloadIgnoringLocalCacheData

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.handleAutomationResponse(
                    data: data,
                    response: response,
                    error: error,
                    transition: queued.transition
                )
                self.finishAutomationRequest()
            }
        }.resume()
    }

    private func finishAutomationRequest() {
        guard let next = automationRequests.finishCurrent() else { return }
        startAutomationRequest(next)
    }

    private func handleAutomationResponse(
        data: Data?,
        response: URLResponse?,
        error: Error?,
        transition: ProgramSceneTransition
    ) {
        if let error {
            lastActionItem.title = "Last action: error"
            appendLog("automation result=error detail=\(error.localizedDescription)")
            flashIcon(state: .failure, duration: 2.0)
            return
        }

        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            lastActionItem.title = "Last action: invalid helper response"
            appendLog("automation result=error reason=invalid_helper_response")
            flashIcon(state: .failure, duration: 2.0)
            return
        }

        let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
        let status = json["status"] as? String ?? "error"
        let cue = json["cue"] as? String ?? ""
        let fromCue = json["from_cue"] as? String ?? ""
        let eventID = json["event_id"] as? String ?? ""
        let reason = json["reason"] as? String ?? ""

        appendLog(
            "automation from_scene=\(transition.previous) to_scene=\(transition.current) action=\(transition.action.rawValue) status=\(status) from_cue=\(fromCue) cue=\(cue) event_id=\(eventID) reason=\(reason) http=\(httpStatus)"
        )

        switch status {
        case "started":
            if transition.action == .leaveBreak, !fromCue.isEmpty {
                lastActionItem.title = "Last action: left \(fromCue) → started \(cue)"
            } else {
                lastActionItem.title = "Last action: started \(cue)"
            }
            flashIcon(state: .success, duration: 1.5)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.refreshStatus()
            }

        case "dry_run":
            lastActionItem.title = cue.isEmpty
                ? "Last action: DRY RUN"
                : "Last action: DRY RUN → \(cue)"
            clearTransientIcon()

        case "ignored":
            lastActionItem.title = reason.isEmpty
                ? "Last action: ignored"
                : "Last action: ignored (\(reason))"
            clearTransientIcon()

        default:
            lastActionItem.title = reason.isEmpty
                ? "Last action: error"
                : "Last action: error (\(reason))"
            flashIcon(state: .failure, duration: 2.0)
        }
    }

    private func configuredPort() -> Int {
        currentConfig?.serverPort ?? defaultPort
    }

    private func refreshStatus() {
        guard let url = URL(string: "http://127.0.0.1:\(configuredPort())/status") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.4
        request.cachePolicy = .reloadIgnoringLocalCacheData

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self else { return }
            guard error == nil, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                DispatchQueue.main.async {
                    self.serviceStatusItem.title = "Service: unavailable"
                    self.ontimeStatusItem.title = "Ontime: unknown"
                    self.ontimeEventItem.title = "Ontime event: -"
                    self.ontimeConnected = false
                    self.currentOntimeCue = nil
                    self.updateBaseIcon()
                }
                return
            }

            DispatchQueue.main.async {
                self.applyStatus(json)
            }
        }.resume()
    }

    private func applyStatus(_ json: [String: Any]) {
        let ontime = json["ontime"] as? String ?? "unknown"
        let version = json["ontime_version"] as? String ?? ""
        let mode = json["mode"] as? String ?? "unknown"

        serviceStatusItem.title = "Service: running"
        modeItem.title = "Mode: " + (mode == "live" ? "LIVE" : "DRY RUN")
        ontimeConnected = ontime == "connected"

        if ontimeConnected {
            ontimeStatusItem.title = version.isEmpty
                ? "Ontime: connected"
                : "Ontime: connected (\(version))"
        } else {
            ontimeStatusItem.title = "Ontime: disconnected"
        }

        if let event = json["ontime_event"] as? [String: Any] {
            let cue = event["cue"] as? String ?? ""
            let title = event["title"] as? String ?? ""
            currentOntimeCue = cue.isEmpty ? nil : cue
            if !cue.isEmpty && !title.isEmpty {
                ontimeEventItem.title = "Ontime event: \(cue) - \(title)"
            } else if !cue.isEmpty {
                ontimeEventItem.title = "Ontime event: \(cue)"
            } else if !title.isEmpty {
                ontimeEventItem.title = "Ontime event: \(title)"
            } else {
                ontimeEventItem.title = "Ontime event: -"
            }
        } else {
            currentOntimeCue = nil
            ontimeEventItem.title = "Ontime event: -"
        }

        if let last = json["last_action"] as? [String: Any] {
            let action = last["action"] as? String ?? ""
            let status = last["status"] as? String ?? "-"
            let cue = last["cue"] as? String ?? ""
            let fromCue = last["from_cue"] as? String ?? ""
            let reason = last["reason"] as? String ?? ""

            if action == "leave_break", !fromCue.isEmpty, !cue.isEmpty {
                lastActionItem.title = "Last action: left \(fromCue) → \(status) \(cue)"
            } else if !cue.isEmpty {
                lastActionItem.title = "Last action: \(status) \(cue)"
            } else if !reason.isEmpty {
                lastActionItem.title = "Last action: \(status) (\(reason))"
            }
        }

        updateBaseIcon()
    }

    private func setIcon(state: StatusPresentationState, tooltip: String) {
        guard let button = statusItem?.button else { return }
        // Force dark menu-bar appearance so the template icon always renders
        // white, regardless of the user's system light/dark mode.
        button.appearance = NSAppearance(named: .darkAqua)
        let symbol = StatusPresentation.symbolName(for: state)
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: appName) {
            image.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
            button.title = ""
        } else {
            button.image = nil
            button.title = "●"
        }

        switch state {
        case .ready:
            button.contentTintColor = nil
        case .warning:
            button.contentTintColor = .systemOrange
        case .working:
            button.contentTintColor = .systemBlue
        case .success:
            button.contentTintColor = .systemGreen
        case .failure:
            button.contentTintColor = .systemRed
        }
        button.toolTip = tooltip
    }

    private func updateBaseIcon() {
        guard !transientIconActive else { return }
        let state = StatusPresentation.baseState(
            obsConnected: obsConnected,
            ontimeConnected: ontimeConnected
        )
        let tooltip = state == .ready
            ? "VEN OBS Utils - OBS and Ontime connected"
            : "VEN OBS Utils - connection warning"
        setIcon(state: state, tooltip: tooltip)
    }

    private func showWorkingIcon() {
        transientIconGeneration += 1
        transientIconActive = true
        setIcon(state: .working, tooltip: "VEN OBS Utils - sending to Ontime")
    }

    private func flashIcon(state: StatusPresentationState, duration: TimeInterval) {
        transientIconGeneration += 1
        let generation = transientIconGeneration
        transientIconActive = true
        let tooltip = state == .success
            ? "VEN OBS Utils - Ontime updated"
            : "VEN OBS Utils - Ontime action failed"
        setIcon(state: state, tooltip: tooltip)

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.transientIconGeneration == generation else { return }
            self.transientIconActive = false
            self.updateBaseIcon()
        }
    }

    private func clearTransientIcon() {
        transientIconGeneration += 1
        transientIconActive = false
        updateBaseIcon()
    }

    private func appendLog(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "\(timestamp) APP \(message)\n".data(using: .utf8) else { return }
        do {
            let handle = try FileHandle(forWritingTo: logURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            // Logging must never affect live automation.
        }
    }

    private func saveSettings(_ draft: SettingsDraft) throws {
        guard let existing = currentConfig else {
            throw SettingsDraftError(field: .general, message: "Cannot load current config")
        }

        let applied = try draft.applying(to: existing)
        let keychain = KeychainStore.obsPassword
        let previousPassword = try keychain.read() ?? ""

        do {
            try keychain.write(applied.password)
            do {
                try applied.config.writeAtomically(to: configURL)
            } catch {
                try? keychain.write(previousPassword)
                throw error
            }
        } catch let error as SettingsDraftError {
            throw error
        } catch {
            throw SettingsDraftError(field: .general, message: error.localizedDescription)
        }

        currentConfig = applied.config
        modeItem.title = applied.config.dryRun ? "Mode: DRY RUN" : "Mode: LIVE"
        serviceStatusItem.title = "Service: restarting…"
        service?.restart()
        configureOBS()
        appendLog("settings saved service_restart=true obs_reconnect=true")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            self?.refreshStatus()
        }
    }

    @objc private func showSettings() {
        do {
            let config = try AppConfig.load(from: configURL)
            currentConfig = config
            let password = try KeychainStore.obsPassword.read() ?? ""
            let draft = SettingsDraft(config: config, password: password)
            let controller = SettingsWindowController(
                draft: draft,
                onSave: { [weak self] draft in
                    guard let self else { return }
                    try self.saveSettings(draft)
                },
                onOpenConfig: { [weak self] in
                    guard let self else { return }
                    NSWorkspace.shared.open(self.configURL)
                }
            )
            settingsController = controller
            controller.present()
        } catch {
            appendLog("settings open_error=\(error.localizedDescription)")
            let alert = NSAlert()
            alert.messageText = "Cannot open Settings"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func restartService() {
        serviceStatusItem.title = "Service: restarting…"
        service?.restart()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.refreshStatus()
        }
    }

    @objc private func openLogs() {
        NSWorkspace.shared.open(logURL)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

@main
@MainActor
struct VENOBSUtilsApplication {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
