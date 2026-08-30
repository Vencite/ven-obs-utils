import Foundation

@main
struct OBSWebSocketClientTests {
    static func main() throws {
        try testWebSocketURL()
        try testAutomationRouting()
        print("OBSWebSocketClientTests: PASS")
    }

    static func testWebSocketURL() throws {
        let url = try OBSWebSocketEndpoint.makeURL(host: "127.0.0.1", port: 4455)
        guard url.absoluteString == "ws://127.0.0.1:4455" else {
            throw OBSWebSocketClientTestFailure("unexpected OBS websocket URL: \(url.absoluteString)")
        }
    }

    static func testAutomationRouting() throws {
        guard OntimeAutomationRoute.path(
            for: .enterBreak,
            enterEnabled: true,
            leaveEnabled: true
        ) == "/ontime/break" else {
            throw OBSWebSocketClientTestFailure("enterBreak should route to /ontime/break")
        }

        guard OntimeAutomationRoute.path(
            for: .leaveBreak,
            enterEnabled: true,
            leaveEnabled: true
        ) == "/ontime/leave-break" else {
            throw OBSWebSocketClientTestFailure("leaveBreak should route to /ontime/leave-break")
        }

        guard OntimeAutomationRoute.path(
            for: .enterBreak,
            enterEnabled: false,
            leaveEnabled: true
        ) == nil else {
            throw OBSWebSocketClientTestFailure("disabled enterBreak must not route")
        }

        guard OntimeAutomationRoute.path(
            for: .leaveBreak,
            enterEnabled: true,
            leaveEnabled: false
        ) == nil else {
            throw OBSWebSocketClientTestFailure("disabled leaveBreak must not route")
        }

        guard OntimeAutomationRoute.path(
            for: .ignore,
            enterEnabled: true,
            leaveEnabled: true
        ) == nil else {
            throw OBSWebSocketClientTestFailure("ignore must not route")
        }
    }
}

struct OBSWebSocketClientTestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
