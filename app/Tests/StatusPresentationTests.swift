import Foundation

@main
struct StatusPresentationTests {
    static func main() throws {
        guard StatusPresentation.baseState(obsConnected: true, ontimeConnected: true) == .ready else {
            throw StatusPresentationTestFailure("both connected should be ready")
        }
        guard StatusPresentation.baseState(obsConnected: false, ontimeConnected: true) == .warning else {
            throw StatusPresentationTestFailure("OBS disconnected should be warning")
        }
        guard StatusPresentation.baseState(obsConnected: true, ontimeConnected: false) == .warning else {
            throw StatusPresentationTestFailure("Ontime disconnected should be warning")
        }
        guard StatusPresentation.symbolName(for: .ready) == "dot.radiowaves.left.and.right" else {
            throw StatusPresentationTestFailure("ready should use broadcast symbol")
        }
        guard StatusPresentation.symbolName(for: .warning) == "exclamationmark.triangle.fill" else {
            throw StatusPresentationTestFailure("warning should use warning symbol")
        }
        for state in [
            StatusPresentationState.ready,
            .warning,
            .working,
            .success,
            .failure,
        ] {
            guard !StatusPresentation.symbolName(for: state).isEmpty else {
                throw StatusPresentationTestFailure("every status state needs an icon")
            }
        }
        assert(MediaOutputPresentation.summary(["output_status": "synced", "ontime_output": "secondary_message"]) == "Secondary message updated")
        assert(MediaOutputPresentation.summary(["output_status": "error", "output_error": "ontime_http_403"]).contains("HTTP 403"))
        assert(MediaOutputPresentation.summary(["output_status": "unknown_remaining"]).contains("unknown"))
        let lost = MediaOutputPresentation.unavailable(enabled: true)
        assert(lost["output_status"] as? String == "unavailable")
        assert(lost["output_error"] == nil && lost["last_ontime_action"] == nil)
        assert(MediaOutputPresentation.summary(lost) == "Helper unavailable")
        assert(MediaOutputPresentation.summary(MediaOutputPresentation.unavailable(enabled: false)) == "Disabled")
        assert(MediaOutputPresentation.summary(["output_status": "pending"]).contains("Waiting"))
        assert(MediaOutputPresentation.summary(["output_status": "connected"]).contains("confirmation"))
        assert(MediaOutputPresentation.summary(["output_status": "synced"]) == "Auxiliary timer updated")
        let multi = MediaOutputPresentation.summary(["auxiliary_timers": [
            ["aux_timer_index": 1, "output_status": "synced"],
            ["aux_timer_index": 2, "output_status": "unknown_remaining"],
            ["aux_timer_index": 3, "output_status": "disabled"]]])
        assert(multi.contains("Aux 1: synced") && multi.contains("Aux 2: waiting for known duration") && multi.contains("Aux 3: disabled"))
        assert(MediaOutputPresentation.summary(["output_status": "playlist_looping"]) == "Playlist is looping")
        assert(MediaOutputPresentation.summary(["auxiliary_timers": [["aux_timer_index": 2, "output_status": "playlist_looping"]]]) == "Aux 2: Playlist is looping")
        print("StatusPresentationTests: PASS")
    }
}

struct StatusPresentationTestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
