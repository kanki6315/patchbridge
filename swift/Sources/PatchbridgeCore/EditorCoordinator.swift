import Foundation

/// Own on the main queue, like EditorTransport. Screens observe onChange and render editor's
/// confirmed state. start/reconnect requires fresh authorization; mutations are never replayed.
public final class EditorCoordinator {
    public enum Phase: Equatable { case disconnected, connecting, awaitingApproval, loading, recovering, ready, failed }
    /// Why a failure happened, when the screen should say more than "Connection ended".
    public enum Failure: Equatable { case bridgeFull, revoked }
    public let editor = GenericEditor()
    public private(set) var nearbyMacs = [String: String]()
    public private(set) var macName: String?
    /// The last Mac chosen, kept after a disconnect so Reconnect can find it again.
    public private(set) var macID: String?
    /// Mac-issued trust tokens by Mac ID. A matching token lets that Mac skip the approval code.
    public var trustTokens = [String: String]()
    /// The Mac accepted this phone's trust token, or issued one on approval.
    public private(set) var trusted = false
    private var preferredMac: String?
    public func chooseMac(_ id: String) {
        guard phase == .connecting, let name = nearbyMacs[id] else { return }
        macName = name; macID = id; preferredMac = nil; discoveryDeadline = now() + 30
        (transport as? DiscoverableEditorTransport)?.selectPeripheral(id); nearbyMacs.removeAll(); onChange?()
    }
    private let diagnostics: Diagnostics
    public private(set) var phase: Phase = .disconnected
    public private(set) var approvalCode: String?
    private var phoneName: String
    public private(set) var error: String?
    public private(set) var failure: Failure?
    public private(set) var outcome: String?
    public private(set) var status = "Disconnected"
    public var onChange: (() -> Void)?
    public var busy: Bool { request != nil }
    private let makeTransport: () -> EditorTransport
    private let now: () -> TimeInterval
    private let pollInterval: TimeInterval
    private let timeout: TimeInterval
    private let automaticPolling: Bool
    private var transport: EditorTransport?
    private var timer: Timer?
    private var isInBackground = false
    private var generation = UUID()
    private var connection: String?
    private var session: String?
    private var revision = 0
    private var operations = Set<String>()
    private var staged: PresetSnapshot?
    // One bounded catalog subset, reused only for a matching ID and covered model IDs.
    private var cachedCatalog: EditorCatalog?
    private var cachedModels = Set<String>()
    private var requestedModels = Set<String>()
    private var nextPoll = TimeInterval.infinity
    private var discoveryDeadline = TimeInterval.infinity
    /// A loading step the bridge was too busy to run, retried once it says to.
    private var deferred: (operation: String, at: TimeInterval)?
    private struct Request { let id: String; let operation: String; let deadline: TimeInterval; var trustOffered = false }
    private var request: Request?

