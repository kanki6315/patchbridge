#if DEBUG
import Foundation

/// A bridge in the app's own process, for the simulator and UI tests: `--offline-bridge`. It
/// answers like the Mac does, from the demo preset, so the live coordinator's flows (listing,
/// switching, saving first) run without Bluetooth or a QC. Never built into Release.
final class DebugBridge: EditorTransport {
    var onReady: (() -> Void)?
    var onDisconnected: (() -> Void)?
    var onStatus: ((String) -> Void)?
    var onResponse: (([String: Any]) -> Void)?
    /// How long the directory read takes, like the QC's (about 12 s) but shorter.
    static var listDelay: TimeInterval = 3
    private var revision = 0
    private var catalog: [String: Any] = [:]
    private var state: [String: Any] = [:]
    private var saved: [String: [String: Any]] = [:]
    private let names = [9: "Ambient Swells", 10: "Octave Fuzz", 11: "Acoustic Sim", 12: "Worship Clean", 14: "Drop D Chug",
                         15: "Blues Lead", 17: "Solo Delay", 18: "Funk Wah"]
    private var listed = false
    /// With `--dirty`, the first poll finds a value turned on the QC itself.
    private var qcEdit: Bool

    init(dirty: Bool) {
        qcEdit = dirty
        guard let url = Bundle.main.url(forResource: "demo-preset", withExtension: "json"),
              let document = try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              var snapshot = document["snapshot"] as? [String: Any] else { return }
        catalog = document["catalog"] as? [String: Any] ?? [:]
        snapshot["dirty"] = false
        for (number, name) in names { saved["slot-\(number)"] = preset(snapshot, number: number, name: name) }
        saved["slot-16"] = preset(snapshot, number: 16, name: snapshot["name"] as? String ?? "Dirty Riffage")
        state = saved["slot-16"]!
    }
    private func preset(_ base: [String: Any], number: Int, name: String) -> [String: Any] {
        var preset = base
        preset["preset_id"] = "slot-\(number)"; preset["name"] = name
        preset["location"] = ["source": "My Presets", "number": number]
        return preset
    }
    /// The demo's first editable value nudged, as if turned on the phone.
    private func edited(_ preset: [String: Any]) -> [String: Any] {
        var preset = preset; preset["dirty"] = true
        guard var blocks = preset["blocks"] as? [[String: Any]], let scene = preset["scene"] as? String else { return preset }
        for index in blocks.indices {
            guard let editable = blocks[index]["editable_parameters"] as? [String], let id = editable.first,
                  var scenes = blocks[index]["scenes"] as? [String: [String: Any]],
                  var parameters = scenes[scene]?["parameters"] as? [String: Any], let value = parameters[id] as? Double else { continue }
            parameters[id] = value > 0.5 ? value - 0.12 : value + 0.12
            scenes[scene]?["parameters"] = parameters; blocks[index]["scenes"] = scenes
            preset["blocks"] = blocks
            return preset
        }
        return preset
    }

    func reconnect() { DispatchQueue.main.async { self.onReady?() } }
    func disconnect() {}
    func send(_ message: [String: Any]) throws {
        let operation = message["operation"] as? String ?? ""
        var reply: [String: Any] = ["version": 1, "id": message["id"] ?? "", "connection_id": "debug", "session_id": "debug"]
        var delay: TimeInterval = 0.15
        func confirm(_ result: [String: Any]) { reply["status"] = "confirmed"; reply["result"] = result }
        func refuse(_ code: String, _ text: String) { reply["status"] = "error"; reply["error"] = ["code": code, "message": text] }
        switch operation {
        case "hello":
            reply = ["version": 1, "id": message["id"] ?? "", "connection_id": "debug", "authorization_required": true,
                     "mac_name": "Debug bridge", "approval_code": "000000"]
        case "connect": confirm(["device": ["id": "debug", "name": "Debug QC"], "state": state])
        case "capabilities":
            confirm(["protocol_version": 1, "operations": ["snapshot", "catalog", "set_parameter", "set_bypass", "select_scene",
                                                            "save", "list_presets", "select_preset"]])
        case "catalog": confirm(catalog)
        case "snapshot":
            if qcEdit { qcEdit = false; state = edited(state); revision += 1 }
            confirm(["state": state])
        case "list_presets":
            delay = Self.listDelay; listed = true
            let entries = saved.values.compactMap { preset -> [String: Any]? in
                guard let location = preset["location"] as? [String: Any] else { return nil }
                return ["preset_id": preset["preset_id"]!, "number": location["number"]!, "name": preset["name"]!]
            }
            confirm(["presets": ["source": "My Presets", "slots": 256, "entries": entries]])
        case "select_preset":
            let payload = message["payload"] as? [String: Any] ?? [:]
            guard listed, let id = payload["preset_id"] as? String, let target = saved[id] else { refuse("invalid_value", "Unknown slot."); break }
            if state["dirty"] as? Bool == true && payload["discard"] as? Bool != true { refuse("unsaved_changes", "Unsaved edits."); break }
            delay = 1.2; state = target; revision += 1; confirm(["state": state])
        case "save":
            delay = 0.8; state["dirty"] = false; saved[state["preset_id"] as! String] = state; revision += 1; confirm(["state": state])
        case "select_scene":
            state["scene"] = (message["payload"] as? [String: Any])?["scene"]; revision += 1; confirm(["state": state])
        case "set_parameter", "set_bypass":
            let payload = message["payload"] as? [String: Any] ?? [:]
            guard var blocks = state["blocks"] as? [[String: Any]], let scene = state["scene"] as? String,
                  let index = blocks.firstIndex(where: { $0["id"] as? String == payload["block_id"] as? String }),
                  var scenes = blocks[index]["scenes"] as? [String: [String: Any]] else { refuse("invalid_value", "Unknown block."); break }
            if operation == "set_bypass" { scenes[scene]?["bypass"] = payload["value"] }
            else if let parameter = payload["parameter_id"] as? String {
                var parameters = scenes[scene]?["parameters"] as? [String: Any] ?? [:]
                parameters[parameter] = payload["value"]; scenes[scene]?["parameters"] = parameters
            }
            blocks[index]["scenes"] = scenes; state["blocks"] = blocks; state["dirty"] = true; revision += 1
            confirm(["state": state])
        case "disconnect": confirm([:])
        default: refuse("unsupported_operation", "Not in the debug bridge.")
        }
        if reply["status"] != nil { reply["revision"] = revision }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.onResponse?(reply) }
    }
}
#endif
