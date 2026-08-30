import Foundation

struct AutomationRequest: Equatable {
    let path: String
    let transition: ProgramSceneTransition
}

struct AutomationRequestSequence {
    private(set) var current: AutomationRequest?
    private var pending: [AutomationRequest] = []

    @discardableResult
    mutating func enqueue(_ request: AutomationRequest) -> AutomationRequest? {
        guard current == nil else {
            pending.append(request)
            return nil
        }

        current = request
        return request
    }

    @discardableResult
    mutating func finishCurrent() -> AutomationRequest? {
        current = nil
        guard !pending.isEmpty else { return nil }

        let next = pending.removeFirst()
        current = next
        return next
    }

    mutating func reset() {
        current = nil
        pending.removeAll()
    }
}
