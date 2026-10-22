import Foundation

public enum ParameterValue: Codable, Equatable {
    case number(Double), boolean(Bool), text(String), unknown
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .unknown }
        else if let value = try? c.decode(Bool.self) { self = .boolean(value) }
        else if let value = try? c.decode(Double.self) { self = .number(value) }
        else if let value = try? c.decode(String.self) { self = .text(value) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported parameter value") }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .number(let v): try c.encode(v); case .boolean(let v): try c.encode(v)
        case .text(let v): try c.encode(v); case .unknown: try c.encodeNil() }
    }
    public var json: Any {
        switch self { case .number(let v): return v; case .boolean(let v): return v
        case .text(let v): return v; case .unknown: return NSNull() }
    }
}

public struct ParameterControl: Codable {
    public struct Option: Codable { public let label: String; public let value: Double }
    /// A conditional control is active only while another parameter (a switch) holds one of these values.
    public struct ActiveWhen: Codable { public let parameter: String; public let values: [Double] }
    public let kind: String
    public let encoding: String
    public let name: String
    public let unit: String
    public let editable: Bool
    public let reason: String?
    public let minimum: Double?
    public let maximum: Double?
    public let mapping: String?
    public let exponent: Double?
    /// Declared [normalized, display] points for mapping "table", interpolated linearly.
    public let points: [[Double]]?
    public let options: [Option]?
    public let verification: String?
    public var active_when: ActiveWhen? = nil
    /// An internal value the QC never shows (hidden="true" or an empty layout slot). Never listed or written.
    public var hidden: Bool? = nil

    /// Raw QC normalized -> declared display units. Unknown metadata returns nil.
    public func displayValue(_ raw: ParameterValue) -> Double? {
        if kind == "number", encoding == "native", mapping == "identity",
           case .number(let n) = raw, n.isFinite, let lo = minimum, let hi = maximum,
           lo.isFinite, hi.isFinite, hi > lo, (lo...hi).contains(n) { return n }
        if mapping == "table" {
            guard case .number(let n) = raw, n.isFinite, (0...1).contains(n), let table else { return nil }
            return Self.interpolate(n, table.map { ($0[0], $0[1]) })
        }
        guard kind == "number", encoding == "qc_normalized", mapping == "power",
              case .number(let n) = raw, n.isFinite, (0...1).contains(n),
              let lo = minimum, let hi = maximum, lo.isFinite, hi.isFinite, hi > lo,
              let skew = exponent, skew.isFinite, skew > 0 else { return nil }
        let value = lo + (hi - lo) * pow(n, 1 / skew)
        return value.isFinite ? value : nil
    }
    public func wireValue(display: Double) -> ParameterValue? {
        if editable, encoding == "native", displayValue(.number(display)) != nil { return .number(display) }
        if mapping == "table" {
            guard editable, display.isFinite, let table else { return nil }
            return Self.interpolate(display, table.map { ($0[1], $0[0]) }).map { .number($0) }
        }
        guard editable, kind == "number", encoding == "qc_normalized", mapping == "power",
              display.isFinite, let lo = minimum, let hi = maximum, lo.isFinite, hi.isFinite,
              hi > lo, (lo...hi).contains(display), let skew = exponent, skew.isFinite, skew > 0 else { return nil }
        return .number(pow((display - lo) / (hi - lo), skew))
    }
    /// Points with both coordinates strictly increasing, spanning 0...1 and the declared range.
    private var table: [[Double]]? {
        guard kind == "number", encoding == "qc_normalized", let points, (2...64).contains(points.count),
              points.allSatisfy({ $0.count == 2 && $0[0].isFinite && $0[1].isFinite }),
              points.first?[0] == 0, points.last?[0] == 1,
              let lo = minimum, let hi = maximum, points.first?[1] == lo, points.last?[1] == hi,
              zip(points, points.dropFirst()).allSatisfy({ $1[0] > $0[0] && $1[1] > $0[1] }) else { return nil }
        return points
    }
    private static func interpolate(_ x: Double, _ points: [(Double, Double)]) -> Double? {
        guard let first = points.first, let last = points.last, (first.0...last.0).contains(x) else { return nil }
        for (a, b) in zip(points, points.dropFirst()) where x <= b.0 {
            return a.1 + (b.1 - a.1) * (x - a.0) / (b.0 - a.0)
        }
        return last.1
    }
    public func accepts(_ value: ParameterValue) -> Bool {
        guard editable else { return false }
        if kind == "number" { return displayValue(value) != nil }
        if kind == "enum", encoding == "qc_normalized", case .number(let n) = value, n.isFinite, (0...1).contains(n),
           let options, (2...1024).contains(options.count),
           options.allSatisfy({ !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.value.isFinite && (0...1).contains($0.value) }),
           Set(options.map(\.value)).count == options.count {
            return options.contains { abs($0.value - n) < 0.000001 }
        }
        return false
    }
}

