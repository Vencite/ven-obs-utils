import Foundation

@MainActor
final class MediaBridgeController {
    var onState: (([String: Any]) -> Void)?
    private let obs: OBSWebSocketClient
    private var config: [String: Any] = [:]
    private var port = 8765
    private var token = ""
    private var session = UUID().uuidString
    private var sequence = 0
    private var generation = 0
    private var connected = false
    private var helperReady = false
    private var selectedUUID: String?
    private var program = ""
    private var observedScenes = Set<String>()
    private var snapshot = MPSState.unavailable(reason: "disabled")
    private var resolveTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    private var deliveryEpoch = 0
    private var receivedAt = Date.distantPast
    private var dirty = false
    private var pendingEvent: [String: Any]?

    init(obs: OBSWebSocketClient) { self.obs = obs }

    func configure(_ config: [String: Any], port: Int, token: String) {
        deliveryEpoch += 1
        flushTask?.cancel()
        flushTask = nil
        self.config = config
        self.port = port
        self.token = token
        session = UUID().uuidString
        sequence = 0
        helperReady = false
        refresh()
    }

    func connectionChanged(_ connected: Bool) {
        self.connected = connected
        if !connected { program = "" }
        refresh()
    }

    func programChanged(_ name: String) {
        program = name
        if config["source_mode"] as? String != "explicit" { refresh() }
        else if selectedUUID == nil { refresh() }
    }

    func receive(type: String, data: [String: Any]) {
        guard config["enabled"] as? Bool == true else { return }
        guard type == "VendorEvent" else {
            let mode = config["source_mode"] as? String ?? "follow_program"
            if type == "InputRemoved" || type == "InputNameChanged" || type == "InputCreated" {
                if let uuid = data["inputUuid"] as? String, uuid == selectedUUID { refresh() }
                else if mode == "explicit", selectedUUID == nil {
                    let configuredUUID = config["source_uuid"] as? String ?? ""
                    let configuredName = config["source_name"] as? String ?? ""
                    if (!configuredUUID.isEmpty && data["inputUuid"] as? String == configuredUUID) ||
                       (configuredUUID.isEmpty && !configuredName.isEmpty && data["inputName"] as? String == configuredName) { refresh() }
                }
            } else if mode == "follow_program" {
                if let scene = data["sceneName"] as? String, observedScenes.contains(scene) || scene == program {
                    if type != "SceneItemListReindexed" { refresh() }
                } else if type == "SceneNameChanged", let old = data["oldSceneName"] as? String,
                          observedScenes.contains(old) { refresh() }
                else if type == "SceneListChanged", let scenes = data["scenes"] as? [[String: Any]] {
                    let names = Set(scenes.compactMap { $0["sceneName"] as? String })
                    if !names.contains(program) { refresh() }
                }
            }
            return
        }
        guard data["vendorName"] as? String == "media-playlist-source",
              data["eventType"] as? String == "PlaylistStateChanged",
              let payload = data["eventData"] as? [String: Any],
              payload["source_uuid"] as? String == selectedUUID else { return }
        do {
            let state = try MPSState(payload).payload
            if resolveTask != nil {
                if (MPSState.integer(state["snapshot_revision"]) ?? 0) >= (MPSState.integer(pendingEvent?["snapshot_revision"]) ?? 0) {
                    pendingEvent = state
                }
                return
            }
            let revision = MPSState.integer(state["snapshot_revision"]) ?? 0
            let previous = MPSState.integer(snapshot["snapshot_revision"]) ?? 0
            if revision < previous { refresh(); return }
            publish(state)
        } catch { publish(MPSState.unavailable(reason: error.localizedDescription)) }
    }

    func refresh() {
        generation += 1
        let current = generation
        resolveTask?.cancel()
        resolveTask = nil
        selectedUUID = nil
        pendingEvent = nil
        publish(MPSState.unavailable(reason: config["enabled"] as? Bool == true ? "waiting_for_snapshot" : "disabled"))
        guard config["enabled"] as? Bool == true, connected else { return }
        resolveTask = Task { [weak self] in
            guard let self else { return }
            do {
                let baseline = try await obs.request("GetCurrentProgramScene")
                guard generation == current else { return }
                guard let name = OBSProtocolCodec.programSceneName(from: baseline) else {
                    throw MPSStateError.invalid("Missing Program baseline")
                }
                program = name
                let response = try await obs.request("GetInputList")
                guard generation == current else { return }
                guard let inputs = response["inputs"] as? [[String: Any]] else {
                    throw MPSStateError.invalid("Invalid OBS input list")
                }
                var sceneMap: [String: [[String: Any]]] = [:]
                let mode = config["source_mode"] as? String ?? "follow_program"
                if mode == "follow_program" {
                    let list = try await obs.request("GetSceneList")
                    guard generation == current else { return }
                    let names = Set((list["scenes"] as? [[String: Any]] ?? []).compactMap { $0["sceneName"] as? String })
                    try await loadScene(name, group: false, names: names, ancestors: [], into: &sceneMap, generation: current)
                }
                guard generation == current else { return }
                observedScenes = Set(sceneMap.keys)
                let uuid = try MPSSelection.resolve(inputs: inputs, scenes: sceneMap, program: name,
                    sourceMode: mode, sourceUUID: config["source_uuid"] as? String ?? "",
                    sourceName: config["source_name"] as? String ?? "")
                observedScenes = Set(sceneMap.keys)
                selectedUUID = uuid
                let result = try await obs.request("CallVendorRequest", data: [
                    "vendorName": "media-playlist-source", "requestType": "GetPlaylistState",
                    "requestData": ["source_uuid": uuid],
                ])
                guard generation == current else { return }
                guard let payload = result["responseData"] as? [String: Any],
                      MPSState.boolean(payload["success"]) == true else {
                    throw MPSStateError.invalid("MPS Vendor API unavailable")
                }
                let state = try MPSState(payload).payload
                guard state["source_uuid"] as? String == uuid else { throw MPSStateError.invalid("MPS source mismatch") }
                resolveTask = nil
                if let event = pendingEvent,
                   (MPSState.integer(event["snapshot_revision"]) ?? 0) >= (MPSState.integer(state["snapshot_revision"]) ?? 0) {
                    publish(event)
                } else { publish(state) }
                pendingEvent = nil
            } catch {
                guard generation == current else { return }
                resolveTask = nil
                publish(MPSState.unavailable(reason: error.localizedDescription))
            }
        }
    }

