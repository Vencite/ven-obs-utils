import Foundation

@main
struct ServiceRestartPolicyTests {
    static func main() throws {
        try testNonzeroExitDoesNotRestartService()
        try testUnexpectedCleanExitRestartsService()
        print("ServiceRestartPolicyTests: PASS")
    }

    static func testNonzeroExitDoesNotRestartService() throws {
        guard !ServiceRestartPolicy.shouldRestart(shouldRun: true, terminationStatus: 1) else {
            throw ServiceRestartPolicyTestFailure("A failed helper must not enter a restart loop")
        }
    }

    static func testUnexpectedCleanExitRestartsService() throws {
        guard ServiceRestartPolicy.shouldRestart(shouldRun: true, terminationStatus: 0) else {
            throw ServiceRestartPolicyTestFailure("An unexpected clean helper exit should restart")
        }
    }
}

struct ServiceRestartPolicyTestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
