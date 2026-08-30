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
