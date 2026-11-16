import Foundation
import CoreFoundation

struct AppConfig {
    var ontimeBaseURL: String
    var ontimeBreakCueRegex: String
    var requestTimeoutSeconds: Double
    var serverHost: String
    var serverPort: Int
    var dryRun: Bool
    var debounceSeconds: Double

    var obsHost: String
    var obsPort: Int
    var obsBreakSceneRegex: String
    var obsReconnectSeconds: Double

    var enterBreakEnabled: Bool
    var leaveBreakEnabled: Bool

    var mediaBridge: [String: Any] = [:]

    private var rawRoot: [String: Any]

    static let currentConfigVersion = 3
    static let defaultOBSHost = "127.0.0.1"
    static let defaultOBSPort = 4455
    static let defaultOBSBreakSceneRegex = #"^PRZERWA_.*$"#
    static let defaultOBSReconnectSeconds = 5.0

    static func migrateIfNeeded(at url: URL) throws -> Bool {
        let originalData = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: originalData) as? [String: Any] else {
            throw ConfigValidationError.invalid("Config root must be a JSON object")
        }

        let version = int(root["config_version"], default: 0)
        if version > currentConfigVersion {
            throw ConfigValidationError.invalid(
                "Config version \(version) is newer than this app supports (\(currentConfigVersion))"
            )
        }
        guard version < currentConfigVersion else { return false }