    private func loadScene(_ name: String, group: Bool, names: Set<String>, ancestors: Set<String>,
                           into scenes: inout [String: [[String: Any]]], generation current: Int) async throws {
        guard generation == current, !Task.isCancelled else { throw CancellationError() }
        guard ancestors.count < 32, !ancestors.contains(name), scenes.count < 256 else {
            throw MPSStateError.invalid("Scene nesting limit or cycle")
        }
        if scenes[name] != nil { return }
        let data = try await obs.request(group ? "GetGroupSceneItemList" : "GetSceneItemList", data: ["sceneName": name])
        guard generation == current else { throw CancellationError() }
        guard let items = data["sceneItems"] as? [[String: Any]], items.count <= 4096 else {
            throw MPSStateError.invalid("Invalid scene items")
        }
        scenes[name] = items
        var ancestors = ancestors
        ancestors.insert(name)
        for item in items {
            guard MPSState.boolean(item["sceneItemEnabled"]) == true,
                  let child = item["sourceName"] as? String else { continue }
            let isGroup = MPSState.boolean(item["isGroup"]) == true
            if isGroup || names.contains(child) {
                try await loadScene(child, group: isGroup, names: names, ancestors: ancestors, into: &scenes, generation: current)
            }
        }
    }

    private func publish(_ value: [String: Any]) {
        snapshot = value
        if value["available"] as? Bool == true { receivedAt = Date() }
        onState?(value)
        dirty = true
        heartbeat()
    }

    func heartbeat() {
        guard config["enabled"] as? Bool == true, !token.isEmpty, flushTask == nil else { return }
        if snapshot["state"] as? String == "playing", Date().timeIntervalSince(receivedAt) > 5, resolveTask == nil {
            refresh()
            return
        }
        let epoch = deliveryEpoch
        flushTask = Task { [weak self] in
            guard let self else { return }
            defer { if deliveryEpoch == epoch { flushTask = nil } }
            do {
                if !helperReady {
                    _ = try await ipc("/media/_session", body: ["session": session])
                    guard epoch == deliveryEpoch else { return }
                    helperReady = true
                    // A restarted helper resumes only after a new authoritative OBS snapshot.
                    if connected { refresh() }
                }
                repeat {
                    dirty = false
                    sequence += 1
                    let currentSession = session
                    _ = try await ipc("/media/_snapshot", body: ["session": currentSession, "sequence": sequence, "snapshot": snapshot])
                    guard epoch == deliveryEpoch, currentSession == session else { return }
                } while dirty
                let data = try await ipc("/media/_controls")
                guard epoch == deliveryEpoch else { return }
                if let actions = data["controls"] as? [[String: Any]] {
                    for action in actions {
                        guard epoch == deliveryEpoch else { return }
                        await control(action)
                    }
                }
            } catch {
                guard epoch == deliveryEpoch else { return }
                helperReady = false
                snapshot = MPSState.unavailable(reason: "Media helper unavailable")
                onState?(snapshot)
            }
        }
    }

    private func control(_ command: [String: Any]) async {
        guard let id = command["id"] as? String else { return }
        let currentGeneration = generation
        var result: [String: Any] = ["status": "ignored", "reason": "stale_source"]
        if command["session"] as? String == session,
           let uuid = selectedUUID, uuid == command["source_uuid"] as? String,
           snapshot["available"] as? Bool == true, connected,
           let action = command["action"] as? String {
            let actions = ["play": "OBS_WEBSOCKET_MEDIA_INPUT_ACTION_PLAY", "pause": "OBS_WEBSOCKET_MEDIA_INPUT_ACTION_PAUSE",
                "next": "OBS_WEBSOCKET_MEDIA_INPUT_ACTION_NEXT", "previous": "OBS_WEBSOCKET_MEDIA_INPUT_ACTION_PREVIOUS",
                "restart": "OBS_WEBSOCKET_MEDIA_INPUT_ACTION_RESTART", "stop": "OBS_WEBSOCKET_MEDIA_INPUT_ACTION_STOP"]
            if let mediaAction = actions[action] {
                do {
                    _ = try await obs.request("TriggerMediaInputAction", data: ["inputUuid": uuid, "mediaAction": mediaAction])
                    result = ["status": "success"]
                } catch { result = ["status": "error", "reason": error.localizedDescription] }
            }
        }
        if generation != currentGeneration { result = ["status": "error", "reason": "source_changed_during_action"] }
        _ = try? await ipc("/media/_control-result", body: ["id": id, "result": result])
    }

    private func ipc(_ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { throw MPSStateError.invalid("Invalid helper URL") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MPSStateError.invalid("Media helper rejected state")
        }
        return result
    }
}
