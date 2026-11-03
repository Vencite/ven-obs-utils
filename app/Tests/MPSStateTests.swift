import Foundation

@main
struct MPSStateTests {
    static func main() throws {
        try testKnownAndUnknown()
        try testInvalidWireValues()
        try testExplicitIdentity()
        try testVisibleProgramTraversal()
        try testAmbiguousAndIncompleteGraphs()
        print("MPSStateTests: PASS")
    }

    static func snapshot() -> [String: Any] {
        [
            "schema_version": 1, "source_uuid": "mps-a", "source_name": "Playlist",
            "snapshot_revision": 0, "state": "playing",
            "remaining_known": true, "remaining_ms": 0,
            "playlist_remaining_known": false, "items_remaining_known": true,
            "items_remaining": 0, "shuffle": true, "loop": true,
            "has_next": false, "has_previous": false,
        ]
    }

    static func testKnownAndUnknown() throws {
        let value = try MPSState(snapshot()).payload
        guard MPSState.integer(value["remaining_ms"]) == 0,
              value["playlist_remaining_ms"] == nil,
              MPSState.boolean(value["available"]) == true,
              MPSState.boolean(value["stale"]) == false else {
            throw Failure("known zero or unknown omission lost")
        }
        var allUnknown = snapshot()
        allUnknown["remaining_known"] = false
        allUnknown.removeValue(forKey: "remaining_ms")
        allUnknown["items_remaining_known"] = false
        allUnknown.removeValue(forKey: "items_remaining")
        _ = try MPSState(allUnknown)
        let unavailable = MPSState.unavailable(reason: "Disconnected")
        guard unavailable["remaining_ms"] == nil,
              unavailable["playlist_remaining_ms"] == nil,
              MPSState.boolean(unavailable["remaining_known"]) == false,
              MPSState.boolean(unavailable["available"]) == false,
              unavailable["reason"] as? String == "Disconnected" else {
            throw Failure("unavailable state invented a countdown")
        }
        let json = try JSONSerialization.data(withJSONObject: snapshot())
        guard let decoded = try JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw Failure("snapshot JSON is not an object")
        }
        _ = try MPSState(decoded)
    }

    static func testInvalidWireValues() throws {
        let invalid: [(String, Any)] = [
            ("schema_version", true), ("schema_version", 1.0), ("schema_version", 2),
            ("snapshot_revision", false), ("snapshot_revision", -1),
            ("remaining_known", 1), ("remaining_ms", true), ("remaining_ms", -1),
            ("remaining_ms", 1.5), ("remaining_ms", "0"), ("remaining_ms", NSNull()),
            ("playlist_remaining_ms", 0), ("playlist_remaining_ms", NSNull()),
            ("items_remaining", [:]), ("source_uuid", ""), ("source_name", NSNull()),
            ("state", "buffering"), ("current_file", ""), ("current_path", [:]),
            ("elapsed_media_ms", -1), ("duration_media_ms", 1.0),
            ("speed_percent", 0), ("has_next", 1), ("shuffle", NSNull()),
            ("unexpected", [:]),
        ]
        for (key, value) in invalid {
            var data = snapshot()
            data[key] = value
            try rejects { _ = try MPSState(data) }
        }
        for key in ["schema_version", "source_uuid", "snapshot_revision", "state", "remaining_known", "remaining_ms", "items_remaining_known", "loop"] {
            var data = snapshot()
            data.removeValue(forKey: key)
            try rejects { _ = try MPSState(data) }
        }
    }

    static func input(_ id: String, _ name: String, kind: String = MPSSelection.inputKind) -> [String: Any] {
        ["inputUuid": id, "inputName": name, "inputKind": kind]
    }

    static func item(_ id: String, _ name: String, enabled: Bool = true, group: Bool = false) -> [String: Any] {
        ["sourceUuid": id, "sourceName": name, "sceneItemEnabled": enabled, "isGroup": group]
    }

    static func resolve(_ inputs: [[String: Any]], _ scenes: [String: [[String: Any]]], program: String = "Program", mode: String = "follow_program", uuid: String = "", name: String = "") throws -> String {
        try MPSSelection.resolve(inputs: inputs, scenes: scenes, program: program, sourceMode: mode, sourceUUID: uuid, sourceName: name)
    }

    static func testExplicitIdentity() throws {
        let inputs = [input("a", "Renamed"), input("b", "Other"), input("video", "Video", kind: "ffmpeg_source")]
        guard try resolve(inputs, [:], mode: "explicit", uuid: "a", name: "Old name") == "a",
              try resolve(inputs, [:], mode: "explicit", name: "Other") == "b" else {
            throw Failure("explicit identity or name fallback failed")
        }
        try rejects { _ = try resolve(inputs, [:], mode: "explicit", uuid: "missing", name: "Other") }
        try rejects { _ = try resolve(inputs, [:], mode: "explicit", uuid: "video") }
        try rejects { _ = try resolve(inputs, [:], mode: "explicit") }
        try rejects { _ = try resolve([input("a", "Same"), input("b", "Same")], [:], mode: "explicit", name: "Same") }
    }

    static func testVisibleProgramTraversal() throws {
        let inputs = [input("a", "Playlist"), input("b", "Preview playlist")]
        let scenes = [
            "Program": [item("nested", "Nested"), item("a", "Playlist"), item("b", "Preview playlist", enabled: false)],
            "Nested": [item("group", "Group", group: true)],
            "Group": [item("a", "Playlist")],
            "Preview": [item("b", "Preview playlist")],
        ]
        guard try resolve(inputs, scenes) == "a" else {
            throw Failure("nested/group/shared input resolution failed")
        }
        let hiddenCycle = ["Program": [item("a", "Playlist"), item("Program", "Program", enabled: false)]]
        guard try resolve(inputs, hiddenCycle) == "a" else {
            throw Failure("hidden source affected Program selection")
        }
    }

    static func testAmbiguousAndIncompleteGraphs() throws {
        let inputs = [input("a", "A"), input("b", "B")]
        try rejects { _ = try resolve(inputs, ["Program": []]) }
        try rejects { _ = try resolve(inputs, ["Program": [item("a", "A"), item("b", "B")]]) }
        try rejects { _ = try resolve(inputs, ["Program": [item("Program", "Program")]]) }
        try rejects { _ = try resolve(inputs, ["Program": [item("group", "Missing group", group: true)]]) }
        try rejects { _ = try resolve(inputs, [:]) }
        var unknownVisibility = item("a", "A")
        unknownVisibility.removeValue(forKey: "sceneItemEnabled")
        try rejects { _ = try resolve(inputs, ["Program": [unknownVisibility]]) }
        var scenes: [String: [[String: Any]]] = [:]
        for depth in 0..<33 { scenes["\(depth)"] = [item("\(depth + 1)", "\(depth + 1)")] }
        scenes["33"] = [item("a", "A")]
        try rejects { _ = try resolve(inputs, scenes, program: "0") }
    }

    static func rejects(_ action: () throws -> Void) throws {
        do { try action() } catch is MPSStateError { return }
        throw Failure("invalid input was accepted")
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
