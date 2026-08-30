import Foundation

enum SettingsDraftField: String, Equatable {
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

    init(config: AppConfig, password: String) {
        obsHost = config.obsHost
        obsPort = String(config.obsPort)
        self.password = password
        obsBreakSceneRegex = config.obsBreakSceneRegex
        ontimeBaseURL = config.ontimeBaseURL
        ontimeBreakCueRegex = config.ontimeBreakCueRegex
        serverPort = String(config.serverPort)
        reconnectSeconds = format(config.obsReconnectSeconds)
        enterBreakEnabled = config.enterBreakEnabled
        leaveBreakEnabled = config.leaveBreakEnabled
        dryRun = config.dryRun
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
