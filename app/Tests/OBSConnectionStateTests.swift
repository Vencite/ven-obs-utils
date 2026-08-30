import Foundation

@main
struct OBSConnectionStateTests {
    static func main() throws {
        let pattern = #"^PRZERWA_.*$"#
        var state = OBSConnectionStateMachine()

        let hello = OBSProtocolMessage.hello(rpcVersion: 1, challenge: nil, salt: nil)
        try expectSingle(try state.handle(hello, password: "", breakPattern: pattern), kind: .identify)

        let baselineCommands = try state.handle(.identified, password: "", breakPattern: pattern)
        guard case .requestBaseline(let requestId) = baselineCommands.first else {
            throw StateTestFailure("Identified must request Program baseline")
        }

        let premature = try state.handle(
            .programSceneChanged("PRZERWA_RANDOM"),
            password: "",
            breakPattern: pattern
        )
        guard premature.isEmpty else {
            throw StateTestFailure("Program event before baseline must not trigger automation")
        }

        let baseline = try state.handle(
            .requestResponse(
                requestType: "GetCurrentProgramScene",
                requestId: requestId,
                success: true,
                responseData: ["sceneName": "KAMERY_LIVE"]
            ),
            password: "",
            breakPattern: pattern
        )
        guard baseline == [.connected(scene: "KAMERY_LIVE")] else {
            throw StateTestFailure("baseline response should mark connection ready")
        }

        let transition = try state.handle(
            .programSceneChanged("PRZERWA_RANDOM"),
            password: "",
            breakPattern: pattern
        )
        guard transition.count == 1,
              case .transition(let value) = transition[0],
              value.previous == "KAMERY_LIVE",
              value.current == "PRZERWA_RANDOM",
              value.action == .enterBreak else {
            throw StateTestFailure("next Program event should emit enter-break transition")
        }

        state.resetForReconnect()
        let afterReset = try state.handle(
            .programSceneChanged("KAMERY_LIVE_DWA"),
            password: "",
            breakPattern: pattern
        )
        guard afterReset.isEmpty else {
            throw StateTestFailure("events after disconnect must wait for a fresh baseline")
        }

        var authState = OBSConnectionStateMachine()
        let authRequired = try authState.handle(
            .hello(rpcVersion: 1, challenge: "challenge", salt: "salt"),
            password: "",
            breakPattern: pattern
        )
        guard authRequired == [.authenticationRequired] else {
            throw StateTestFailure("auth challenge without password must stop at passwordRequired")
        }

        let authCommands = try authState.handle(
            .hello(rpcVersion: 1, challenge: "challenge", salt: "salt"),
            password: "secret",
            breakPattern: pattern
        )
        guard authCommands.count == 1,
              case .identify(let rpcVersion, let authentication) = authCommands[0],
              rpcVersion == 1,
              authentication == OBSProtocolCodec.authentication(password: "secret", salt: "salt", challenge: "challenge") else {
            throw StateTestFailure("auth challenge should produce Identify authentication")
        }

        print("OBSConnectionStateTests: PASS")
    }

    enum ExpectedKind { case identify }

    static func expectSingle(
        _ commands: [OBSConnectionCommand],
        kind: ExpectedKind
    ) throws {
        guard commands.count == 1 else { throw StateTestFailure("expected one command") }
        switch (kind, commands[0]) {
        case (.identify, .identify): return
        default: throw StateTestFailure("unexpected command")
        }
    }
}

struct StateTestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
