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

        print("SceneAutomationTests: PASS")
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
