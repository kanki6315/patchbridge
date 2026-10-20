import SwiftUI

/// Main-thread presentation owner. Live writes always pass through the confirmed-state coordinator.
final class PhoneModel: ObservableObject {
    @Published private(set) var version = 0
    @Published private(set) var demo = false
    @Published var notice: String?
    let coordinator = EditorCoordinator()
    private let demoEditor = GenericEditor()
    private var demoRevision = 0
    var editor: GenericEditor { demo ? demoEditor : coordinator.editor }
    var snapshot: PresetSnapshot? { editor.snapshot }
    var ready: Bool { demo || coordinator.phase == .ready }
    var busy: Bool { !demo && coordinator.busy }
    var error: String? { (demo ? nil : coordinator.error) ?? editor.lastError }
    init() {
        coordinator.onChange = { [weak self] in self?.version += 1 }
    }
    func start() { coordinator.setPhoneName(UserDefaults.standard.string(forKey: "patchbridge.phoneName") ?? ""); demo = false; notice = nil; coordinator.start() }
    func disconnect() { coordinator.disconnect(); demoEditor.disconnect(); demo = false; notice = nil; version += 1 }
    func background() { if !demo { disconnect() } }
    func loadDemo() {
        struct Fixture: Decodable { let catalog: EditorCatalog; let snapshot: PresetSnapshot }
        do {
            guard let url = Bundle.main.url(forResource: "qc-editor", withExtension: "json") else { throw EditorFailure.invalidState }
            let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
            coordinator.disconnect(); demoRevision = 0
            try demoEditor.load(snapshot: fixture.snapshot, catalog: fixture.catalog, session: "demo", connection: "demo", revision: 0, operations: ["set_parameter", "save"])
            demo = true; notice = nil; version += 1
        } catch { notice = "The demo preset could not be loaded." }
    }
    func edit(_ block: String, _ parameter: String, _ value: ParameterValue) {
        do {
            notice = nil
            if demo {
                let pending = try editor.propose(blockID: block, parameterID: parameter, value: value)
                try confirmDemo(pending)
            } else { try coordinator.edit(blockID: block, parameterID: parameter, value: value) }
        } catch { notice = "Not applied. Refresh the preset and try again." }
        version += 1
    }
    func save() {
        do {
            if demo { try confirmDemo(editor.proposeSave()); notice = "Saved in demo only" }
            else { try coordinator.save() }
        } catch { notice = "Couldn’t save. Check the connection and try again." }
        version += 1
    }
    private func confirmDemo(_ pending: GenericEditor.Pending) throws {
        guard let snapshot else { throw EditorFailure.invalidState }
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as! [String: Any]
        object["dirty"] = pending.operation != "save"
        if let block = pending.blockID, let parameter = pending.parameterID, let value = pending.proposedValue {
            var blocks = object["blocks"] as! [[String: Any]]
            let index = blocks.firstIndex { $0["id"] as? String == block }!
            var scenes = blocks[index]["scenes"] as! [String: [String: Any]]
            var parameters = scenes[snapshot.scene]!["parameters"] as! [String: Any]
            parameters[parameter] = value.json; scenes[snapshot.scene]!["parameters"] = parameters
            blocks[index]["scenes"] = scenes; object["blocks"] = blocks
        }
        let updated = try JSONDecoder().decode(PresetSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        demoRevision += 1
        try editor.confirm(id: pending.id, snapshot: updated, session: "demo", connection: "demo", revision: demoRevision)
    }
    func name(_ block: PresetSnapshot.Block) -> String { editor.catalog?.models[block.model_id]?.name ?? "Unknown block" }
    func category(_ block: PresetSnapshot.Block) -> BlockCategory { BlockCategory(editor.catalog?.models[block.model_id]?.category ?? "") }
    func parameters(_ block: PresetSnapshot.Block) -> [String] {
        (block.scenes[snapshot?.scene ?? ""]?.parameters.keys.map { $0 } ?? []).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    func valueText(_ block: String, _ parameter: String) -> String {
        guard let value = editor.value(blockID: block, parameterID: parameter) else { return "Unavailable" }
        let control = editor.control(blockID: block, parameterID: parameter)
        if let n = control?.displayValue(value) { return String(format: "%.1f", n) + (control?.unit.isEmpty == false ? " \(control!.unit)" : "") }
        if case .number(let n) = value, let option = control?.options?.first(where: { abs($0.value - n) < 0.000001 }) { return option.label }
        switch value {
        case .number(let n):
            if control?.encoding == "qc_normalized", (0...1).contains(n) { return String(format: "%.0f %%", n * 100) }
            return "Raw \(n.formatted())"
        case .boolean(let b): return b ? "On" : "Off"
        case .text(let t): return t
        case .unknown: return "Unavailable"
        }
    }
}
