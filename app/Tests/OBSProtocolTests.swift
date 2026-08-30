import Foundation

@main
struct OBSProtocolTests {
    static func main() throws {
        try testAuthenticationVector()
        try testHelloParsing()
        try testIdentifyMessage()
        try testProgramSceneEvent()
        try testPreviewSceneEventIsIgnored()
        try testCurrentProgramSceneResponse()
        try testRequestMessage()
        print("OBSProtocolTests: PASS")
    }

    static func testAuthenticationVector() throws {
        let auth = OBSProtocolCodec.authentication(
            password: "supersecretpassword",
            salt: "lM1GncleQOaCu9lT1yeUZhFYnqhsLLP1G5lAGo3ixaI=",
            challenge: "+IxH4CnCiqpX1rM9scsNynZzbOe4KhDeYcTNS3PDaeY="
        )
        guard auth == "1Ct943GAT+6YQUUX47Ia/ncufilbe6+oD6lY+5kaCu4=" else {
            throw OBSProtocolTestFailure("authentication vector mismatch")
        }
    }

    static func testHelloParsing() throws {
        let text = #"{"op":0,"d":{"rpcVersion":1,"obsStudioVersion":"30.2.2","obsWebSocketVersion":"5.5.2","authentication":{"challenge":"challenge","salt":"salt"}}}"#
        switch try OBSProtocolCodec.parse(text) {
        case .hello(let rpcVersion, let challenge, let salt):
            guard rpcVersion == 1, challenge == "challenge", salt == "salt" else {
                throw OBSProtocolTestFailure("hello fields mismatch")
            }
        default:
            throw OBSProtocolTestFailure("expected hello")
        }
    }

    static func testIdentifyMessage() throws {
        let text = try OBSProtocolCodec.identifyJSON(rpcVersion: 1, authentication: "secret")
        let root = try jsonObject(text)
        guard root["op"] as? Int == 1,
              let data = root["d"] as? [String: Any],
              data["rpcVersion"] as? Int == 1,
              data["authentication"] as? String == "secret" else {
            throw OBSProtocolTestFailure("identify JSON mismatch")
        }
    }

    static func testProgramSceneEvent() throws {
        let text = #"{"op":5,"d":{"eventType":"CurrentProgramSceneChanged","eventIntent":4,"eventData":{"sceneName":"PRZERWA_RANDOM"}}}"#
        switch try OBSProtocolCodec.parse(text) {
        case .programSceneChanged(let sceneName):
            guard sceneName == "PRZERWA_RANDOM" else {
                throw OBSProtocolTestFailure("program scene mismatch")
            }
        default:
            throw OBSProtocolTestFailure("expected program scene event")
        }
    }

    static func testPreviewSceneEventIsIgnored() throws {
        let text = #"{"op":5,"d":{"eventType":"CurrentPreviewSceneChanged","eventIntent":4,"eventData":{"sceneName":"PRZERWA_RANDOM"}}}"#
        switch try OBSProtocolCodec.parse(text) {
        case .ignored: break
        default: throw OBSProtocolTestFailure("preview scene event must be ignored")
        }
    }

    static func testCurrentProgramSceneResponse() throws {
        let text = #"{"op":7,"d":{"requestType":"GetCurrentProgramScene","requestId":"baseline","requestStatus":{"result":true,"code":100},"responseData":{"sceneName":"KAMERY_LIVE"}}}"#
        switch try OBSProtocolCodec.parse(text) {
        case .requestResponse(let requestType, let requestId, let success, let responseData):
            guard requestType == "GetCurrentProgramScene",
                  requestId == "baseline",
                  success,
                  OBSProtocolCodec.programSceneName(from: responseData) == "KAMERY_LIVE" else {
                throw OBSProtocolTestFailure("request response mismatch")
            }
        default:
            throw OBSProtocolTestFailure("expected request response")
        }
    }

    static func testRequestMessage() throws {
        let text = try OBSProtocolCodec.requestJSON(
            requestType: "GetCurrentProgramScene",
            requestId: "baseline"
        )
        let root = try jsonObject(text)
        guard root["op"] as? Int == 6,
              let data = root["d"] as? [String: Any],
              data["requestType"] as? String == "GetCurrentProgramScene",
              data["requestId"] as? String == "baseline" else {
            throw OBSProtocolTestFailure("request JSON mismatch")
        }
    }

    static func jsonObject(_ text: String) throws -> [String: Any] {
        let data = Data(text.utf8)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OBSProtocolTestFailure("invalid JSON object")
        }
        return root
    }
}

struct OBSProtocolTestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