public struct EditorCatalog: Codable {
    public struct Model: Codable {
        public struct Parameter: Codable { public let control: ParameterControl? }
        public let name: String
        public var category: String? = nil
        public let parameters: [String: Parameter]
    }
    public let id: String
    public let metadata_version: Int
    public let models: [String: Model]
}

public struct PresetSnapshot: Codable, Equatable {
    public struct Block: Codable, Equatable {
        public struct Scene: Codable, Equatable { public let parameters: [String: ParameterValue]; public let bypass: Bool? }
        public let id: String
        public let model_id: String
        public let position: [Int]
        public let scenes: [String: Scene]
        public let editable_parameters: [String]?
    }
    public let preset_id: String
    public let catalog_id: String?
    public let name: String
    public let scene: String
    public let dirty: Bool
    public let blocks: [Block]
    public var scene_labels: [String]? = nil
    public var scene_colors: [UInt32]? = nil
    public static let sceneLetters = ["A", "B", "C", "D", "E", "F", "G", "H"]
    var validStructure: Bool {
        let scenes = Set(Self.sceneLetters)
        return !preset_id.isEmpty && scenes.contains(scene) && blocks.count <= 32 &&
            Set(blocks.map(\.id)).count == blocks.count &&
            Set(blocks.map(\.position)).count == blocks.count && blocks.allSatisfy {
                !$0.id.isEmpty && !$0.model_id.isEmpty && $0.position.count == 2 &&
                (0..<4).contains($0.position[0]) && (0..<8).contains($0.position[1]) &&
                Set($0.scenes.keys).isSubset(of: scenes)
            }
    }
}

public enum EditorFailure: Error { case disconnected, busy, staleContext, incompatibleCatalog, unsupported, invalidValue, invalidState }

