import SwiftUI

/// Main-thread presentation owner. Live writes always pass through the confirmed-state coordinator.
final class PhoneModel: ObservableObject {
    @Published private(set) var version = 0
    @Published private(set) var demo = false
    #if DEBUG
    @Published private(set) var screenshotFixture = false
    #endif
    /// Both offline transports confirm edits locally; screenshot fixtures use the normal UI.
    var usesLocalFixture: Bool {
        #if DEBUG
        return demo || screenshotFixture
        #else
        return demo
        #endif
    }
    @Published var notice: String?
    let coordinator = EditorCoordinator()
    let liveActivity = ConnectionActivityController()
    let tuner = TunerModel()
    private let demoEditor = GenericEditor()
    private var demoRevision = 0
    var editor: GenericEditor { usesLocalFixture ? demoEditor : coordinator.editor }
    var snapshot: PresetSnapshot? { editor.snapshot }
    var ready: Bool { usesLocalFixture || coordinator.phase == .ready }
    var busy: Bool { !usesLocalFixture && coordinator.busy }
    var error: String? { (usesLocalFixture ? nil : coordinator.error) ?? editor.lastError }
    /// The last Mac has a trust token, so Reconnect should skip the approval code.
    var hasTrust: Bool { coordinator.macID.flatMap { coordinator.trustTokens[$0] } != nil }
    /// Reconnect finds the last Mac directly instead of listing nearby ones.
    var canReconnect: Bool { coordinator.macID != nil && !usesLocalFixture }
    init() {
        tuner.phone = self
        coordinator.trustTokens = TrustStore.load()
        coordinator.onChange = { [weak self] in
            guard let self else { return }
            // A connection that ended takes the tuner with it; recovery keeps it.
            if !self.usesLocalFixture, [.disconnected, .failed].contains(self.coordinator.phase), self.tuner.open || self.tuner.live { self.tuner.reset() }
            if self.coordinator.trustTokens != self.savedTrust { self.savedTrust = self.coordinator.trustTokens; TrustStore.save(self.savedTrust) }
            self.liveActivity.sync(self)
            self.version += 1
        }
        savedTrust = coordinator.trustTokens
        ConnectionActivityActions.handler = { [weak self] action in
            switch action {
            case .disconnect: self?.disconnect()
            case .reconnect: self?.reconnect()
            }
        }
    }
    private var savedTrust = [String: String]()
    private func clearScreenshotFixture() {
        #if DEBUG
        screenshotFixture = false
        #endif
    }
    func start() { clearScreenshotFixture(); coordinator.setPhoneName(UserDefaults.standard.string(forKey: "patchbridge.phoneName") ?? ""); demo = false; notice = nil; coordinator.start() }
    func reconnect() {
        guard canReconnect else { start(); return }
        coordinator.setPhoneName(UserDefaults.standard.string(forKey: "patchbridge.phoneName") ?? "")
        notice = nil; liveActivity.willReconnect(); coordinator.start(reconnecting: true)
    }
    func disconnect() { clearScreenshotFixture(); tuner.reset(); liveActivity.willDisconnect(); coordinator.disconnect(); demoEditor.disconnect(); demo = false; notice = nil; version += 1 }
    /// Settings changed: start, update or end the activity to match.
    func connectionStatusPreferenceChanged() { liveActivity.sync(self) }
    func background() { coordinator.setBackgrounded(true) }
    func foreground() { coordinator.setBackgrounded(false) }
    #if DEBUG
    /// Website preset data with connected-state presentation, without Bluetooth or USB writes.
    func loadScreenshotFixture() {
        loadDemo()
        guard demo else { return }
        screenshotFixture = true
        demo = false
    }
    #endif
    func loadDemo() {
        clearScreenshotFixture()
        do {
            let fixture = try DemoFixture.load()
            tuner.reset(); liveActivity.willDisconnect(); coordinator.disconnect(); demoRevision = 0
            try demoEditor.load(snapshot: fixture.snapshot, catalog: fixture.catalog, session: "demo", connection: "demo", revision: 0, operations: ["set_parameter", "save"])
            demo = true; notice = nil; liveActivity.sync(self); version += 1
        } catch { notice = "The demo preset could not be loaded." }
    }
    func edit(_ block: String, _ parameter: String, _ value: ParameterValue) {
        do {
            notice = nil
            if usesLocalFixture {
                let pending = try editor.propose(blockID: block, parameterID: parameter, value: value)
                try confirmDemo(pending)
            } else { try coordinator.edit(blockID: block, parameterID: parameter, value: value) }
        } catch { notice = "Not applied. Refresh the preset and try again." }
        version += 1
    }
    func save() {
        do {
            if usesLocalFixture { try confirmDemo(editor.proposeSave()); notice = demo ? "Saved in demo only" : "Saved on the QC" }
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
    func name(_ block: PresetSnapshot.Block) -> String { editor.blockName(blockID: block.id) ?? "Unknown block" }
    /// The category, plus the model name when the block goes by a capture name: "Neural Capture · Eltron 30".
    func kind(_ block: PresetSnapshot.Block) -> String {
        let kind = editor.catalog?.models[block.model_id]?.category ?? "Block"
        guard editor.captureName(blockID: block.id) != nil, let model = editor.modelName(blockID: block.id) else { return kind }
        return "\(kind) · \(model)"
    }
    func category(_ block: PresetSnapshot.Block) -> BlockCategory { BlockCategory(editor.catalog?.models[block.model_id]?.category ?? "") }
    func parameters(_ block: PresetSnapshot.Block) -> [String] { editor.visibleParameters(blockID: block.id) }
    func location(_ snapshot: PresetSnapshot) -> String {
        if snapshot.preset_id.hasPrefix("captured:") { return snapshot.preset_id.replacingOccurrences(of: "captured:", with: "").replacingOccurrences(of: ":", with: " · ") }
        return "Current preset"
    }
    func sceneColor(_ theme: PhoneTheme, _ index: Int) -> Color {
        guard let colors = snapshot?.scene_colors, colors.indices.contains(index) else { return theme.muted }
        return Color(hex: colors[index])
    }
    func sceneName(_ index: Int) -> String {
        guard let labels = snapshot?.scene_labels, labels.indices.contains(index) else { return "" }
        return labels[index]
    }
    func editable(_ block: PresetSnapshot.Block) -> Bool {
        parameters(block).contains { editor.readOnlyReason(blockID: block.id, parameterID: $0) == nil }
    }
    func summary(_ block: PresetSnapshot.Block) -> String {
        if block.scenes[snapshot?.scene ?? ""]?.bypass == true { return "Bypassed" }
        let editable = parameters(block).filter { editor.readOnlyReason(blockID: block.id, parameterID: $0) == nil }
        if editable.isEmpty { return "Read-only" }
        return editable.prefix(2).map { id in
            let name = editor.control(blockID: block.id, parameterID: id)?.name.capitalized ?? "Value"
            // A unit that repeats the name says it once: "Semitones -1.0", not "Semitones -1.0 Semitones".
            let unit = editor.control(blockID: block.id, parameterID: id)?.unit.caseInsensitiveCompare(name) != .orderedSame
            return name + " " + valueText(block.id, id, unit: unit)
        }.joined(separator: " · ")
    }
    func valueText(_ block: String, _ parameter: String, unit: Bool = true) -> String {
        guard let value = editor.value(blockID: block, parameterID: parameter) else { return "Unavailable" }
        let control = editor.control(blockID: block, parameterID: parameter)
        if let n = control?.displayValue(value) { return String(format: "%.1f", n) + (unit && control?.unit.isEmpty == false ? " \(control!.unit)" : "") }
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
