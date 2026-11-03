import Foundation
import CoreFoundation

enum MPSStateError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let reason): return reason
        }
    }
}

struct MPSState {
    let payload: [String: Any]

    init(_ payload: [String: Any]) throws {
        guard Self.integer(payload["schema_version"]) == 1 else {
            throw MPSStateError.invalid("Unsupported MPS schema version")
        }
        for key in ["source_uuid", "source_name"] {
            guard let value = payload[key] as? String, !value.isEmpty else {
                throw MPSStateError.invalid("MPS snapshot is missing \(key)")
            }
        }
        guard let revision = Self.integer(payload["snapshot_revision"]), revision >= 0 else {
            throw MPSStateError.invalid("Invalid MPS snapshot revision")
        }
        guard let state = payload["state"] as? String,
              ["playing", "paused", "stopped", "ended", "unknown"].contains(state) else {
            throw MPSStateError.invalid("Invalid MPS playback state")
        }
        for (flag, value) in [
            ("remaining_known", "remaining_ms"),
            ("playlist_remaining_known", "playlist_remaining_ms"),
            ("items_remaining_known", "items_remaining"),
        ] {
            guard let known = Self.boolean(payload[flag]) else {
                throw MPSStateError.invalid("Invalid or missing MPS flag \(flag)")
            }
            if known {
                guard let number = Self.integer(payload[value]), number >= 0 else {
                    throw MPSStateError.invalid("Known MPS value \(value) must be a non-negative integer")
                }
            } else if payload[value] != nil {
                throw MPSStateError.invalid("Unknown MPS value \(value) must be absent")
            }
        }
        for key in ["shuffle", "loop", "has_next", "has_previous"] {
            guard Self.boolean(payload[key]) != nil else {
                throw MPSStateError.invalid("Invalid or missing MPS flag \(key)")
            }
        }
        for key in ["current_item_id", "current_path", "current_file"] where payload[key] != nil {
            guard let value = payload[key] as? String, !value.isEmpty else {
                throw MPSStateError.invalid("Invalid MPS string \(key)")
            }
        }
        for key in ["playlist_index", "folder_item_index", "elapsed_media_ms", "duration_media_ms", "speed_percent"] where payload[key] != nil {
            guard let value = Self.integer(payload[key]), value >= 0,
                  key != "speed_percent" || value > 0 else {
                throw MPSStateError.invalid("Invalid MPS integer \(key)")
            }
        }
        // Schema v1 is flat; accepting null or nested placeholders would hide a wire mismatch.
        for (_, value) in payload {
            guard value is String || value is NSNumber else {
                throw MPSStateError.invalid("Invalid nested or null MPS value")
            }
        }
        var normalized = payload
        normalized["available"] = true
        normalized["stale"] = false
        self.payload = normalized
    }

    static func unavailable(reason: String) -> [String: Any] {
        [
            "schema_version": 1,
            "available": false,
            "stale": true,
            "reason": reason,
            "state": "unknown",
            "remaining_known": false,
            "playlist_remaining_known": false,
            "items_remaining_known": false,
        ]
    }

    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              ["s", "i", "l", "q", "S", "I", "L", "Q"].contains(String(cString: number.objCType)) else {
            return nil
        }
        return Int(number.stringValue)
    }

    static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return nil
        }
        return number.boolValue
    }
}

enum MPSSelection {
    static let inputKind = "media_playlist_source_codeyan"

    static func resolve(
        inputs: [[String: Any]],
        scenes: [String: [[String: Any]]],
        program: String,
        sourceMode: String,
        sourceUUID: String,
        sourceName: String
    ) throws -> String {
        func isMPS(_ input: [String: Any]) -> Bool {
            input["inputKind"] as? String == inputKind || input["unversionedInputKind"] as? String == inputKind
        }
        func uuid(_ input: [String: Any]) throws -> String {
            guard let id = input["inputUuid"] as? String, !id.isEmpty else {
                throw MPSStateError.invalid("MPS input is missing its UUID")
            }
            return id
        }
        if sourceMode == "explicit" {
            let matches = inputs.filter { input in
                if !sourceUUID.isEmpty { return input["inputUuid"] as? String == sourceUUID }
                return !sourceName.isEmpty && input["inputName"] as? String == sourceName
            }
            guard matches.count == 1, let input = matches.first, isMPS(input) else {
                throw MPSStateError.invalid("Explicit source must resolve to exactly one MPS input")
            }
            return try uuid(input)
        }
        guard sourceMode == "follow_program" else {
            throw MPSStateError.invalid("Invalid MPS source mode")
        }

        var candidates = Set<String>()
        var visited = Set<String>()
        func visit(_ scene: String, ancestors: Set<String>) throws {
            guard ancestors.count < 32, !ancestors.contains(scene) else {
                throw MPSStateError.invalid("Program scene graph has a cycle or exceeds the depth limit")
            }
            if visited.contains(scene) { return }
            guard let items = scenes[scene] else {
                throw MPSStateError.invalid("Program scene graph is incomplete")
            }
            var nextAncestors = ancestors
            nextAncestors.insert(scene)
            for item in items {
                guard let enabled = MPSState.boolean(item["sceneItemEnabled"]) else {
                    throw MPSStateError.invalid("Scene item visibility is unknown")
                }
                guard enabled else { continue }
                guard let name = item["sourceName"] as? String, !name.isEmpty else {
                    throw MPSStateError.invalid("Scene item is missing its source name")
                }
                if scenes[name] != nil || MPSState.boolean(item["isGroup"]) == true || item["inputKind"] as? String == "scene" {
                    try visit(name, ancestors: nextAncestors)
                    continue
                }
                let matches = inputs.filter { input in
                    if let id = item["sourceUuid"] as? String, !id.isEmpty {
                        return input["inputUuid"] as? String == id
                    }
                    return input["inputName"] as? String == name
                }
                if matches.count > 1 {
                    throw MPSStateError.invalid("Scene item identity is ambiguous")
                }
                if let input = matches.first, isMPS(input) {
                    candidates.insert(try uuid(input))
                } else if item["inputKind"] as? String == inputKind {
                    throw MPSStateError.invalid("Scene MPS input could not be verified")
                }
            }
            visited.insert(scene)
        }
        try visit(program, ancestors: [])
        guard candidates.count == 1, let selected = candidates.first else {
            throw MPSStateError.invalid(candidates.isEmpty ? "No visible MPS in Program" : "Multiple visible MPS inputs in Program")
        }
        return selected
    }
}
