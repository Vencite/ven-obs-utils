import Foundation

@main
struct AutomationRequestSequenceTests {
    static func main() throws {
        try testDisconnectAndLateHTTPCompletion()
        let enterTransition = ProgramSceneTransition(
            previous: "CAMERAS_LIVE",
            current: "PRZERWA_RANDOM",
            action: .enterBreak
        )
        let leaveTransition = ProgramSceneTransition(
            previous: "PRZERWA_RANDOM",
            current: "CAMERAS_LIVE",
            action: .leaveBreak
        )

        let enter = AutomationRequest(
            path: "/ontime/break",
            transition: enterTransition
        )
        let leave = AutomationRequest(
            path: "/ontime/leave-break",
            transition: leaveTransition
        )

        var sequence = AutomationRequestSequence()

        guard sequence.enqueue(enter) == enter else {
            throw SequenceTestFailure("first request must start immediately")
        }
        guard sequence.enqueue(leave) == nil else {
            throw SequenceTestFailure("second request must wait while first is active")
        }
        guard sequence.current == enter else {
            throw SequenceTestFailure("enter request must remain active until completion")
        }
        guard sequence.finishCurrent() == leave else {
            throw SequenceTestFailure("leave request must start only after enter completes")
        }
        guard sequence.current == leave else {
            throw SequenceTestFailure("leave request must become active next")
        }
        guard sequence.finishCurrent() == nil, sequence.current == nil else {
            throw SequenceTestFailure("queue must become idle after final request")
        }

        sequence.enqueue(enter)
        sequence.enqueue(leave)
        sequence.reset()
        guard sequence.current == nil, sequence.finishCurrent() == nil else {
            throw SequenceTestFailure("reset must discard active and pending requests")
        }

        print("AutomationRequestSequenceTests: PASS")
    }

    static func testDisconnectAndLateHTTPCompletion() throws {
        let enter = AutomationRequest(path: "/ontime/break", transition: ProgramSceneTransition(
            previous: "LIVE", current: "PRZERWA_1", action: .enterBreak))
        let leave = AutomationRequest(path: "/ontime/leave-break", transition: ProgramSceneTransition(
            previous: "PRZERWA_1", current: "LIVE", action: .leaveBreak))
        var sequence = AutomationRequestSequence()
        assert(sequence.enqueue(enter) == enter)
        assert(sequence.enqueue(leave) == nil)
        sequence.discardPending() // OBS disconnected; the active HTTP action may already be applied.
        assert(sequence.current == enter, "Disconnect must preserve the active request")
        assert(sequence.finishCurrent() == nil, "Late completion must not dispatch the stale leave")

        // Reconnect establishes a new baseline, which must not recreate historical transitions.
        var obs = OBSConnectionStateMachine()
        let pattern = "^PRZERWA_.*$"
        let commands = try obs.handle(.identified, password: "", breakPattern: pattern)
        guard case .requestBaseline(let id) = commands.first else {
            throw SequenceTestFailure("Reconnect must request a new baseline")
        }
        let premature = try obs.handle(.programSceneChanged("LIVE"), password: "", breakPattern: pattern)
        assert(premature.isEmpty)
        let baseline = try obs.handle(.requestResponse(requestType: "GetCurrentProgramScene", requestId: id,
            success: true, responseData: ["sceneName": "PRZERWA_2"]), password: "", breakPattern: pattern)
        assert(baseline == [.connected(scene: "PRZERWA_2")])
        assert(sequence.current == nil)
        let fresh = try obs.handle(.programSceneChanged("LIVE"), password: "", breakPattern: pattern)
        guard case .transition(let transition) = fresh.first else {
            throw SequenceTestFailure("Fresh post-baseline transition must still work")
        }
        assert(transition.previous == "PRZERWA_2" && transition.action == .leaveBreak)

        // If a reconnect precedes the old HTTP response, only fresh queued work can follow it.
        sequence.enqueue(enter)
        sequence.enqueue(leave)
        sequence.discardPending()
        let newRequest = AutomationRequest(path: "/ontime/leave-break", transition: transition)
        assert(sequence.enqueue(newRequest) == nil)
        assert(sequence.finishCurrent() == newRequest)
        assert(sequence.finishCurrent() == nil)
        sequence.discardPending()
        sequence.discardPending()
        assert(sequence.current == nil)
    }

}

struct SequenceTestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
