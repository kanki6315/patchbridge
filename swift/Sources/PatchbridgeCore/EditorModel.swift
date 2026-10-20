import Foundation
import Combine

final class EditorModel: ObservableObject {
    @Published var status = "Ready to find your Mac"
    @Published var connected = false
    @Published var ready = false
    @Published var busy = false
    @Published var needsApproval = false
    @Published var error: String?
    @Published var preset = "Simulation"
    @Published var scene = "A"
    @Published var gain = 5.0
    @Published var confirmedGain = 5.0
    @Published var dirty = false
    @Published var lastResult = ""
    private var central: EditorTransport?
    private let makeTransport: () -> EditorTransport
    init(makeTransport: @escaping () -> EditorTransport = { BLECentral() }) { self.makeTransport = makeTransport }
    private var connectionID: String?
    private var sessionID: String?
    private var revision = 0
    private var presetID = "1"
    private var pendingID: String?
    private var pendingOperation: String?

    func scan() {
        error = nil
        if central == nil {
            let transport = makeTransport()
            transport.onStatus = { [weak self] message in self?.status = message }
            transport.onReady = { [weak self] in
                guard let self else { return }
                self.connected = true
                self.send("hello")
            }
            transport.onDisconnected = { [weak self] in self?.clear() }
            transport.onResponse = { [weak self] response in self?.receive(response) }
            central = transport
        } else { central?.reconnect() }
        status = "Looking for Patchbridge Demo…"
    }
    func disconnect() {
        central?.disconnect()
        clear()
        status = "Disconnected"
    }
    private func clear() {
        connected = false; ready = false; busy = false; needsApproval = false
        connectionID = nil; sessionID = nil; pendingID = nil; pendingOperation = nil
        gain = confirmedGain
    }
    func authorize() { send("connect") }
    func refresh() { send("snapshot") }
    func save() { guard ready else { return }; send("save") }
    func changeScene(_ newScene: String) { send("select_scene", payload: ["scene": newScene]) }
    func commitGain() {
        guard ready, gain.isFinite, (0...10).contains(gain), gain != confirmedGain else { gain = confirmedGain; return }
        send("set_parameter", payload: ["block_id": "amp-1", "parameter_id": "gain", "value": gain])
    }
    private func send(_ operation: String, payload: [String: Any] = [:]) {
        guard !busy, let central else { return }
        let id = UUID().uuidString
        var request: [String: Any] = ["version": 1, "id": id, "operation": operation, "payload": payload]
        if let connectionID { request["connection_id"] = connectionID }
        if let sessionID { request["session_id"] = sessionID }
        request["revision"] = revision; request["preset_id"] = presetID; request["scene"] = scene
        do {
            busy = true; error = nil; pendingID = id; pendingOperation = operation
            try central.send(request)
        } catch {
            busy = false; pendingID = nil; pendingOperation = nil
            gain = confirmedGain
            self.error = "Couldn’t send the command. Disconnect and try again."
        }
    }
    private func invalidate(_ message: String) {
        disconnect(); error = message
    }
    private func receive(_ response: [String: Any]) {
        guard let expectedID = pendingID, response["id"] as? String == expectedID else { return }
        let operation = pendingOperation
        pendingID = nil; pendingOperation = nil; busy = false
        if operation == "hello" { connectionID = response["connection_id"] as? String }
        else if response["connection_id"] as? String != connectionID { invalidate("Connection changed. Reconnect to your Mac."); return }
        if operation == "hello", response["version"] as? Int == 1,
           response["authorization_required"] as? Bool == true, connectionID != nil {
            needsApproval = true; status = "Approve this iPhone on your Mac"
            return
        }
        guard response["version"] as? Int == 1 else { invalidate("Unsupported bridge protocol."); return }
        guard response["status"] as? String == "confirmed" else {
            let detail = (response["error"] as? [String: Any])?["message"] as? String ?? response["error"] as? String ?? "Unknown bridge error"
            error = detail == "unauthorized" ? "Approval is still needed on the Mac. Approve there, then try again." : detail
            gain = confirmedGain
            if operation != "connect", response["session_id"] is NSNull { ready = false; needsApproval = true }
            return
        }
        guard let newSession = response["session_id"] as? String,
              let newRevision = response["revision"] as? Int, newRevision >= 0,
              operation == "connect" || (newSession == sessionID && newRevision >= revision) else {
            invalidate("The bridge returned stale state. Reconnect to your Mac."); return
        }
        if ["set_parameter", "save", "select_scene"].contains(operation ?? ""), newRevision <= revision {
            invalidate("The edit was not confirmed with fresh state. Reconnect to your Mac."); return
        }
        sessionID = newSession
        revision = newRevision
        if let result = response["result"] as? [String: Any], let state = result["state"] as? [String: Any] {
            guard let blocks = state["blocks"] as? [[String: Any]],
                  let amp = blocks.first(where: { $0["id"] as? String == "amp-1" }),
                  let sceneName = state["scene"] as? String,
                  let scenes = amp["scenes"] as? [String: [String: Any]],
                  let values = scenes[sceneName]?["parameters"] as? [String: Any],
                  let value = values["gain"] as? Double, value.isFinite, (0...10).contains(value),
                  ["A", "B"].contains(sceneName), let name = state["name"] as? String,
                  let id = state["preset_id"] as? String, let savedDirty = state["dirty"] as? Bool else {
                invalidate("Unexpected simulation state. Disconnect and reconnect."); return
            }
            if operation == "save" && savedDirty {
                invalidate("The preset is still unsaved. Reconnect and check its state."); return
            }
            preset = name
            presetID = id
            scene = sceneName; gain = value; confirmedGain = value; dirty = savedDirty
            ready = true; needsApproval = false; status = "Connected to Mac"
            lastResult = operation == "save" ? "Saved in the Mac simulation" : "Confirmed by Mac"
        } else { invalidate("The bridge omitted confirmed state. Reconnect to your Mac.") }
    }
}
