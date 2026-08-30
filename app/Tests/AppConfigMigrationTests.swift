import Foundation

@main
struct AppConfigMigrationTests {
    static func main() throws {
        try testLegacyConfigIsMigratedWithBackup()
        try testCurrentConfigIsLeftUntouched()
        try testLoadAutomaticallyMigratesLegacyConfig()
        print("AppConfigMigrationTests: PASS")
    }

    static func testLegacyConfigIsMigratedWithBackup() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("config.json")
        let backupURL = url.appendingPathExtension("backup")

        let legacyJSON = #"{"ontime_base_url":"https://private.example.com","break_cue_regex":"^BRK_\\d+$","request_timeout_seconds":4,"server_host":"127.0.0.1","server_port":9876,"dry_run":false,"debounce_seconds":3,"custom":{"keep":"yes"}}"#
        let originalData = Data(legacyJSON.utf8)
        try originalData.write(to: url)

        let migrated = try AppConfig.migrateIfNeeded(at: url)
        guard migrated else {
            throw MigrationTestFailure("legacy config should report migration")
        }

        let backupData = try Data(contentsOf: backupURL)
        guard backupData == originalData else {
            throw MigrationTestFailure("backup must be an exact copy of the pre-migration config")
        }

        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MigrationTestFailure("migrated config is not a JSON object")
        }

        guard (root["config_version"] as? NSNumber)?.intValue == AppConfig.currentConfigVersion else {
            throw MigrationTestFailure("migrated config should contain current config_version")
        }
        guard let ontime = root["ontime"] as? [String: Any],
              ontime["base_url"] as? String == "https://private.example.com",
              let server = root["server"] as? [String: Any],
              (server["port"] as? NSNumber)?.intValue == 9876,
              let safety = root["safety"] as? [String: Any],
              (safety["dry_run"] as? NSNumber)?.boolValue == false,
              let custom = root["custom"] as? [String: Any],
              custom["keep"] as? String == "yes" else {
            throw MigrationTestFailure("migration did not preserve existing values")
        }

        guard root["ontime_base_url"] == nil,
              root["server_port"] == nil,
              root["dry_run"] == nil else {
            throw MigrationTestFailure("legacy flat keys should be removed after migration")
        }
    }

    static func testCurrentConfigIsLeftUntouched() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("config.json")
        let backupURL = url.appendingPathExtension("backup")

        let currentJSON = #"{"config_version":1,"ontime":{"base_url":"https://ontime.example.com","break_cue_regex":"^BRK_\\d+$","request_timeout_seconds":3},"obs":{"host":"127.0.0.1","port":4455,"break_scene_regex":"^BREAK_.*$","reconnect_seconds":5},"automation":{"enter_break":true,"leave_break":true},"server":{"host":"127.0.0.1","port":8765},"safety":{"dry_run":true,"debounce_seconds":2}}"#
        let originalData = Data(currentJSON.utf8)
        try originalData.write(to: url)

        let migrated = try AppConfig.migrateIfNeeded(at: url)
        guard migrated == false else {
            throw MigrationTestFailure("current config should not be migrated")
        }
        guard try Data(contentsOf: url) == originalData else {
            throw MigrationTestFailure("current config should not be rewritten")
        }
        guard !FileManager.default.fileExists(atPath: backupURL.path) else {
            throw MigrationTestFailure("current config should not create a migration backup")
        }
    }

    static func testLoadAutomaticallyMigratesLegacyConfig() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("config.json")
        let backupURL = url.appendingPathExtension("backup")

        let legacyJSON = #"{"ontime_base_url":"https://auto.example.com","break_cue_regex":"^BRK_\\d+$","request_timeout_seconds":3,"server_host":"127.0.0.1","server_port":8765,"dry_run":true,"debounce_seconds":2}"#
        try Data(legacyJSON.utf8).write(to: url)

        let config = try AppConfig.load(from: url)
        guard config.ontimeBaseURL == "https://auto.example.com" else {
            throw MigrationTestFailure("load should preserve legacy values")
        }
        guard FileManager.default.fileExists(atPath: backupURL.path) else {
            throw MigrationTestFailure("load should automatically create a migration backup")
        }

        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["config_version"] as? NSNumber)?.intValue == AppConfig.currentConfigVersion else {
            throw MigrationTestFailure("load should automatically write the current config version")
        }
    }
}

struct MigrationTestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
