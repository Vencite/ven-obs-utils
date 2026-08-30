import Foundation

enum ServiceRestartPolicy {
    static func shouldRestart(shouldRun: Bool, terminationStatus: Int32) -> Bool {
        shouldRun && terminationStatus == 0
    }
}
