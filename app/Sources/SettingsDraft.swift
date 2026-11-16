import Foundation

enum SettingsDraftField: String, Hashable {
    case obsHost
    case obsPort
    case password
    case obsBreakSceneRegex
    case ontimeBaseURL
    case ontimeBreakCueRegex
    case serverPort
    case reconnectSeconds
    case general
}

struct SettingsDraftError: LocalizedError, Equatable {
    let field: SettingsDraftField
    let message: String

    var errorDescription: String? { message }
}

enum SettingsConfigurationSource {
    static func resolve(
        current: AppConfig?,
        load: () throws -> AppConfig
    ) rethrows -> AppConfig {
        if let current {
            return current
        }
        return try load()
    }
}

struct SettingsDraft {
    var obsHost: String
    var obsPort: String
    var password: String
    var obsBreakSceneRegex: String
    var ontimeBaseURL: String
    var ontimeBreakCueRegex: String
    var serverPort: String
    var reconnectSeconds: String
    var enterBreakEnabled: Bool
    var leaveBreakEnabled: Bool
    var dryRun: Bool
    var mediaBridge: [String: Any]

    init(config: AppConfig, password: String) {
        obsHost = config.obsHost
        obsPort = String(config.obsPort)
        self.password = password
        obsBreakSceneRegex = config.obsBreakSceneRegex
        ontimeBaseURL = config.ontimeBaseURL
        ontimeBreakCueRegex = config.ontimeBreakCueRegex
        serverPort = String(config.serverPort)
        reconnectSeconds = Self.format(config.obsReconnectSeconds)
        enterBreakEnabled = config.enterBreakEnabled
        leaveBreakEnabled = config.leaveBreakEnabled
        dryRun = config.dryRun
        mediaBridge = config.mediaBridge
    }

    func applying(to existing: AppConfig) throws -> (config: AppConfig, password: String) {
        let trimmedHost = obsHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            throw SettingsDraftError(field: .obsHost, message: "OBS host cannot be empty")
        }

        guard let parsedOBSPort = Int(obsPort), (1...65535).contains(parsedOBSPort) else {
            throw SettingsDraftError(field: .obsPort, message: "OBS port must be a number from 1 to 65535")
        }

        do {
            try SceneTransitionClassifier.validate(pattern: obsBreakSceneRegex)
        } catch {
            throw SettingsDraftError(field: .obsBreakSceneRegex, message: "OBS break scene regex is invalid")
        }

        let trimmedOntime = ontimeBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let ontimeURL = URL(string: trimmedOntime),
              let scheme = ontimeURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw SettingsDraftError(field: .ontimeBaseURL, message: "Ontime URL must start with http:// or https://")
        }

        do {
            _ = try NSRegularExpression(pattern: ontimeBreakCueRegex)
        } catch {
            throw SettingsDraftError(field: .ontimeBreakCueRegex, message: "Ontime break CUE regex is invalid")
        }

        guard let parsedServerPort = Int(serverPort), (1...65535).contains(parsedServerPort) else {
            throw SettingsDraftError(field: .serverPort, message: "Local service port must be a number from 1 to 65535")
        }

        guard let parsedReconnect = Double(reconnectSeconds), parsedReconnect > 0 else {
            throw SettingsDraftError(field: .reconnectSeconds, message: "Reconnect interval must be greater than 0")
        }

        var updated = existing
        updated.obsHost = trimmedHost
        updated.obsPort = parsedOBSPort
        updated.obsBreakSceneRegex = obsBreakSceneRegex
        updated.obsReconnectSeconds = parsedReconnect
        updated.ontimeBaseURL = trimmedOntime
        updated.ontimeBreakCueRegex = ontimeBreakCueRegex
        updated.serverPort = parsedServerPort
        updated.enterBreakEnabled = enterBreakEnabled
        updated.leaveBreakEnabled = leaveBreakEnabled
        updated.dryRun = dryRun
        updated.mediaBridge = mediaBridge

        do {
            _ = try updated.validated()
        } catch {
            throw SettingsDraftError(field: .general, message: error.localizedDescription)
        }

        return (updated, password)
    }

    private static func format(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(value)
    }
}

struct MPSSourceChoice: Equatable {
    let uuid: String
    let name: String
}

enum MediaMessageTemplate {
    static let variables: [(key: String, label: String)] = [
        ("current_file", "Current filename"),
        ("remaining_hhmmss", "Time remaining in current file"),
        ("playlist_remaining_hhmmss", "Time remaining in playlist"),
    ]

    static func time(_ value: Any?) -> String {
        guard let number = value as? NSNumber, number.doubleValue >= 0 else { return "--:--" }
        let seconds = number.int64Value / 1000
        return String(format: "%02lld:%02lld:%02lld", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }

    static func remainingSummary(_ state: [String: Any]) -> String {
        let file = "Remaining: file " + time(state["remaining_ms"])
        return state["loop"] as? Bool == true ? file : file + " · playlist " + time(state["playlist_remaining_ms"])
    }

    static func preview(_ template: String, state: [String: Any]) -> String {
        let live = state["available"] as? Bool == true
        let values = ["current_file": live ? (state["current_file"] as? String ?? "—") : "intro.mp4",
                      "remaining_hhmmss": live ? time(state["remaining_ms"]) : "00:00:45",
                      "playlist_remaining_hhmmss": live ? time(state["loop"] as? Bool == true ? nil : state["playlist_remaining_ms"]) : "00:12:30"]
        let chars = Array(template)
        var result = ""
        var i = 0
        while i < chars.count {
            if (chars[i] == "{" || chars[i] == "}"), i + 1 < chars.count, chars[i] == chars[i + 1] {
                result.append(chars[i]); i += 2
            } else if chars[i] == "{", let end = chars[(i + 1)...].firstIndex(of: "}") {
                let key = String(chars[(i + 1)..<end])
                result += values[key] ?? "{\(key)}"
                i = end + 1
            } else { result.append(chars[i]); i += 1 }
        }
        return result
    }
}
