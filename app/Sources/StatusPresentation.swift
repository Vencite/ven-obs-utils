import Foundation

enum StatusPresentationState: Equatable {
    case ready
    case warning
    case working
    case success
    case failure
}

enum StatusPresentation {
    static func baseState(obsConnected: Bool, ontimeConnected: Bool) -> StatusPresentationState {
        obsConnected && ontimeConnected ? .ready : .warning
    }

    static func symbolName(for state: StatusPresentationState) -> String {
        switch state {
        case .ready:
            return "dot.radiowaves.left.and.right"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .working:
            return "arrow.triangle.2.circlepath"
        case .success:
            return "checkmark.circle.fill"
        case .failure:
            return "xmark.circle.fill"
        }
    }
}


enum MediaOutputPresentation {
    static func unavailable(enabled: Bool) -> [String: Any] {
        ["output_status": enabled ? "unavailable" : "disabled"]
    }

    static func summary(_ state: [String: Any]) -> String {
        if let rows = state["auxiliary_timers"] as? [[String: Any]], !rows.isEmpty {
            var parts = rows.map { row -> String in
                let index = row["aux_timer_index"] as? Int ?? 0
                let status = row["output_status"] as? String ?? "pending"
                let label = status == "playlist_looping" ? "Playlist is looping" : status == "unknown_remaining" ? "waiting for known duration" : status == "waiting_for_snapshot" ? "waiting for MPS" : status.replacingOccurrences(of: "_", with: " ")
                return "Aux \(index): " + label
            }
            if let message = state["secondary_message_status"] as? String { parts.append("Message: " + message.replacingOccurrences(of: "_", with: " ")) }
            if let error = state["output_error"] as? String { parts.append("Error: " + error.replacingOccurrences(of: "_", with: " ")) }
            return parts.joined(separator: " · ")
        }
        let status = state["output_status"] as? String ?? "waiting_for_snapshot"
        if let error = state["output_error"] as? String, !error.isEmpty {
            if error.hasPrefix("ontime_http_") {
                return "Error: Ontime returned HTTP " + error.replacingOccurrences(of: "ontime_http_", with: "")
            }
            switch error {
            case "timer_recovery_required":
                let slot = (state["recovery_timer_index"] as? Int).map { " \($0)" } ?? ""
                return "Recovery: review auxiliary timer" + slot + " in Ontime"
            case "timer_recovery_target_changed": return "Recovery: previous Ontime target needs operator review"
            case "ontime_unreachable": return "Error: Ontime unavailable"
            case "aux_timer_in_use": return "Error: auxiliary timer is in use"
            case "aux_timer_unavailable": return "Error: selected auxiliary timer is unavailable"
            case "export_failed", "file_export_failed", "filesystem_error": return "Error: could not write the export file"
            default: return "Error: " + error.replacingOccurrences(of: "_", with: " ")
            }
        }
        switch status {
        case "disabled": return "Disabled"
        case "unavailable": return "Helper unavailable"
        case "connected": return "Connected — waiting for output confirmation"
        case "off": return "Ontime output off"
        case "waiting_for_snapshot": return "Waiting for OBS playlist data"
        case "inactive": return "No active media — inactive policy applied"
        case "playlist_looping": return "Playlist is looping"
        case "unknown_remaining": return "Remaining time unknown — countdown not running"
        case "pending": return "Waiting to send to Ontime"
        case "dry_run": return "Dry run — no changes sent to Ontime"
        case "synced":
            return state["ontime_output"] as? String == "secondary_message" ? "Secondary message updated" : "Auxiliary timer updated"
        case "error": return "Error: Ontime output failed"
        default: return status.replacingOccurrences(of: "_", with: " ")
        }
    }
}