        let config = try decode(from: url)
        let backupURL = url.appendingPathExtension("backup")
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: backupURL.path) {
            try fileManager.removeItem(at: backupURL)
        }
        try originalData.write(to: backupURL, options: .atomic)
        try config.writeAtomically(to: url)
        return true
    }

    static func load(from url: URL) throws -> AppConfig {
        _ = try migrateIfNeeded(at: url)
        return try decode(from: url)
    }

    private static func decode(from url: URL) throws -> AppConfig {
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConfigValidationError.invalid("Config root must be a JSON object")
        }

        if let media = root["media_bridge"], !(media is [String: Any]) {
            throw ConfigValidationError.invalid("Media bridge configuration must be an object")
        }
        let ontime = root["ontime"] as? [String: Any] ?? [:]
        let server = root["server"] as? [String: Any] ?? [:]
        let safety = root["safety"] as? [String: Any] ?? [:]
        let obs = root["obs"] as? [String: Any] ?? [:]
        let automation = root["automation"] as? [String: Any] ?? [:]

        let baseURL: String
        let breakCueRegex: String
        let requestTimeout: Double
        let serverHost: String
        let serverPort: Int
        let dryRun: Bool
        let debounce: Double

        if !ontime.isEmpty {
            baseURL = string(ontime["base_url"], default: "")
            breakCueRegex = string(ontime["break_cue_regex"], default: #"^BRK_\d+$"#)
            requestTimeout = double(ontime["request_timeout_seconds"], default: 3.0)
            serverHost = string(server["host"], default: "127.0.0.1")
            serverPort = int(server["port"], default: 8765)
            dryRun = bool(safety["dry_run"], default: true)
            debounce = double(safety["debounce_seconds"], default: 2.0)
        } else {
            baseURL = string(root["ontime_base_url"], default: "")
            breakCueRegex = string(root["break_cue_regex"], default: #"^BRK_\d+$"#)
            requestTimeout = double(root["request_timeout_seconds"], default: 3.0)
            serverHost = string(root["server_host"], default: "127.0.0.1")
            serverPort = int(root["server_port"], default: 8765)
            dryRun = bool(root["dry_run"], default: true)
            debounce = double(root["debounce_seconds"], default: 2.0)
        }

        return AppConfig(
            ontimeBaseURL: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            ontimeBreakCueRegex: breakCueRegex,
            requestTimeoutSeconds: requestTimeout,
            serverHost: serverHost,
            serverPort: serverPort,
            dryRun: dryRun,
            debounceSeconds: debounce,
            obsHost: string(obs["host"], default: defaultOBSHost),
            obsPort: int(obs["port"], default: defaultOBSPort),
            obsBreakSceneRegex: string(obs["break_scene_regex"], default: defaultOBSBreakSceneRegex),
            obsReconnectSeconds: double(obs["reconnect_seconds"], default: defaultOBSReconnectSeconds),
            enterBreakEnabled: bool(automation["enter_break"], default: true),
            leaveBreakEnabled: bool(automation["leave_break"], default: true),
            mediaBridge: root["media_bridge"] as? [String: Any] ?? [:],
            rawRoot: root
        )
    }

    static func auxiliaryTimers(in media: [String: Any]) -> [[String: Any]] {
        if media["auxiliary_timers"] != nil { return media["auxiliary_timers"] as? [[String: Any]] ?? [] }
        let timer = media["timer"] as? [String: Any] ?? [:]
        guard timer["ontime_output"] as? String ?? "auxiliary_timer" == "auxiliary_timer",
              timer["media_timer_source"] as? String ?? "off" != "off" else { return [] }
        return [["enabled": true, "aux_timer_index": timer["aux_timer_index"] ?? 1,
                 "media_timer_source": timer["media_timer_source"] ?? "playlist",
                 "inactive_policy": timer["inactive_policy"] ?? "stop"]]
    }

    static func stageTimerSource(in media: [String: Any]) -> String {
        if let selected = media["stage_timer_source"] as? String { return selected }
        let timer = media["timer"] as? [String: Any] ?? [:]
        guard timer["change_stage_timer_secondary_source"] as? Bool == true,
              timer["media_timer_source"] as? String ?? "off" != "off" else { return "off" }
        return timer["ontime_output"] as? String == "secondary_message" ? "secondary" : "aux\(timer["aux_timer_index"] as? Int ?? 1)"
    }

    func validated() throws -> AppConfig {
        let trimmedOntime = ontimeBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOntime.isEmpty,
              let url = URL(string: trimmedOntime),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw ConfigValidationError.invalid("Ontime URL must start with http:// or https://")
        }
        guard !obsHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConfigValidationError.invalid("OBS host cannot be empty")
        }
        guard (1...65535).contains(obsPort) else {
            throw ConfigValidationError.invalid("OBS port must be between 1 and 65535")
        }
        guard (1...65535).contains(serverPort) else {
            throw ConfigValidationError.invalid("Local service port must be between 1 and 65535")
        }
        guard obsReconnectSeconds > 0 else {
            throw ConfigValidationError.invalid("OBS reconnect interval must be greater than 0")
        }
        guard requestTimeoutSeconds > 0 else {
            throw ConfigValidationError.invalid("Ontime timeout must be greater than 0")
        }
        guard debounceSeconds >= 0 else {
            throw ConfigValidationError.invalid("Debounce cannot be negative")
        }
        try SceneTransitionClassifier.validate(pattern: obsBreakSceneRegex)
        do {
            _ = try NSRegularExpression(pattern: ontimeBreakCueRegex)
        } catch {
            throw ConfigValidationError.invalid("Ontime break CUE regex is invalid")
        }
        guard ["127.0.0.1", "localhost"].contains(serverHost) else {
            throw ConfigValidationError.invalid("Local service requires a loopback address")
        }
        let media = mediaBridge
        if let enabled = media["enabled"], !Self.isBoolean(enabled) {
            throw ConfigValidationError.invalid("Media bridge enabled must be a boolean")
        }
        guard media["enabled"] as? Bool == true else { return self }
        for section in ["txt", "json", "timer"] {
            if let value = media[section], !(value is [String: Any]) {
                throw ConfigValidationError.invalid("Invalid media \(section) configuration")
            }
        }
        let toggles = [("txt", "enabled"), ("json", "enabled")] + (media["auxiliary_timers"] == nil ? [("timer", "change_stage_timer_secondary_source")] : [])
        for (section, key) in toggles {
            if let value = (media[section] as? [String: Any])?[key], !Self.isBoolean(value) {
                throw ConfigValidationError.invalid("Media toggles must be booleans")
            }
        }
        if media["enabled"] as? Bool == true {
            for key in ["source_mode", "source_uuid", "source_name"] {
                if let value = media[key], !(value is String) {
                    throw ConfigValidationError.invalid("Invalid media source field")
                }
            }
            let mode = media["source_mode"] as? String ?? "follow_program"
            guard ["explicit", "follow_program"].contains(mode) else {
                throw ConfigValidationError.invalid("Invalid media source mode")
            }
            if mode == "explicit",
               (media["source_uuid"] as? String ?? "").isEmpty,
               (media["source_name"] as? String ?? "").isEmpty {
                throw ConfigValidationError.invalid("Choose an MPS source UUID or name")
            }
            let txt = media["txt"] as? [String: Any] ?? [:]
            if txt["enabled"] as? Bool == true {
                guard let path = txt["path"] as? String, path.hasPrefix("/"), !path.contains("\0") else {
                    throw ConfigValidationError.invalid("Media TXT path must be absolute")
                }
            }
            for section in ["txt", "json"] {
                let output = media[section] as? [String: Any] ?? [:]
                if output["enabled"] as? Bool == true,
                   (!(output["path"] as? String ?? "").hasPrefix("/") || (output["path"] as? String ?? "").contains("\0")) {
                    throw ConfigValidationError.invalid("Media export paths must be absolute")
                }
            }
            let json = media["json"] as? [String: Any] ?? [:]
            if txt["enabled"] as? Bool == true, json["enabled"] as? Bool == true,
               txt["path"] as? String == json["path"] as? String {
                throw ConfigValidationError.invalid("TXT and JSON export paths must differ")
            }
            if let value = txt["clear_policy"], !(value is String) {
                throw ConfigValidationError.invalid("Invalid TXT policy")
            }
            guard ["clear_when_inactive", "keep_last"].contains(txt["clear_policy"] as? String ?? "clear_when_inactive") else {
                throw ConfigValidationError.invalid("Invalid TXT policy")
            }
            let timer = media["timer"] as? [String: Any] ?? [:]
            let validateTimer = media["auxiliary_timers"] == nil || (timer["ontime_output"] as? String == "secondary_message" && (timer["media_timer_source"] as? String ?? "invalid") != "off")
            if validateTimer {
                for (section, keys) in [(timer, ["media_timer_source", "ontime_output", "inactive_policy", "secondary_message_template"]),
                                        (txt, ["clear_policy"])] {
                    for key in keys {
                        if let value = section[key], !(value is String) {
                            throw ConfigValidationError.invalid("Invalid media setting type")
                        }
                    }
                }
                if let value = timer["aux_timer_index"] {
                    guard !Self.isBoolean(value), let number = value as? NSNumber,
                          String(cString: number.objCType) != "d", String(cString: number.objCType) != "f",
                          number.doubleValue == Double(number.intValue), (1...3).contains(number.intValue) else {
                        throw ConfigValidationError.invalid("Invalid auxiliary timer index")
                    }
                }
                guard Self.validMediaTemplate(timer["secondary_message_template"] as? String ?? "{current_file}") else {
                    throw ConfigValidationError.invalid("Invalid media message template")
                }
                guard ["off", "current_item", "playlist"].contains(timer["media_timer_source"] as? String ?? "off"),
                      ["auxiliary_timer", "secondary_message"].contains(timer["ontime_output"] as? String ?? "auxiliary_timer"),
                      (1...3).contains(timer["aux_timer_index"] as? Int ?? 1),
                      ["stop", "keep_last"].contains(timer["inactive_policy"] as? String ?? "stop"),
                      ["clear_when_inactive", "keep_last"].contains(txt["clear_policy"] as? String ?? "clear_when_inactive") else {
                    throw ConfigValidationError.invalid("Invalid media timer or TXT policy")
                }
            }
        }
        if let value = media["auxiliary_timers"] {
            guard let rows = value as? [[String: Any]], rows.count <= 3 else {
                throw ConfigValidationError.invalid("At most three auxiliary timers are allowed")
            }
            var slots = Set<Int>()
            for row in rows {
                if let enabled = row["enabled"], !Self.isBoolean(enabled) {
                    throw ConfigValidationError.invalid("Timer enabled must be a boolean")
                }
                if row["enabled"] as? Bool == false { continue }
                guard let value = row["aux_timer_index"], !Self.isBoolean(value),
                      let number = value as? NSNumber, String(cString: number.objCType) != "d",
                      String(cString: number.objCType) != "f", let index = row["aux_timer_index"] as? Int,
                      (1...3).contains(index), slots.insert(index).inserted,
                      let mode = row["media_timer_source"] as? String, ["current_item", "playlist"].contains(mode),
                      row["inactive_policy"] == nil || row["inactive_policy"] is String,
                      ["stop", "keep_last"].contains(row["inactive_policy"] as? String ?? "stop") else {
                    throw ConfigValidationError.invalid("Invalid timer settings or duplicate auxiliary slot")
                }
            }
        }
        if let value = media["stage_timer_source"] {
            guard let selected = value as? String, ["off", "aux1", "aux2", "aux3", "secondary"].contains(selected) else {
                throw ConfigValidationError.invalid("Invalid Stage Timer display source")
            }
            let timer = media["timer"] as? [String: Any] ?? [:]
            if selected == "secondary" {
                guard timer["ontime_output"] as? String == "secondary_message", timer["media_timer_source"] as? String ?? "off" != "off" else {
                    throw ConfigValidationError.invalid("Enable the selected Stage Timer output")
                }
            } else if selected.hasPrefix("aux") {
                let index = Int(String(selected.suffix(1)))!
                guard Self.auxiliaryTimers(in: media).contains(where: { $0["enabled"] as? Bool != false && ($0["aux_timer_index"] as? Int ?? 1) == index }) else {
                    throw ConfigValidationError.invalid("Enable the selected Stage Timer output")
                }
            }
        }
        return self
    }

    func writeAtomically(to url: URL) throws {
        _ = try validated()

        if (rawRoot["media_bridge"] as? [String: Any])?["auxiliary_timers"] == nil,
           mediaBridge["auxiliary_timers"] != nil, FileManager.default.fileExists(atPath: url.path) {
            let backup = url.appendingPathExtension("backup")
            if !FileManager.default.fileExists(atPath: backup.path) {
                try Data(contentsOf: url).write(to: backup, options: .atomic)
            }
        }
        var root = rawRoot
        root["config_version"] = Self.currentConfigVersion
        var media = mediaBridge
        media.removeValue(forKey: "http")
        if media["enabled"] == nil { media["enabled"] = false }
        if media["source_mode"] == nil { media["source_mode"] = "follow_program" }
        root["media_bridge"] = media

        var ontime = root["ontime"] as? [String: Any] ?? [:]
        ontime["base_url"] = ontimeBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        ontime["break_cue_regex"] = ontimeBreakCueRegex
        ontime["request_timeout_seconds"] = requestTimeoutSeconds
        root["ontime"] = ontime

        var server = root["server"] as? [String: Any] ?? [:]
        server["host"] = serverHost
        server["port"] = serverPort
        root["server"] = server

        var safety = root["safety"] as? [String: Any] ?? [:]
        safety["dry_run"] = dryRun
        safety["debounce_seconds"] = debounceSeconds
        root["safety"] = safety

        var obs = root["obs"] as? [String: Any] ?? [:]
        obs["host"] = obsHost.trimmingCharacters(in: .whitespacesAndNewlines)
        obs["port"] = obsPort
        obs["break_scene_regex"] = obsBreakSceneRegex
        obs["reconnect_seconds"] = obsReconnectSeconds
        root["obs"] = obs

        var automation = root["automation"] as? [String: Any] ?? [:]
        automation["enter_break"] = enterBreakEnabled
        automation["leave_break"] = leaveBreakEnabled
        root["automation"] = automation

        for legacyKey in [
            "ontime_base_url", "break_cue_regex", "request_timeout_seconds",
            "server_host", "server_port", "dry_run", "debounce_seconds",
        ] {
            root.removeValue(forKey: legacyKey)
        }

        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    private static func validMediaTemplate(_ text: String) -> Bool {
        guard text.count <= 2048 else { return false }
        let allowed = ["current_file", "remaining_hhmmss", "playlist_remaining_hhmmss"]
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            if chars[i] == "{" || chars[i] == "}" {
                if i + 1 < chars.count && chars[i + 1] == chars[i] { i += 2; continue }
                guard chars[i] == "{", let end = chars[(i + 1)...].firstIndex(of: "}"),
                      allowed.contains(String(chars[(i + 1)..<end])) else { return false }
                i = end + 1
            } else { i += 1 }
        }
        return true
    }

    private static func isBoolean(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func string(_ value: Any?, default defaultValue: String) -> String {
        value as? String ?? defaultValue
    }

    private static func int(_ value: Any?, default defaultValue: Int) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String, let parsed = Int(value) { return parsed }
        return defaultValue
    }

    private static func double(_ value: Any?, default defaultValue: Double) -> Double {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String, let parsed = Double(value) { return parsed }
        return defaultValue
    }

    private static func bool(_ value: Any?, default defaultValue: Bool) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String {
            if value.lowercased() == "true" { return true }
            if value.lowercased() == "false" { return false }
        }
        return defaultValue
    }
}

enum ConfigValidationError: LocalizedError, Equatable {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        }
    }
}
