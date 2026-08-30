import Foundation

@main
struct AutomationRequestSequenceTests {
    static func main() throws {
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
}

struct SequenceTestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
