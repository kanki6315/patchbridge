#if os(macOS)
import Foundation

/// UI-only, bounded by the owner. Never persisted or included in diagnostics.
struct RecentBridgeEdit: Identifiable {
    enum Outcome: String { case confirmed = "Confirmed", adjusted = "Adjusted by device", rejected = "Not applied", unknown = "Outcome unknown" }
    let id = UUID()
    let date = Date()
    let title: String
    let context: String
    let value: String?
    let outcome: Outcome
    let detail: String

    init(request: [String: Any], response: [String: Any]?, snapshot: [String: Any]?, catalog: [String: Any]?) {
        let operation = request["operation"] as? String ?? ""
        let payload = request["payload"] as? [String: Any] ?? [:]
        let blockID = payload["block_id"] as? String
        let parameterID = payload["parameter_id"] as? String
        let block = (snapshot?["blocks"] as? [[String: Any]])?.first { $0["id"] as? String == blockID }
        let modelID = block?["model_id"] as? String ?? ""
        let model = (catalog?["models"] as? [String: [String: Any]])?[modelID]
        let definition = (model?["parameters"] as? [String: [String: Any]])?[parameterID ?? ""]
        let control = definition?["control"] as? [String: Any]
        let parameter = DeviceIdentity.name(control?["name"] as? String, fallback: "Parameter")
        let blockName = DeviceIdentity.name(model?["name"] as? String, fallback: "Block")
        title = operation == "save" ? "Save preset" : "\(parameter.capitalized) · \(blockName)"
        context = "\(DeviceIdentity.name(snapshot?["name"] as? String, fallback: "Preset")) · Scene \(snapshot?["scene"] as? String ?? "—")"
        let state = (response?["result"] as? [String: Any])?["state"] as? [String: Any]
        let scene = state?["scene"] as? String ?? ""
        let afterBlock = (state?["blocks"] as? [[String: Any]])?.first { $0["id"] as? String == blockID }
        let afterScene = (afterBlock?["scenes"] as? [String: [String: Any]])?[scene]
        let actual = (afterScene?["parameters"] as? [String: Any])?[parameterID ?? ""] as? NSNumber
        let requested = payload["value"] as? NSNumber
        let confirmed = response?["status"] as? String == "confirmed"
        if confirmed, operation == "save", state?["dirty"] as? Bool == false {
            outcome = .confirmed; detail = "Save confirmed"; value = nil
        } else if confirmed, let actual, actual.doubleValue.isFinite {
            outcome = requested.map { abs($0.doubleValue - actual.doubleValue) > 0.000001 } == true ? .adjusted : .confirmed
            detail = outcome.rawValue
            // Do not invent display units for a normalized QC parameter.
            value = (state?["value_encoding"] as? String == "qc_normalized") ? nil : actual.stringValue
        } else {
            let code = (response?["error"] as? [String: Any])?["code"] as? String ?? ""
            switch code {
            case "stale_context": outcome = .rejected; detail = "Device state changed"
            case "invalid_value": outcome = .rejected; detail = "Value is invalid"
            case "unsupported_parameter", "unsupported_operation", "read_only": outcome = .rejected; detail = "Not supported in this session"
            default: outcome = .unknown; detail = "Not retried. Reload state before editing."
            }
            value = nil
        }
    }
}
#endif
