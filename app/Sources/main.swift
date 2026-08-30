import AppKit
import Foundation

private let appName = "VEN OBS Utils"
private let defaultPort = 8765

private func shellQuote(_ value: String) -> String {
    return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var service: ServiceController?

    private let serviceStatusItem = NSMenuItem(title: "Service: starting…", action: nil, keyEquivalent: "")
    private let ontimeStatusItem = NSMenuItem(title: "Ontime: checking…", action: nil, keyEquivalent: "")
    private let modeItem = NSMenuItem(title: "Mode: -", action: nil, keyEquivalent: "")
    private let patternItem = NSMenuItem(title: "Break pattern: -", action: nil, keyEquivalent: "")
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

        do {
            try prepareSupportFiles()
        } catch {
            setStatus(symbol: "!", tooltip: "Cannot prepare application files")
            serviceStatusItem.title = "Service: setup error"
            return
        }

        guard
            let serviceURL = Bundle.main.resourceURL?.appendingPathComponent("services/ontime_break_sync.py"),
            FileManager.default.fileExists(atPath: serviceURL.path)
        else {
            setStatus(symbol: "!", tooltip: "Service file missing")
            serviceStatusItem.title = "Service: file missing"
            return
        }

        service = ServiceController(serviceURL: serviceURL, configURL: configURL, logURL: logURL)
        service?.start()

        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.refreshStatus()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        service?.stop()
    }

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setStatus(symbol: "…", tooltip: appName)

        let menu = NSMenu()
        let header = NSMenuItem(title: appName, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        for item in [serviceStatusItem, ontimeStatusItem, modeItem, patternItem, lastActionItem] {
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Restart Service", action: #selector(restartService), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Open Config", action: #selector(openConfig), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Open Logs", action: #selector(openLogs), keyEquivalent: "l"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit VEN OBS Utils", action: #selector(quitApp), keyEquivalent: "q"))

        for item in menu.items where item.action != nil {
            item.target = self
        }
        statusItem.menu = menu
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

    private func configuredPort() -> Int {
        guard
            let data = try? Data(contentsOf: configURL),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let server = json["server"] as? [String: Any]
        else { return defaultPort }

        if let port = server["port"] as? Int { return port }
        if let number = server["port"] as? NSNumber { return number.intValue }
        return defaultPort
    }

    private func refreshStatus() {
        let url = URL(string: "http://127.0.0.1:\(configuredPort())/status")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.2
        request.cachePolicy = .reloadIgnoringLocalCacheData

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            guard error == nil, let data else {
                DispatchQueue.main.async {
                    self.setStatus(symbol: "×", tooltip: "VEN OBS Utils service unavailable")
                    self.serviceStatusItem.title = "Service: unavailable"
                    self.ontimeStatusItem.title = "Ontime: unknown"
                }
                return
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                DispatchQueue.main.async {
                    self.setStatus(symbol: "!", tooltip: "Invalid status response")
                    self.serviceStatusItem.title = "Service: invalid response"
                }
                return
            }

            DispatchQueue.main.async {
                self.applyStatus(json)
            }
        }.resume()
    }

    private func applyStatus(_ json: [String: Any]) {
        let ontime = (json["ontime"] as? String) ?? "unknown"
        let version = (json["ontime_version"] as? String) ?? ""
        let mode = (json["mode"] as? String) ?? "unknown"
        let pattern = (json["break_cue_regex"] as? String) ?? "-"

        serviceStatusItem.title = "Service: running"
        modeItem.title = "Mode: " + (mode == "live" ? "LIVE" : "DRY RUN")
        patternItem.title = "Break pattern: \(pattern)"

        if ontime == "connected" {
            setStatus(symbol: "✓", tooltip: "VEN OBS Utils - running")
            ontimeStatusItem.title = version.isEmpty ? "Ontime: connected" : "Ontime: connected (\(version))"
        } else {
            setStatus(symbol: "!", tooltip: "VEN OBS Utils - Ontime disconnected")
            ontimeStatusItem.title = "Ontime: disconnected"
        }

        if let last = json["last_action"] as? [String: Any] {
            let status = (last["status"] as? String) ?? "-"
            let cue = (last["cue"] as? String) ?? ""
            let reason = (last["reason"] as? String) ?? ""
            if !cue.isEmpty {
                lastActionItem.title = "Last action: \(status) \(cue)"
            } else if !reason.isEmpty {
                lastActionItem.title = "Last action: \(status) (\(reason))"
            } else {
                lastActionItem.title = "Last action: \(status)"
            }
        } else {
            lastActionItem.title = "Last action: -"
        }
    }

    private func setStatus(symbol: String, tooltip: String) {
        statusItem?.button?.title = "VEN \(symbol)"
        statusItem?.button?.toolTip = tooltip
    }

    @objc private func restartService() {
        serviceStatusItem.title = "Service: restarting…"
        service?.restart()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.refreshStatus()
        }
    }

    @objc private func openConfig() {
        NSWorkspace.shared.open(configURL)
    }

    @objc private func openLogs() {
        NSWorkspace.shared.open(logURL)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
