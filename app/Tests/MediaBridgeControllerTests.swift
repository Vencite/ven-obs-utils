import Foundation

// These stand-ins replace only the OBS transport; the controller and schema are production code.
@MainActor
final class OBSWebSocketClient {
    var state = fixture()
    var calls = 0
    var fail = false
    var gate: CheckedContinuation<Void, Never>?
    var block = false

    func request(_ type: String, data: [String: Any] = [:]) async throws -> [String: Any] {
        switch type {
        case "GetCurrentProgramScene": return ["currentProgramSceneName": "Program"]
        case "GetInputList": return ["inputs": [["inputUuid": state["source_uuid"] as? String ?? "source", "inputName": "MPS", "inputKind": "media_playlist_source_codeyan"]]]
        case "CallVendorRequest":
            calls += 1
            let captured = state
            if block { await withCheckedContinuation { gate = $0 } }
            if fail { throw MPSStateError.invalid("OBS unavailable") }
            return ["responseData": captured]
        default: throw MPSStateError.invalid("Unexpected request: \(type)")
        }
    }
}

enum OBSProtocolCodec {
    static func programSceneName(from value: [String: Any]) -> String? { value["currentProgramSceneName"] as? String }
}

func fixture(_ state: String = "paused", revision: Int = 1) -> [String: Any] {
    ["success": true, "schema_version": 1, "source_uuid": "source", "source_name": "MPS",
     "state": state, "snapshot_revision": revision, "remaining_known": true, "remaining_ms": 9000,
     "playlist_remaining_known": false, "items_remaining_known": false,
     "shuffle": false, "loop": false, "has_next": false, "has_previous": false]
}

final class IPCProtocol: URLProtocol {
    static let lock = NSLock()
    static var paths: [String] = []
    static var fail = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.paths.append(request.url!.path)
        let failed = Self.fail
        Self.lock.unlock()
        if failed {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    static func count(_ path: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return paths.filter { $0 == path }.count
    }
    static func setFailure(_ value: Bool) { lock.lock(); defer { lock.unlock() }; fail = value }
}

@main
struct MediaBridgeControllerTests {
    @MainActor
    static func wait(_ condition: () -> Bool) async {
        for _ in 0..<2000 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        fatalError("Asynchronous condition did not complete")
    }

    @MainActor
    static func drain() async {
        // Scheduler settling only; all heartbeat time is supplied by the fake clock.
        for _ in 0..<10 { try? await Task.sleep(nanoseconds: 1_000_000) }
    }

    @MainActor
    static func main() async {
        let obs = OBSWebSocketClient()
        var clock: TimeInterval = 100
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [IPCProtocol.self]
        let http = URLSession(configuration: config)
        defer { http.invalidateAndCancel() }
        let bridge = MediaBridgeController(obs: obs, now: { clock }, http: http)
        var latest: [String: Any] = [:]
        bridge.onState = { latest = $0 }
        bridge.configure(["enabled": true, "source_mode": "explicit", "source_uuid": "source"], port: 8765, token: "test")
        bridge.connectionChanged(true)
        await wait { latest["state"] as? String == "paused" }
        await drain()
        let initialSnapshots = IPCProtocol.count("/media/_snapshot")
        for _ in 0..<90 {
            clock += 2
            bridge.heartbeat()
            await drain()
            assert(latest["state"] as? String == "paused")
            assert(latest["remaining_ms"] as? Int == 9000)
        }
        assert(obs.calls >= 40 && obs.calls <= 50, "Idle probing must be bounded")
        assert(IPCProtocol.count("/media/_heartbeat") > 0)
        assert(IPCProtocol.count("/media/_snapshot") == initialSnapshots, "Idle probes must not republish unchanged data")

        obs.state = fixture("playing", revision: 2)
        clock += 4
        bridge.heartbeat()
        await wait { latest["state"] as? String == "playing" }
        await drain()
        obs.state = fixture("paused", revision: 3)
        clock += 4
        bridge.heartbeat()
        await wait { latest["state"] as? String == "paused" }
        await drain()

        bridge.connectionChanged(false)
        assert(latest["available"] as? Bool == false)
        bridge.connectionChanged(true)
        await wait { latest["state"] as? String == "paused" }
        await drain()

        // A response from the previous generation cannot restore a disconnected source.
        obs.block = true
        clock += 4
        bridge.heartbeat()
        await wait { obs.gate != nil }
        bridge.connectionChanged(false)
        obs.block = false
        obs.gate?.resume()
        obs.gate = nil
        await drain()
        assert(latest["available"] as? Bool == false)
        bridge.connectionChanged(true)
        await wait { latest["state"] as? String == "paused" }
        await drain()

        obs.fail = true
        clock += 4
        bridge.heartbeat()
        await wait { latest["available"] as? Bool == false }
        await drain()
        obs.fail = false
        clock += 4
        bridge.heartbeat()
        await wait { latest["state"] as? String == "paused" }
        await drain()

        IPCProtocol.setFailure(true)
        bridge.heartbeat()
        await wait { latest["reason"] as? String == "Media helper unavailable" }
        IPCProtocol.setFailure(false)
        clock += 4
        bridge.heartbeat()
        await wait { latest["state"] as? String == "paused" }
        await drain()
        assert(IPCProtocol.count("/media/_session") >= 2)
        for state in ["stopped", "unknown"] {
            obs.state = fixture(state, revision: 4)
            clock += 4
            bridge.heartbeat()
            await wait { latest["state"] as? String == state }
            await drain()
        }
        obs.block = true
        clock += 4
        bridge.heartbeat()
        await wait { obs.gate != nil }
        let previousRequest = obs.gate
        obs.gate = nil
        obs.block = false
        obs.state = fixture("paused", revision: 1)
        obs.state["source_uuid"] = "other-source"
        bridge.configure(["enabled": true, "source_mode": "explicit", "source_uuid": "other-source"], port: 8765, token: "test")
        previousRequest?.resume()
        await wait { latest["source_uuid"] as? String == "other-source" }
        await drain()
        assert(latest["source_uuid"] as? String == "other-source")
        bridge.configure(["enabled": false], port: 8765, token: "test")
        assert(latest["reason"] as? String == "disabled")
        print("MediaBridgeControllerTests: PASS")
    }
}