/// UI-independent confirmed state. Exactly one edit in flight; never automatically replay.
public final class GenericEditor {
    public struct Pending {
        public let id: String
        public let operation: String
        public let blockID: String?
        public let parameterID: String?
        public let proposedValue: ParameterValue?
        public let command: [String: Any]
    }
    public private(set) var snapshot: PresetSnapshot?
    public private(set) var catalog: EditorCatalog?
    public private(set) var pending: Pending?
    public private(set) var lastError: String?
    private var session: String?
    private var connection: String?
    private var revision = 0
    private var operations = Set<String>()
    public init() {}
    public func supports(_ operation: String) -> Bool { operations.contains(operation) }
    public func disconnect() {
        snapshot = nil; catalog = nil; pending = nil; session = nil; connection = nil
        revision = 0; operations.removeAll()
    }
    public func load(snapshot: PresetSnapshot, catalog: EditorCatalog, session: String,
                     connection: String, revision: Int, operations: Set<String>) throws {
        disconnect()
        guard !session.isEmpty, !connection.isEmpty, revision >= 0 else { throw EditorFailure.invalidState }
        guard catalog.metadata_version == 1, snapshot.catalog_id == catalog.id else { throw EditorFailure.incompatibleCatalog }
        guard snapshot.validStructure else { throw EditorFailure.invalidState }
        self.snapshot = snapshot; self.catalog = catalog; self.session = session
        self.connection = connection; self.revision = revision; self.operations = operations
        pending = nil; lastError = nil
    }
    public func control(blockID: String, parameterID: String) -> ParameterControl? {
        guard let block = snapshot?.blocks.first(where: { $0.id == blockID }) else { return nil }
        return catalog?.models[block.model_id]?.parameters[parameterID]?.control
    }
    /// Parameters the QC shows for this block, in index order. Hidden parameters and values the
    /// block's catalog model doesn't define are left out; unsupported ones stay, read-only.
    /// A block whose model is missing from the catalog lists every value, read-only.
    public func visibleParameters(blockID: String) -> [String] {
        guard let snapshot, let block = snapshot.blocks.first(where: { $0.id == blockID }) else { return [] }
        let ids = (block.scenes[snapshot.scene]?.parameters.keys).map(Array.init) ?? []
        let definitions = catalog?.models[block.model_id]?.parameters
        return ids.filter { id in
            guard let definitions else { return true }
            guard let control = definitions[id]?.control else { return false }
            return control.hidden != true
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    /// The catalog model's name, e.g. "Eltron 30".
    public func modelName(blockID: String) -> String? {
        guard let block = snapshot?.blocks.first(where: { $0.id == blockID }) else { return nil }
        return catalog?.models[block.model_id]?.name
    }
    /// What the QC calls the block: a Neural Capture's own name ("OG TS808") when its hidden
    /// file_name holds one, otherwise the model name. Display only; file_name stays unlisted and unwritable.
    public func blockName(blockID: String) -> String? {
        captureName(blockID: blockID) ?? modelName(blockID: blockID)
    }
    public func captureName(blockID: String) -> String? {
        guard let snapshot, let block = snapshot.blocks.first(where: { $0.id == blockID }),
              let parameters = catalog?.models[block.model_id]?.parameters,
              let id = parameters.first(where: { $0.value.control?.name == "file_name" })?.key,
              case .text(let raw)? = block.scenes[snapshot.scene]?.parameters[id] else { return nil }
        return Self.captureName(fileName: raw)
    }
    /// file_name is a 64-character lowercase hex hash followed by the capture's name. Anything else is nil.
    public static func captureName(fileName: String) -> String? {
        let hash = fileName.prefix(64)
        guard hash.count == 64, hash.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else { return nil }
        let name = fileName.dropFirst(64).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
    public func value(blockID: String, parameterID: String) -> ParameterValue? {
        guard let snapshot else { return nil }
        return snapshot.blocks.first { $0.id == blockID }?.scenes[snapshot.scene]?.parameters[parameterID]
    }
    public func readOnlyReason(blockID: String, parameterID: String) -> String? {
        guard let snapshot, let block = snapshot.blocks.first(where: { $0.id == blockID }),
              let control = control(blockID: blockID, parameterID: parameterID) else { return "Unknown block or metadata." }
        guard operations.contains("set_parameter") else { return "Adapter does not support parameter edits." }
        guard control.editable else { return control.reason ?? "Unsupported control." }
        if let reason = inactiveReason(block: block, scene: snapshot.scene, parameterID: parameterID) { return reason }
        guard block.editable_parameters?.contains(parameterID) == true else { return "Device marks this parameter read-only." }
        guard let value = block.scenes[snapshot.scene]?.parameters[parameterID], control.accepts(value) else { return "Missing or unsupported current value." }
        return nil
    }
    /// The QC greys out a conditional control while its switch is elsewhere, or while that switch is itself greyed out.
    private func inactiveReason(block: PresetSnapshot.Block, scene: String, parameterID: String, depth: Int = 0) -> String? {
        guard let rule = control(blockID: block.id, parameterID: parameterID)?.active_when else { return nil }
        let switchControl = control(blockID: block.id, parameterID: rule.parameter)
        let name = switchControl?.name ?? "its switch"
        guard depth < 8, case .number(let position)? = block.scenes[scene]?.parameters[rule.parameter] else {
            return "Inactive: \(name) has no current value."
        }
        if !rule.values.contains(where: { abs($0 - position) < 0.000001 }) {
            let label = switchControl?.options?.first { abs($0.value - position) < 0.000001 }?.label ?? String(format: "%g", position)
            return "Inactive while \(name) is \(label)."
        }
        return inactiveReason(block: block, scene: scene, parameterID: rule.parameter, depth: depth + 1).map { _ in "Inactive while \(name) is inactive." }
    }
    @discardableResult
    public func propose(blockID: String, parameterID: String, value: ParameterValue) throws -> Pending {
        guard let snapshot, let session, let connection else { throw EditorFailure.disconnected }
        guard pending == nil else { throw EditorFailure.busy }
        guard readOnlyReason(blockID: blockID, parameterID: parameterID) == nil else { throw EditorFailure.unsupported }
        guard control(blockID: blockID, parameterID: parameterID)?.accepts(value) == true else { throw EditorFailure.invalidValue }
        let id = UUID().uuidString
        let command: [String: Any] = ["version": 1, "id": id, "operation": "set_parameter", "connection_id": connection,
            "session_id": session, "revision": revision, "preset_id": snapshot.preset_id, "scene": snapshot.scene,
            "payload": ["block_id": blockID, "parameter_id": parameterID, "value": value.json]]
        let edit = Pending(id: id, operation: "set_parameter", blockID: blockID, parameterID: parameterID, proposedValue: value, command: command)
        pending = edit; lastError = nil
        return edit
    }
    /// The active scene's bypass flag; nil when the device didn't report one.
    public func bypassed(blockID: String) -> Bool? {
        guard let snapshot else { return nil }
        return snapshot.blocks.first { $0.id == blockID }?.scenes[snapshot.scene]?.bypass
    }
    public func bypassReadOnlyReason(blockID: String) -> String? {
        guard operations.contains("set_bypass") else { return "Adapter does not support bypass." }
        guard bypassed(blockID: blockID) != nil else { return "Device did not report bypass for this scene." }
        return nil
    }
    @discardableResult
    public func proposeBypass(blockID: String, bypassed: Bool) throws -> Pending {
        guard let snapshot, let session, let connection else { throw EditorFailure.disconnected }
        guard pending == nil else { throw EditorFailure.busy }
        guard bypassReadOnlyReason(blockID: blockID) == nil else { throw EditorFailure.unsupported }
        let id = UUID().uuidString
        let command: [String: Any] = ["version": 1, "id": id, "operation": "set_bypass", "connection_id": connection,
            "session_id": session, "revision": revision, "preset_id": snapshot.preset_id, "scene": snapshot.scene,
            "payload": ["block_id": blockID, "value": bypassed]]
        let edit = Pending(id: id, operation: "set_bypass", blockID: blockID, parameterID: nil, proposedValue: .boolean(bypassed), command: command)
        pending = edit; lastError = nil
        return edit
    }
    /// Asks the QC to make `scene` active. Scenes aren't part of Save, so this never touches dirty.
    @discardableResult
    public func proposeScene(_ scene: String) throws -> Pending {
        guard let snapshot, let session, let connection else { throw EditorFailure.disconnected }
        guard pending == nil else { throw EditorFailure.busy }
        guard operations.contains("select_scene") else { throw EditorFailure.unsupported }
        guard PresetSnapshot.sceneLetters.contains(scene) else { throw EditorFailure.invalidValue }
        let id = UUID().uuidString
        let command: [String: Any] = ["version": 1, "id": id, "operation": "select_scene", "connection_id": connection,
            "session_id": session, "revision": revision, "preset_id": snapshot.preset_id, "scene": snapshot.scene,
            "payload": ["scene": scene]]
        let change = Pending(id: id, operation: "select_scene", blockID: nil, parameterID: nil, proposedValue: .text(scene), command: command)
        pending = change; lastError = nil
        return change
    }
    /// A nil message clears the pending change without an error, for outcomes shown elsewhere.
    public func reject(id: String, message: String?) {
        guard pending?.id == id else { return }
        pending = nil; lastError = message // confirmed snapshot remains unchanged
    }
    public func proposeSave() throws -> Pending {
        guard let snapshot, let session, let connection else { throw EditorFailure.disconnected }
        guard pending == nil else { throw EditorFailure.busy }
        guard operations.contains("save") else { throw EditorFailure.unsupported }
        let id = UUID().uuidString
        let command: [String: Any] = ["version": 1, "id": id, "operation": "save", "connection_id": connection,
            "session_id": session, "revision": revision, "preset_id": snapshot.preset_id, "scene": snapshot.scene]
        let save = Pending(id: id, operation: "save", blockID: nil, parameterID: nil, proposedValue: nil, command: command)
        pending = save; lastError = nil; return save
    }
    /// Explicit refresh/event application cancels optimistic edits instead of rebasing them.
    public func refresh(_ newState: PresetSnapshot, session: String, connection: String, revision: Int) throws {
        guard session == self.session, connection == self.connection, revision >= self.revision,
              newState.validStructure,
              newState.catalog_id == catalog?.id, Set(newState.blocks.map(\.id)).count == newState.blocks.count else { throw EditorFailure.staleContext }
        if revision == self.revision {
            guard newState == snapshot else { throw EditorFailure.staleContext }; return
        }
        if pending != nil { lastError = "Device state changed; pending edit discarded." }
        pending = nil; snapshot = newState; self.revision = revision
    }
    public func confirm(id: String, snapshot newState: PresetSnapshot, session: String, connection: String, revision: Int) throws {
        guard let pending, pending.id == id, session == self.session, connection == self.connection,
              revision >= self.revision, newState.catalog_id == catalog?.id,
              newState.preset_id == snapshot?.preset_id, newState.validStructure else { throw EditorFailure.staleContext }
        // Only a scene switch may change the scene, and only to the one it asked for. Switching
        // to the scene that is already active writes nothing, so its revision may stay put.
        if pending.operation == "select_scene" {
            guard case .text(let scene)? = pending.proposedValue, newState.scene == scene,
                  revision > self.revision || newState == snapshot else { throw EditorFailure.staleContext }
        } else {
            guard revision > self.revision, newState.scene == snapshot?.scene else { throw EditorFailure.staleContext }
        }
        if pending.operation == "set_parameter" {
            guard let blockID = pending.blockID, let parameterID = pending.parameterID,
                  let block = newState.blocks.first(where: { $0.id == blockID }),
                  block.model_id == snapshot?.blocks.first(where: { $0.id == blockID })?.model_id,
                  let value = block.scenes[newState.scene]?.parameters[parameterID],
                  control(blockID: blockID, parameterID: parameterID)?.accepts(value) == true else { throw EditorFailure.invalidState }
        } else if pending.operation == "set_bypass" {
            guard let blockID = pending.blockID,
                  let block = newState.blocks.first(where: { $0.id == blockID }),
                  block.model_id == snapshot?.blocks.first(where: { $0.id == blockID })?.model_id,
                  block.scenes[newState.scene]?.bypass != nil else { throw EditorFailure.invalidState }
        } else if pending.operation == "save" {
            guard !newState.dirty, newState.blocks == snapshot?.blocks, newState.name == snapshot?.name else { throw EditorFailure.invalidState }
        }
        // Readback is authoritative, including a valid value adjusted by the device.
        snapshot = newState; self.revision = revision; self.pending = nil; lastError = nil
    }
}
