import Foundation

@main
struct SceneAutomationTests {
    static func main() throws {
        let pattern = #"^PRZERWA_.*$"#
        try expect(
            SceneTransitionClassifier.classify(previous: "KAMERY_LIVE", current: "PRZERWA_RANDOM", pattern: pattern),
            .enterBreak,
            "non-break -> break"
        )
        try expect(
            SceneTransitionClassifier.classify(previous: "PRZERWA_RANDOM", current: "KAMERY_LIVE", pattern: pattern),
            .leaveBreak,
            "break -> non-break"
        )
        try expect(
            SceneTransitionClassifier.classify(previous: "PRZERWA_RANDOM", current: "PRZERWA_MANGO", pattern: pattern),
            .ignore,
            "break -> break"
        )
        try expect(
            SceneTransitionClassifier.classify(previous: "KAMERY_LIVE", current: "KAMERY_LIVE_DWA", pattern: pattern),
            .ignore,
            "non-break -> non-break"
        )

        do {
            _ = try SceneTransitionClassifier.classify(previous: "A", current: "B", pattern: "[")
            fatalError("invalid regex should throw")
        } catch ScenePatternError.invalidRegex {
            // expected
        }

        try testConfigMigrationDefaults()
        print("SceneAutomationTests: PASS")
    }

    static func testConfigMigrationDefaults() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        let json = #"{"ontime":{"base_url":"https://ontime.example.com","break_cue_regex":"^BRK_\\d+$"},"server":{"host":"127.0.0.1","port":8765},"safety":{"dry_run":false,"debounce_seconds":2}}"#
        try json.data(using: .utf8)!.write(to: url)

        let config = try AppConfig.load(from: url)
        guard config.obsHost == "127.0.0.1",
              config.obsPort == 4455,
              config.obsBreakSceneRegex == #"^PRZERWA_.*$"#,
              config.obsReconnectSeconds == 5,
              config.enterBreakEnabled,
              config.leaveBreakEnabled,
              config.ontimeBaseURL == "https://ontime.example.com",
              config.serverPort == 8765,
              config.dryRun == false else {
            throw TestFailure("existing config should load with OBS defaults without losing current values")
        }
    }

    static func expect(
        _ actual: SceneTransitionAction,
        _ expected: SceneTransitionAction,
        _ label: String
    ) throws {
        guard actual == expected else {
            throw TestFailure("\(label): expected \(expected.rawValue), got \(actual.rawValue)")
        }
    }
}

struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
