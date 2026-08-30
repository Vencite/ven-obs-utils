import CryptoKit
import Foundation

enum OBSProtocolMessage {
    case hello(rpcVersion: Int, challenge: String?, salt: String?)
    case identified
    case programSceneChanged(String)
    case requestResponse(
        requestType: String,
        requestId: String,
        success: Bool,
        responseData: [String: Any]
    )
    case ignored
}

enum OBSProtocolError: LocalizedError {
    case invalidJSON
    case invalidMessage(String)

    var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "OBS sent invalid JSON"
        case .invalidMessage(let message):
            return "Invalid OBS WebSocket message: \(message)"
        }
    }
}

enum OBSProtocolCodec {
    static func authentication(password: String, salt: String, challenge: String) -> String {
        let secretInput = Data((password + salt).utf8)
        let secret = Data(SHA256.hash(data: secretInput)).base64EncodedString()
        let authInput = Data((secret + challenge).utf8)
        return Data(SHA256.hash(data: authInput)).base64EncodedString()
    }

    static func parse(_ text: String) throws -> OBSProtocolMessage {
        guard let data = text.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let op = integer(root["op"]),
              let payload = root["d"] as? [String: Any] else {
            throw OBSProtocolError.invalidJSON
        }

        switch op {
        case 0:
            guard let rpcVersion = integer(payload["rpcVersion"]) else {
                throw OBSProtocolError.invalidMessage("Hello is missing rpcVersion")
            }
            if let auth = payload["authentication"] as? [String: Any] {
                guard let challenge = auth["challenge"] as? String,
                      let salt = auth["salt"] as? String else {
                    throw OBSProtocolError.invalidMessage("Hello authentication challenge is incomplete")
                }
                return .hello(rpcVersion: rpcVersion, challenge: challenge, salt: salt)
            }
            return .hello(rpcVersion: rpcVersion, challenge: nil, salt: nil)

        case 2:
            return .identified

        case 5:
            guard let eventType = payload["eventType"] as? String else {
                throw OBSProtocolError.invalidMessage("Event is missing eventType")
            }
            guard eventType == "CurrentProgramSceneChanged" else {
                return .ignored
            }
            guard let eventData = payload["eventData"] as? [String: Any],
                  let sceneName = eventData["sceneName"] as? String,
                  !sceneName.isEmpty else {
                throw OBSProtocolError.invalidMessage("Program scene event is missing sceneName")
            }
            return .programSceneChanged(sceneName)

        case 7:
            guard let requestType = payload["requestType"] as? String,
                  let requestId = payload["requestId"] as? String,
                  let status = payload["requestStatus"] as? [String: Any],
                  let success = status["result"] as? Bool else {
                throw OBSProtocolError.invalidMessage("RequestResponse is incomplete")
            }
            return .requestResponse(
                requestType: requestType,
                requestId: requestId,
                success: success,
                responseData: payload["responseData"] as? [String: Any] ?? [:]
            )

        default:
            return .ignored
        }
    }

    static func identifyJSON(rpcVersion: Int, authentication: String?) throws -> String {
        var payload: [String: Any] = ["rpcVersion": rpcVersion]
        if let authentication, !authentication.isEmpty {
            payload["authentication"] = authentication
        }
        return try encode(["op": 1, "d": payload])
    }

    static func requestJSON(requestType: String, requestId: String) throws -> String {
        try encode([
            "op": 6,
            "d": [
                "requestType": requestType,
                "requestId": requestId,
            ],
        ])
    }

    static func programSceneName(from responseData: [String: Any]) -> String? {
        if let sceneName = responseData["sceneName"] as? String, !sceneName.isEmpty {
            return sceneName
        }
        if let legacy = responseData["currentProgramSceneName"] as? String, !legacy.isEmpty {
            return legacy
        }
        return nil
    }

    private static func encode(_ object: [String: Any]) throws -> String {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw OBSProtocolError.invalidMessage("Cannot encode JSON object")
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let text = String(data: data, encoding: .utf8) else {
            throw OBSProtocolError.invalidMessage("Cannot encode UTF-8 JSON")
        }
        return text
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }
}
