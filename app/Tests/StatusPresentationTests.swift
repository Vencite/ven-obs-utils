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
        print("StatusPresentationTests: PASS")
    }
}

struct StatusPresentationTestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
