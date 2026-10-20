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
    public let options: [Option]?
    public let verification: String?

    /// Raw QC normalized -> declared display units. Unknown metadata returns nil.
    public func displayValue(_ raw: ParameterValue) -> Double? {
        if kind == "number", encoding == "native", mapping == "identity",
           case .number(let n) = raw, n.isFinite, let lo = minimum, let hi = maximum,
           lo.isFinite, hi.isFinite, hi > lo, (lo...hi).contains(n) { return n }
        guard kind == "number", encoding == "qc_normalized", mapping == "power",
              case .number(let n) = raw, n.isFinite, (0...1).contains(n),
              let lo = minimum, let hi = maximum, lo.isFinite, hi.isFinite, hi > lo,
              let skew = exponent, skew.isFinite, skew > 0 else { return nil }
        let value = lo + (hi - lo) * pow(n, 1 / skew)
        return value.isFinite ? value : nil
    }
    public func wireValue(display: Double) -> ParameterValue? {
        if editable, encoding == "native", displayValue(.number(display)) != nil { return .number(display) }
        guard editable, kind == "number", encoding == "qc_normalized", mapping == "power",
              display.isFinite, let lo = minimum, let hi = maximum, lo.isFinite, hi.isFinite,
              hi > lo, (lo...hi).contains(display), let skew = exponent, skew.isFinite, skew > 0 else { return nil }
        return .number(pow((display - lo) / (hi - lo), skew))
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
    var validStructure: Bool {
        let scenes = Set(["A", "B", "C", "D", "E", "F", "G", "H"])
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
    public func value(blockID: String, parameterID: String) -> ParameterValue? {
        guard let snapshot else { return nil }
        return snapshot.blocks.first { $0.id == blockID }?.scenes[snapshot.scene]?.parameters[parameterID]
    }
    public func readOnlyReason(blockID: String, parameterID: String) -> String? {
        guard let snapshot, let block = snapshot.blocks.first(where: { $0.id == blockID }),
              let control = control(blockID: blockID, parameterID: parameterID) else { return "Unknown block or metadata." }
        guard operations.contains("set_parameter") else { return "Adapter does not support parameter edits." }
        guard control.editable else { return control.reason ?? "Unsupported control." }
        guard block.editable_parameters?.contains(parameterID) == true else { return "Device marks this parameter read-only." }
        guard let value = block.scenes[snapshot.scene]?.parameters[parameterID], control.accepts(value) else { return "Missing or unsupported current value." }
        return nil
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
    public func reject(id: String, message: String) {
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
              revision > self.revision, newState.catalog_id == catalog?.id,
              newState.preset_id == snapshot?.preset_id, newState.scene == snapshot?.scene,
              newState.validStructure else { throw EditorFailure.staleContext }
        if pending.operation == "set_parameter" {
            guard let blockID = pending.blockID, let parameterID = pending.parameterID,
                  let block = newState.blocks.first(where: { $0.id == blockID }),
                  block.model_id == snapshot?.blocks.first(where: { $0.id == blockID })?.model_id,
                  let value = block.scenes[newState.scene]?.parameters[parameterID],
                  control(blockID: blockID, parameterID: parameterID)?.accepts(value) == true else { throw EditorFailure.invalidState }
        } else if pending.operation == "save" {
            guard !newState.dirty, newState.blocks == snapshot?.blocks, newState.name == snapshot?.name else { throw EditorFailure.invalidState }
        }
        // Readback is authoritative, including a valid value adjusted by the device.
        snapshot = newState; self.revision = revision; self.pending = nil; lastError = nil
    }
}
