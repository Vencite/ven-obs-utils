import Foundation

@main
struct SettingsDraftTests {
    static func main() throws {
        try testSettingsUseTheConfigurationAlreadyLoadedAtStartup()
        try testValidDraftUpdatesConfig()
        try testInvalidOBSPortIsFieldError()
        try testInvalidSceneRegexIsFieldError()
        print("SettingsDraftTests: PASS")
    }

    static func testSettingsUseTheConfigurationAlreadyLoadedAtStartup() throws {
        let cachedConfig = try baseConfig()
        let resolved = try SettingsConfigurationSource.resolve(current: cachedConfig) {
            throw SettingsDraftTestFailure("Settings should not reload config when it is already cached")
        }

        guard resolved.obsHost == cachedConfig.obsHost,
              resolved.ontimeBaseURL == cachedConfig.ontimeBaseURL else {
            throw SettingsDraftTestFailure("Settings did not use the cached configuration")
        }
    }

    static func baseConfig() throws -> AppConfig {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("config.json")
        let json = #"{"ontime":{"base_url":"https://ontime.example.com","break_cue_regex":"^BRK_\\d+$","request_timeout_seconds":3},"server":{"host":"127.0.0.1","port":8765},"safety":{"dry_run":true,"debounce_seconds":2}}"#
        try Data(json.utf8).write(to: url)
        return try AppConfig.load(from: url)
    }

    static func testValidDraftUpdatesConfig() throws {
        let config = try baseConfig()
        var draft = SettingsDraft(config: config, password: "old")
        draft.obsHost = "10.0.0.20"
        draft.obsPort = "4456"
        draft.password = "new-secret"
        draft.obsBreakSceneRegex = #"^BREAK_.*$"#
        draft.ontimeBaseURL = "https://ontime.example.org"
        draft.ontimeBreakCueRegex = #"^PAUZA_\d+$"#
        draft.serverPort = "9876"
        draft.reconnectSeconds = "7.5"
        draft.enterBreakEnabled = false
        draft.leaveBreakEnabled = true
        draft.dryRun = false

        let result = try draft.applying(to: config)
        guard result.config.obsHost == "10.0.0.20",
              result.config.obsPort == 4456,
              result.config.obsBreakSceneRegex == #"^BREAK_.*$"#,
              result.config.ontimeBaseURL == "https://ontime.example.org",
              result.config.ontimeBreakCueRegex == #"^PAUZA_\d+$"#,
              result.config.serverPort == 9876,
              result.config.obsReconnectSeconds == 7.5,
              result.config.enterBreakEnabled == false,
              result.config.leaveBreakEnabled == true,
              result.config.dryRun == false,
              result.password == "new-secret" else {
            throw SettingsDraftTestFailure("valid draft was not applied correctly")
        }
    }

    static func testInvalidOBSPortIsFieldError() throws {
        let config = try baseConfig()
        var draft = SettingsDraft(config: config, password: "")
        draft.obsPort = "abc"
        do {
            _ = try draft.applying(to: config)
            throw SettingsDraftTestFailure("invalid OBS port should fail")
        } catch let error as SettingsDraftError {
            guard error.field == .obsPort else {
                throw SettingsDraftTestFailure("invalid OBS port should point at obsPort")
            }
        }
    }

    static func testInvalidSceneRegexIsFieldError() throws {
        let config = try baseConfig()
        var draft = SettingsDraft(config: config, password: "")
        draft.obsBreakSceneRegex = "["
        do {
            _ = try draft.applying(to: config)
            throw SettingsDraftTestFailure("invalid scene regex should fail")
        } catch let error as SettingsDraftError {
            guard error.field == .obsBreakSceneRegex else {
                throw SettingsDraftTestFailure("invalid scene regex should point at obsBreakSceneRegex")
            }
        }
    }
}

struct SettingsDraftTestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
