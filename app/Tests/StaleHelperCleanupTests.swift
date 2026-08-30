import Foundation

@main
struct StaleHelperCleanupTests {
    static func main() throws {
        try testMatchesAHelperUsingThisConfig()
        try testRejectsAHelperUsingAnotherConfig()
        try testRejectsAnUnrelatedListener()
        print("StaleHelperCleanupTests: PASS")
    }

    static func testMatchesAHelperUsingThisConfig() throws {
        let configURL = URL(fileURLWithPath: "/Users/test/Library/Application Support/VEN OBS Utils/config.json")
        let command = "/usr/bin/python3 /Applications/VEN OBS Utils.app/Contents/Resources/services/ontime_break_sync.py --config '\(configURL.path)'"
        guard StaleHelperCleanup.isManagedHelper(command: command, configURL: configURL) else {
            throw StaleHelperCleanupTestFailure("Expected the previous app helper to match")
        }
    }

    static func testRejectsAHelperUsingAnotherConfig() throws {
        let configURL = URL(fileURLWithPath: "/Users/test/Library/Application Support/VEN OBS Utils/config.json")
        let command = "/usr/bin/python3 ontime_break_sync.py --config /tmp/other-config.json"
        guard !StaleHelperCleanup.isManagedHelper(command: command, configURL: configURL) else {
            throw StaleHelperCleanupTestFailure("A helper using another config must not be terminated")
        }
    }

    static func testRejectsAnUnrelatedListener() throws {
        let configURL = URL(fileURLWithPath: "/Users/test/Library/Application Support/VEN OBS Utils/config.json")
        guard !StaleHelperCleanup.isManagedHelper(command: "/usr/local/bin/other-service", configURL: configURL) else {
            throw StaleHelperCleanupTestFailure("An unrelated listener must not be terminated")
        }
    }
}

struct StaleHelperCleanupTestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