    public init(pollInterval: TimeInterval = 2, timeout: TimeInterval = 60,
                automaticPolling: Bool = true, phoneName: String = DeviceIdentity.phoneName, diagnostics: Diagnostics = .shared,
                now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                makeTransport: @escaping () -> EditorTransport = { BLECentral(automaticallyConnect: false) }) {
        self.phoneName = DeviceIdentity.name(phoneName, fallback: "iPhone")
        self.diagnostics = diagnostics
        self.pollInterval = max(0.5, pollInterval.isFinite ? pollInterval : 2)
        self.timeout = max(0.5, timeout.isFinite ? timeout : 15)
        self.automaticPolling = automaticPolling; self.now = now; self.makeTransport = makeTransport
    }
    deinit { timer?.invalidate() }
    public func setPhoneName(_ name: String) {
        guard phase == .disconnected || phase == .failed else { return }
        phoneName = DeviceIdentity.name(name, fallback: "iPhone")
    }
    /// With `reconnecting`, the last Mac is chosen as soon as it is found.
    public func start(reconnecting: Bool = false) {
        let lastMac = macID, lastName = macName
        disconnect()
        if reconnecting, let lastMac { preferredMac = lastMac; macID = lastMac; macName = lastName }
        else { macID = nil; macName = nil }
        diagnostics.record(.editorStarted)
        error = nil; outcome = nil; discoveryDeadline = now() + 30; phase = .connecting; status = "Connecting"
        let epoch = generation
        let transport = makeTransport()
        self.transport = transport
        (transport as? DiscoverableEditorTransport)?.onDiscovered = { [weak self] id, name in
            guard let self, self.generation == epoch, self.phase == .connecting else { return }
            self.nearbyMacs[id] = name
            if id == self.preferredMac { self.chooseMac(id) } else { self.onChange?() }
        }
        transport.onReady = { [weak self] in
            guard let self, self.generation == epoch, self.phase == .connecting else { return }
            self.send("hello")
        }
        transport.onDisconnected = { [weak self] in
            guard let self, self.generation == epoch else { return }
            self.fail(self.transport?.disconnectionReason ?? (self.status.hasPrefix("Bluetooth") ? self.status : "Connection ended. Reconnect to reload confirmed state."))
        }
        transport.onStatus = { [weak self] status in
            guard let self, self.generation == epoch else { return }
            self.status = status; self.onChange?()
        }
        transport.onResponse = { [weak self] response in
            guard let self, self.generation == epoch else { return }; self.receive(response)
        }
        if automaticPolling {
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        }
        transport.reconnect(); onChange?()
    }
    public func disconnect() {
        error = nil; failure = nil; outcome = nil; deferred = nil
        diagnostics.record(.editorDisconnected)
        generation = UUID(); timer?.invalidate(); timer = nil
        let old = transport; transport = nil
        old?.onReady = nil; old?.onDisconnected = nil; old?.onStatus = nil; old?.onResponse = nil
        nearbyMacs.removeAll(); approvalCode = nil; trusted = false; preferredMac = nil
        request = nil; staged = nil; connection = nil; session = nil; revision = 0
        operations.removeAll(); nextPoll = .infinity; discoveryDeadline = .infinity; editor.disconnect()
        phase = .disconnected; status = "Disconnected"; old?.disconnect(); onChange?()
    }
    public func authorize() {
        guard phase == .awaitingApproval, !busy else { return }
        phase = .loading; error = nil; send("connect")
    }
    public func refresh() { guard phase == .ready, !busy else { return }; send("snapshot") }
    /// Keep the authorized transport alive while iOS handles Bluetooth events, but
    /// stop idle polling. Outstanding requests retain their normal timeout policy.
    public func setBackgrounded(_ backgrounded: Bool) {
        guard isInBackground != backgrounded else { return }
        isInBackground = backgrounded
        if !backgrounded {
            nextPoll = now()
            tick()
        }
    }
    /// Also usable with a deterministic clock in offline hosts. No overlapping polls or catch-up bursts.
    public func tick() {
        if phase == .connecting, nearbyMacs.isEmpty, now() >= discoveryDeadline { fail("No Mac replied. Open Patchbridge on your Mac and try again."); return }
        if let request, now() >= request.deadline { fail("Request timed out; its outcome is unknown. Reconnect before editing."); return }
        guard !isInBackground else { return }
        if phase == .ready, !busy, now() >= nextPoll { refresh() }
        if phase == .recovering, !busy, now() >= nextPoll { send("recover") }
        if phase == .loading, !busy, let step = deferred, now() >= step.at { deferred = nil; send(step.operation) }
    }
    public func edit(blockID: String, parameterID: String, value: ParameterValue) throws {
        guard phase == .ready else { throw EditorFailure.disconnected }
        guard !busy else { throw EditorFailure.busy }
        outcome = nil
        let pending = try editor.propose(blockID: blockID, parameterID: parameterID, value: value)
        send(pending.operation, command: pending.command)
    }
    public func save() throws {
        guard phase == .ready else { throw EditorFailure.disconnected }
        guard !busy else { throw EditorFailure.busy }
        outcome = nil
        let pending = try editor.proposeSave(); send(pending.operation, command: pending.command)
    }
    private func fail(_ message: String, reason: Failure? = nil) {
        diagnostics.record(.editorFailed, code: "transport_failure")
        disconnect(); phase = .failed; error = message; failure = reason; status = "Reconnect required"; onChange?()
    }
    private static func deviceName(_ response: [String: Any]) -> String? {
        (response["changed_by"] as? String).map { DeviceIdentity.name($0, fallback: "another device") }
    }
    private func send(_ operation: String, command: [String: Any]? = nil) {
        guard request == nil, let transport else { return }
        var message = command ?? ["version": 1, "id": UUID().uuidString, "operation": operation]
        if operation == "hello" {
            message["device_name"] = phoneName
            if let macID, let token = trustTokens[macID] { message["trust_token"] = token }
        }
        if let connection { message["connection_id"] = connection }
        if let session { message["session_id"] = session }
        if operation == "catalog" { message["payload"] = ["model_ids": requestedModels.sorted()] }
        request = Request(id: message["id"] as! String, operation: operation, deadline: now() + timeout, trustOffered: message["trust_token"] != nil)
        do { try transport.send(message) }
        catch { fail("Could not send request; reconnect to reload state. No edit will be retried.") }
        onChange?()
    }
    private func decode<T: Decodable>(_ type: T.Type, _ object: Any?) throws -> T {
        guard let object else { throw EditorFailure.invalidState }
        return try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: object))
    }
    private func integer(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber, String(cString: n.objCType) != "c",
              n.doubleValue.isFinite, n.doubleValue >= 0, n.doubleValue < Double(Int.max),
              n.doubleValue.rounded() == n.doubleValue else { return nil }
        return n.intValue
    }
    private func receive(_ response: [String: Any]) {
        guard let pending = request, response["id"] as? String == pending.id else { return }
        request = nil
        do {
            guard integer(response["version"]) == 1 else { throw EditorFailure.invalidState }
            if pending.operation == "hello" {
                if (response["error"] as? [String: Any])?["code"] as? String == "bridge_full" {
                    let detail = (response["error"] as? [String: Any])?["message"] as? String ?? "This Mac is already connected to the most devices it allows."
                    fail("\(detail) Disconnect one on the Mac, then try again.", reason: .bridgeFull); return
                }
                let offeredTrust = pending.trustOffered
                guard let token = response["connection_id"] as? String, !token.isEmpty,
                      let required = response["authorization_required"] as? Bool, required || offeredTrust else { throw EditorFailure.invalidState }
                macName = DeviceIdentity.name(response["mac_name"] as? String, fallback: "Mac")
                connection = token
                if !required {
                    trusted = true; phase = .loading; status = "Trusted · connecting"; send("connect"); return
                }
                // The Mac no longer trusts this phone (it quit or trust was revoked).
                if offeredTrust, let macID { trustTokens[macID] = nil }
                approvalCode = DeviceIdentity.approvalCode(token)
                phase = .awaitingApproval; status = "Approve on Mac, then authorize"
                onChange?(); return
            }
            guard response["connection_id"] as? String == connection else { throw EditorFailure.staleContext }
            if response["status"] as? String != "confirmed" {
                let detail = response["error"] as? [String: Any]
                let code = detail?["code"] as? String ?? response["error"] as? String ?? "unknown"
                let message = detail?["message"] as? String ?? code
                if pending.operation == "connect", code == "unauthorized" {
                    phase = .awaitingApproval; error = message; onChange?(); return
                }
                if code == "revoked" {
                    fail("Disconnected on your Mac. Reconnect to ask for approval again.", reason: .revoked); return
                }
                // Refused before reaching the QC, so nothing changed: retry when the bridge says.
                if code == "busy" {
                    let retry = response["retry_after"] as? Double ?? 1
                    let delay = retry.isFinite ? min(8, max(0.5, retry)) : 1
                    if ["set_parameter", "save"].contains(pending.operation) {
                        let text = pending.operation == "save" ? "Save not applied. The bridge was busy with another device; try again."
                            : "Not applied. The bridge was busy with another device; try again."
                        editor.reject(id: pending.id, message: text); error = text; ready()
                    } else if phase == .ready || phase == .recovering {
                        nextPoll = now() + delay
                    } else if phase == .loading {
                        deferred = (pending.operation, now() + delay)
                    } else { fail(message); return }
                    onChange?(); return
                }
                if code == "device_unavailable" {
                    let uncertain = ["set_parameter", "save"].contains(pending.operation)
                    editor.disconnect(); staged = nil; session = nil; operations.removeAll()
                    phase = .recovering; status = "QC unavailable · reconnecting"
                    if uncertain {
                        // The bridge marks an edit it never sent; only then is the outcome certain.
                        error = response["applied"] as? Bool == false
                            ? (pending.operation == "save" ? "Save not applied. Editing resumes after the QC reconnects." : "Edit not applied. Editing resumes after the QC reconnects.")
                            : "Last edit or save outcome unknown. It will not be retried."
                    }
                    let delay = response["retry_after"] as? Double ?? 1
                    nextPoll = now() + (delay.isFinite ? min(8, max(0.5, delay)) : 1)
                    onChange?(); return
                }
                // Only explicit, session-preserving rejections are recoverable. Resync before more edits.
                if ["set_parameter", "save"].contains(pending.operation),
                   ["stale_context", "invalid_value", "unsupported_parameter", "unsupported_operation"].contains(code),
                   response["session_id"] as? String == session {
                    let text = code == "stale_context" ? Self.deviceName(response).map { "Not applied. \($0) changed it first." } ?? message : message
                    editor.reject(id: pending.id, message: text); error = text
                    phase = .loading; send("snapshot"); return
                }
                fail(message); return
            }
            guard let newSession = response["session_id"] as? String, !newSession.isEmpty,
                  let newRevision = integer(response["revision"]),
                  ["connect", "recover"].contains(pending.operation) || (newSession == session && newRevision >= revision),
                  let result = response["result"] as? [String: Any] else { throw EditorFailure.staleContext }
            if pending.operation == "connect", let macID {
                trustTokens[macID] = response["trust_token"] as? String
                trusted = trustTokens[macID] != nil
            }
            if ["connect", "recover"].contains(pending.operation) {
                phase = .loading; session = newSession; revision = newRevision
                staged = try decode(PresetSnapshot.self, result["state"])
                send("capabilities"); return
            }
            switch pending.operation {
            case "capabilities":
                guard integer(result["protocol_version"]) == 1,
                      let supported = result["operations"] as? [String],
                      Set(["snapshot", "catalog"]).isSubset(of: Set(supported)) else { throw EditorFailure.unsupported }
                operations = Set(supported); try loadCatalogIfNeeded()
            case "catalog":
                let catalog = try decode(EditorCatalog.self, result)
                guard catalog.id == staged?.catalog_id, catalog.metadata_version == 1 else { throw EditorFailure.incompatibleCatalog }
                cachedCatalog = catalog; cachedModels = requestedModels; try installStaged()
            case "snapshot":
                let state = try decode(PresetSnapshot.self, result["state"])
                if let previous = editor.snapshot, previous != state {
                    outcome = Self.deviceName(response).map { "Changed on \($0)" } ?? "Changed on the QC"
                }
                guard newRevision > revision || state == editor.snapshot else { throw EditorFailure.staleContext }
                if state.catalog_id != editor.catalog?.id || !Set(state.blocks.map(\.model_id)).isSubset(of: cachedModels) {
                    staged = state; revision = newRevision; phase = .loading
                    editor.disconnect(); try loadCatalogIfNeeded()
                } else {
                    try editor.refresh(state, session: newSession, connection: connection!, revision: newRevision)
                    revision = newRevision; ready()
                }
            case "set_parameter", "save":
                let state = try decode(PresetSnapshot.self, result["state"])
                let proposed = editor.pending
                try editor.confirm(id: pending.id, snapshot: state, session: newSession, connection: connection!, revision: newRevision)
                if pending.operation == "save" { outcome = "Saved on the QC" }
                else if let block = proposed?.blockID, let parameter = proposed?.parameterID {
                    outcome = editor.value(blockID: block, parameterID: parameter) == proposed?.proposedValue ? "Confirmed" : "Adjusted by the QC"
                }
                revision = newRevision; error = nil; ready()
            default: throw EditorFailure.invalidState
            }
            onChange?()
        } catch { fail("Invalid or stale bridge response. Reconnect to reload state.") }
    }
    private func loadCatalogIfNeeded() throws {
        guard let id = staged?.catalog_id, !id.isEmpty else { throw EditorFailure.incompatibleCatalog }
        requestedModels = Set(staged!.blocks.map(\.model_id))
        guard requestedModels.count <= 128 else { throw EditorFailure.invalidState }
        if cachedCatalog?.id == id, requestedModels.isSubset(of: cachedModels) { try installStaged() }
        else { cachedCatalog = nil; cachedModels.removeAll(); send("catalog") }
    }
    private func installStaged() throws {
        guard let staged, let cachedCatalog, let session, let connection else { throw EditorFailure.invalidState }
        try editor.load(snapshot: staged, catalog: cachedCatalog, session: session, connection: connection,
                        revision: revision, operations: operations)
        self.staged = nil; ready()
    }
    private func ready() { phase = .ready; status = "Confirmed state loaded"; nextPoll = now() + pollInterval }
}
