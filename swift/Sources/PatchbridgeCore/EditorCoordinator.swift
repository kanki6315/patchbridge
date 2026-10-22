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
    /// Each new tuner reading. Kept apart from `onChange`, which redraws whole screens, because it fires about ten times a second.
    public var onTuner: (() -> Void)?
    /// Tuner requests run between edits, never in their way, so they don't count as busy.
    public var busy: Bool { request.map { !Self.tunerOperations.contains($0.operation) } ?? false }

    // Tuner. The Mac gives the QC the strongest mode any device wants: open (shown, and mute
    // applies), then live (streaming, never muted), then off.
    public enum TunerMode: String { case off, live, open }
    static let tunerOperations: Set<String> = ["tuner", "tuner_read", "set_tuner_mute"]
    /// Edits this phone sends. Their outcome is reported and they are never replayed.
    static let mutations: Set<String> = ["set_parameter", "set_bypass", "select_scene", "select_preset", "save"]

    // Scenes. The strip always draws the scene the QC confirmed; this only marks the tapped one.
    public enum SceneSwitch: Equatable { case pending(String), confirmed(String), notApplied(String), unknown(String) }
    public private(set) var sceneSwitch: SceneSwitch?
    public var sceneSwitchAvailable: Bool { phase == .ready && editor.supports("select_scene") }
    /// A newer tap made while a switch was in flight. It replaces the one before it.
    private var queuedScene: String?
    /// "On the QC" shows this long after a confirmed switch, then clears.
    private let sceneConfirmationTime: TimeInterval = 1.6
    private var sceneSettledAt = TimeInterval.infinity
    /// The preset the last switch was sent on. A scene letter means nothing on another preset.
    private var sceneSwitchPreset: String?

    // Presets. The list is read once (about 12 s on the QC) and kept until Refresh. The loaded
    // preset stays the one the QC reports; a switch only marks the row it was sent for.
    public enum PresetSwitch: Equatable {
        /// Saving the current preset before loading the target.
        case saving(String)
        case pending(String)
        /// The QC loaded it; its blocks' metadata is still on the way.
        case loading(String)
        case notApplied(String, String)
        case unknown(String)
        public var target: String {
            switch self { case .saving(let id), .pending(let id), .loading(let id), .notApplied(let id, _), .unknown(let id): return id }
        }
    }
    public enum PresetSwitchMode { case clean, discard, saveFirst }
    public private(set) var presetList: PresetList?
    public private(set) var presetListError: String?
    public private(set) var presetSwitch: PresetSwitch?
    public var presetBrowsingAvailable: Bool { phase == .ready && editor.supports("list_presets") }
    public var presetSwitchAvailable: Bool { presetBrowsingAvailable && editor.supports("select_preset") }
    /// A list request is in flight or waiting for the request slot.
    public var listingPresets: Bool { request?.operation == "list_presets" || wantsList }
    private var wantsList = false
    private var listRetryAt: TimeInterval = 0
    /// A switch tapped during a background read; it goes as soon as the read returns, and only
    /// if the preset is still the one the player approved.
    private var queuedPreset: (id: String, mode: PresetSwitchMode, approved: PresetSnapshot)?
    /// The preset to load once the save sent for it is confirmed.
    private var afterSave: String?
    /// The staged preset while its metadata loads, so the overview can draw its name.
    public var loadingPreset: PresetSnapshot? { if case .loading? = presetSwitch { return staged } else { return nil } }
    public private(set) var tunerMode: TunerMode = .off
    public private(set) var tunerMuted: Bool?
    public private(set) var tunerError: String?
    public private(set) var tunerTrack = TunerTrack()
    public var tunerAvailable: Bool { operations.contains("tuner") && operations.contains("tuner_read") }
    public var tunerMuteAvailable: Bool { operations.contains("set_tuner_mute") }
    public func tunerPitch() -> TunerPitch? { tunerTrack.pitch(at: now()) }
    private var tunerSeq = 0
    private var tunerSync = false
    private var muteRequest: Bool?
    private var nextTunerRead = TimeInterval.infinity
    /// An edit or save that arrived while a tuner request was in flight; it goes first.
    private var held: (operation: String, command: [String: Any])?
    private let tunerInterval: TimeInterval = 0.08
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
        held = nil; tunerMode = .off; tunerMuted = nil; tunerError = nil; tunerTrack = TunerTrack()
        sceneSwitch = nil; queuedScene = nil; sceneSettledAt = .infinity; sceneSwitchPreset = nil
        presetList = nil; presetListError = nil; presetSwitch = nil; wantsList = false; listRetryAt = 0
        queuedPreset = nil; afterSave = nil
        tunerSeq = 0; tunerSync = false; muteRequest = nil; nextTunerRead = .infinity
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
        if case .confirmed? = sceneSwitch, now() >= sceneSettledAt { sceneSwitch = nil; sceneSettledAt = .infinity; onChange?() }
        guard !isInBackground else { return }
        if phase == .ready, request == nil, now() >= nextPoll { refresh() }
        pump()
        if phase == .recovering, !busy, now() >= nextPoll { send("recover") }
        if phase == .loading, !busy, let step = deferred, now() >= step.at { deferred = nil; send(step.operation) }
    }
    /// Starts, changes or stops this phone's tuner. It keeps its mode across reconnects.
    public func setTuner(_ mode: TunerMode) {
        guard mode != tunerMode else { return }
        tunerMode = mode; tunerError = nil; tunerSync = true
        if mode == .off { tunerTrack = TunerTrack(); tunerMuted = nil; muteRequest = nil }
        pump(); onChange?()
    }
    /// Mute only applies while the tuner is open; the QC confirms each change.
    public func setTunerMuted(_ muted: Bool) {
        guard tunerMode == .open, tunerMuteAvailable else { return }
        tunerError = nil; muteRequest = muted; pump(); onChange?()
    }
    /// Reads My Presets from the QC, or re-reads it. The old list stays usable meanwhile.
    public func listPresets() {
        guard presetBrowsingAvailable, !listingPresets else { return }
        presetListError = nil; wantsList = true; listRetryAt = 0; pump(); onChange?()
    }
    /// Loads a preset. A dirty preset needs `discard` or `saveFirst`; the bridge refuses it otherwise.
    /// `approved` is the state the player chose that against (by default, what is on screen now):
    /// discarding or saving goes ahead only while the QC still holds exactly that. A tap during a
    /// background read waits for it. Never replayed after a failure.
    public func selectPreset(_ id: String, mode: PresetSwitchMode = .clean, approved: PresetSnapshot? = nil) throws {
        guard phase == .ready else { throw EditorFailure.disconnected }
        guard presetSwitchAvailable else { throw EditorFailure.unsupported }
        guard let snapshot = editor.snapshot, presetList?.entries.contains(where: { $0.preset_id == id }) == true else { throw EditorFailure.invalidValue }
        let approved = approved ?? snapshot
        guard approvalHolds(mode, approved) else {
            presetSwitch = .notApplied(id, Self.changedBeforeSwitch); onChange?(); return
        }
        if mode == .saveFirst && !editor.supports("save") { throw EditorFailure.unsupported }
        if id == snapshot.preset_id && !snapshot.dirty { presetSwitch = nil; onChange?(); return }
        // A background read (the list or a poll) is in the way: go right after it.
        if let reading = request?.operation, ["list_presets", "snapshot"].contains(reading) {
            queuedPreset = (id, mode, approved); presetSwitch = mode == .saveFirst ? .saving(id) : .pending(id); onChange?(); return
        }
        guard !busy else { throw EditorFailure.busy }
        outcome = nil; error = nil
        try sendPreset(id, mode: mode)
    }
    static let changedBeforeSwitch = "Not switched. The preset changed before it went; review its edits and try again."
    /// A clean switch loses nothing, so any state will do. Discarding or saving acts on the
    /// edits the player saw, so the preset must not have moved at all since.
    private func approvalHolds(_ mode: PresetSwitchMode, _ approved: PresetSnapshot) -> Bool {
        mode == .clean || editor.snapshot == approved
    }
    /// Forgets a refusal or unknown outcome once the browser that showed it closes.
    public func clearPresetSwitch() {
        switch presetSwitch { case .notApplied?, .unknown?: presetSwitch = nil; onChange?(); default: break }
    }
    private func sendPreset(_ id: String, mode: PresetSwitchMode) throws {
        queuedPreset = nil
        if mode == .saveFirst, editor.snapshot?.dirty == true {
            let pending = try editor.proposeSave()
            afterSave = id; presetSwitch = .saving(id)
            send(pending.operation, command: pending.command); return
        }
        let pending = try editor.proposePreset(id, discard: mode == .discard)
        presetSwitch = .pending(id)
        send(pending.operation, command: pending.command)
    }
    /// The QC answered a preset switch, or the save before it, without loading it.
    private func presetRefused(_ pending: Request, code: String, message: String, response: [String: Any]) -> Bool {
        let target: String
        if pending.operation == "select_preset", case .text(let id)? = editor.pending?.proposedValue { target = id }
        else if pending.operation == "save", let id = afterSave { target = id }
        else { return false }
        afterSave = nil
        let sameSession = response["session_id"] as? String == session
        let saving = pending.operation == "save"
        if ["busy", "device_busy"].contains(code) {
            presetSwitch = .notApplied(target, code == "busy" ? "The bridge was busy with another device. Try again." : "The QC was changing scene or preset. Try again.")
        } else if sameSession && code == "not_confirmed" {
            presetSwitch = saving ? .notApplied(target, "Not switched. The save’s outcome is unknown; check the QC before switching.") : .unknown(target)
        } else if sameSession && ["stale_context", "invalid_value", "unsupported_operation", "unsaved_changes"].contains(code) {
            presetSwitch = .notApplied(target, code == "unsaved_changes" ? "Not switched. The preset has unsaved edits." : saving ? "Not switched. The save didn’t go through." : message)
        } else { return false }
        if pending.operation == "select_preset" && sameSession && code == "invalid_value" {
            // The bridge doesn't know that slot: its listing is gone or newer than ours.
            presetSwitch = .notApplied(target, "Not switched. The list was out of date; it’s being read again.")
            presetList = nil; wantsList = true; listRetryAt = 0
        }
        editor.reject(id: pending.id, message: nil)
        if ["busy", "device_busy"].contains(code) { ready(keepingPoll: true); pump(); onChange?() }
        else { phase = .loading; send("snapshot") }
        return true
    }
    /// Shows a loaded preset: at once when its metadata is cached, otherwise once it arrives.
    private func adopt(_ state: PresetSnapshot, session newSession: String, revision newRevision: Int) throws {
        if state.catalog_id != editor.catalog?.id || !Set(state.blocks.map(\.model_id)).isSubset(of: cachedModels) {
            staged = state; revision = newRevision; phase = .loading
            editor.disconnect(); try loadCatalogIfNeeded()
        } else {
            try editor.refresh(state, session: newSession, connection: connection!, revision: newRevision)
            revision = newRevision; ready()
        }
    }
    /// Sends what is waiting, in order: a held edit, a queued preset switch, the preset list,
    /// a tuner change, then the next tuner read.
    private func pump() {
        guard phase == .ready, request == nil else { return }
        if let held { self.held = nil; send(held.operation, command: held.command); return }
        if let queued = queuedPreset {
            // The read that held it may have shown another preset, or new edits on this one.
            guard approvalHolds(queued.mode, queued.approved) else {
                queuedPreset = nil; presetSwitch = .notApplied(queued.id, Self.changedBeforeSwitch); onChange?(); return
            }
            do { try sendPreset(queued.id, mode: queued.mode) }
            catch { queuedPreset = nil; presetSwitch = .notApplied(queued.id, "Not switched. Refresh the preset and try again."); onChange?() }
            if request != nil { return }
        }
        if wantsList, now() >= listRetryAt, !isInBackground { wantsList = false; send("list_presets"); return }
        guard tunerAvailable, !isInBackground else { return }
        if tunerSync { tunerSync = false; send("tuner", payload: ["mode": tunerMode.rawValue]); return }
        if let mute = muteRequest { muteRequest = nil; send("set_tuner_mute", payload: ["value": mute]); return }
        if tunerMode != .off, now() >= nextTunerRead { send("tuner_read", payload: ["after": tunerSeq]) }
    }
    private func applyTuner(_ object: Any?, operation: String) throws {
        guard let tuner = object as? [String: Any], let mode = tuner["mode"] as? String, let seq = integer(tuner["seq"]) else { throw EditorFailure.invalidState }
        tunerMuted = tuner["muted"] as? Bool
        // Another device can stop or restart the stream, which starts its numbering over.
        if seq < tunerSeq { tunerSeq = 0 }
        let readings = (tuner["readings"] as? [[String: Any]]) ?? []
        for reading in readings {
            guard let number = integer(reading["seq"]), number > tunerSeq, let hz = reading["hz"] as? Double else { continue }
            tunerTrack.add(hz: hz, at: now()); tunerSeq = number
        }
        tunerSeq = max(tunerSeq, seq)
        // The helper's tuner is off although this phone wants it: a new USB session. Ask again.
        if mode == "off", tunerMode != .off { tunerSync = true }
        nextTunerRead = operation == "tuner_read" ? now() + tunerInterval : now()
        if automaticPolling { DispatchQueue.main.asyncAfter(deadline: .now() + tunerInterval) { [weak self] in self?.tick() } }
    }
    public func edit(blockID: String, parameterID: String, value: ParameterValue) throws {
        guard phase == .ready else { throw EditorFailure.disconnected }
        guard !busy else { throw EditorFailure.busy }
        outcome = nil
        let pending = try editor.propose(blockID: blockID, parameterID: parameterID, value: value)
        send(pending.operation, command: pending.command)
    }
    public func setBypass(blockID: String, bypassed: Bool) throws {
        guard phase == .ready else { throw EditorFailure.disconnected }
        guard !busy else { throw EditorFailure.busy }
        outcome = nil
        let pending = try editor.proposeBypass(blockID: blockID, bypassed: bypassed)
        send(pending.operation, command: pending.command)
    }
    /// Asks the QC to switch scene. A tap while another switch is in flight replaces it: the
    /// newest one goes to the QC as soon as the current one answers. Never replayed after a failure.
    public func selectScene(_ scene: String) throws {
        guard phase == .ready else { throw EditorFailure.disconnected }
        guard editor.supports("select_scene") else { throw EditorFailure.unsupported }
        guard PresetSnapshot.sceneLetters.contains(scene) else { throw EditorFailure.invalidValue }
        if request?.operation == "select_scene" || held?.operation == "select_scene" {
            queuedScene = scene; sceneSwitch = .pending(scene); onChange?(); return
        }
        guard !busy else { throw EditorFailure.busy }
        // The QC is already there and nothing else is waiting on the strip.
        if scene == editor.snapshot?.scene { sceneSwitch = nil; onChange?(); return }
        outcome = nil
        try sendScene(scene)
    }
    /// The scene the switch on its way to the QC asked for; a later tap may already be queued.
    private var inFlightScene: String? {
        guard editor.pending?.operation == "select_scene", case .text(let scene)? = editor.pending?.proposedValue else { return nil }
        return scene
    }
    private func sendScene(_ scene: String) throws {
        queuedScene = nil
        let pending = try editor.proposeScene(scene)
        sceneSwitch = .pending(scene); sceneSettledAt = .infinity; sceneSwitchPreset = editor.snapshot?.preset_id
        send(pending.operation, command: pending.command)
    }
    /// The QC answered a switch without confirming it. Nothing is retried; a stale or unknown
    /// outcome reloads state first.
    private func sceneRefused(_ pending: Request, code: String, response: [String: Any]) -> Bool {
        guard pending.operation == "select_scene", let scene = inFlightScene else { return false }
        let sameSession = response["session_id"] as? String == session
        if ["busy", "device_busy"].contains(code) || (sameSession && ["stale_context", "invalid_value", "unsupported_operation"].contains(code)) {
            sceneSwitch = .notApplied(scene)
        } else if sameSession && code == "not_confirmed" {
            sceneSwitch = .unknown(scene)
        } else { return false }
        queuedScene = nil; editor.reject(id: pending.id, message: nil)
        if code == "busy" || code == "device_busy" { ready(keepingPoll: true) } else { phase = .loading; send("snapshot"); return true }
        pump(); onChange?(); return true
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
    private func send(_ operation: String, command: [String: Any]? = nil, payload: [String: Any]? = nil) {
        // An edit waits for a tuner request already in flight, then goes before anything else.
        if let request, Self.tunerOperations.contains(request.operation), command != nil { held = (operation, command!); onChange?(); return }
        guard request == nil, let transport else { return }
        var message = command ?? ["version": 1, "id": UUID().uuidString, "operation": operation]
        if let payload { message["payload"] = payload }
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
                // The Mac no longer trusts this phone (trust was revoked or evicted).
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
                if sceneRefused(pending, code: code, response: response) { return }
                if presetRefused(pending, code: code, message: message, response: response) { return }
                // A list that couldn't be read leaves the connection as it was.
                if pending.operation == "list_presets", code != "device_unavailable",
                   response["session_id"] as? String == session || code == "busy" {
                    if code == "busy" || code == "device_busy" {
                        let retry = response["retry_after"] as? Double ?? 1
                        wantsList = true; listRetryAt = now() + (retry.isFinite ? min(8, max(0.5, retry)) : 1)
                    } else { presetListError = code == "unsupported_operation" ? "This bridge can’t list presets." : message }
                    ready(keepingPoll: true); pump(); onChange?(); return
                }
                if code == "busy" || code == "device_busy" {
                    let retry = response["retry_after"] as? Double ?? 1
                    let delay = retry.isFinite ? min(8, max(0.5, retry)) : 1
                    if Self.tunerOperations.contains(pending.operation) {
                        // Nothing reached the QC; ask again once the bridge is free.
                        if pending.operation == "tuner" { tunerSync = true }
                        nextTunerRead = now() + delay
                    } else if Self.mutations.contains(pending.operation) {
                        let cause = code == "busy" ? "The bridge was busy with another device" : "The QC was changing scene or preset"
                        let text = pending.operation == "save" ? "Save not applied. \(cause); try again." : "Not applied. \(cause); try again."
                        editor.reject(id: pending.id, message: text); error = text; ready()
                    } else if phase == .ready || phase == .recovering {
                        nextPoll = now() + delay
                    } else if phase == .loading {
                        deferred = (pending.operation, now() + delay)
                    } else { fail(message); return }
                    onChange?(); return
                }
                if code == "device_unavailable" {
                    let uncertain = Self.mutations.contains(pending.operation)
                    let scene = pending.operation == "select_scene" ? inFlightScene : nil
                    let preset = pending.operation == "select_preset" || (pending.operation == "save" && afterSave != nil)
                        ? presetList?.entries.first { $0.preset_id == presetSwitch?.target }?.name ?? "the preset" : nil
                    editor.disconnect(); staged = nil; session = nil; operations.removeAll(); held = nil
                    sceneSwitch = nil; queuedScene = nil
                    presetSwitch = nil; queuedPreset = nil; afterSave = nil; wantsList = false
                    phase = .recovering; status = "QC unavailable · reconnecting"
                    if let preset, pending.operation == "select_preset" {
                        error = response["applied"] as? Bool == false ? "\(preset) not loaded. Switching resumes after the QC reconnects."
                            : "Load \(preset): outcome unknown. It will not be retried."
                    } else if let scene {
                        // The strip is gone until fresh state loads, so say it in words.
                        error = response["applied"] as? Bool == false ? "Scene \(scene) not applied. Switching resumes after the QC reconnects."
                            : "Switch to Scene \(scene): outcome unknown. It will not be retried."
                    } else if uncertain {
                        // The bridge marks an edit it never sent; only then is the outcome certain.
                        error = response["applied"] as? Bool == false
                            ? (pending.operation == "save" ? "Save not applied. Editing resumes after the QC reconnects." : "Edit not applied. Editing resumes after the QC reconnects.")
                            : "Last edit or save outcome unknown. It will not be retried."
                    }
                    let delay = response["retry_after"] as? Double ?? 1
                    nextPoll = now() + (delay.isFinite ? min(8, max(0.5, delay)) : 1)
                    onChange?(); return
                }
                // The tuner never ends the connection: say what went wrong and keep editing.
                if Self.tunerOperations.contains(pending.operation), response["session_id"] as? String == session {
                    if pending.operation == "tuner" { tunerMode = .off; tunerTrack = TunerTrack() }
                    if pending.operation != "tuner_read" || code != "unsupported_operation" { tunerError = message }
                    if code == "unsupported_operation" { tunerMode = .off }
                    nextTunerRead = now() + 1; ready(keepingPoll: true); pump(); onChange?(); return
                }
                // Only explicit, session-preserving rejections are recoverable. Resync before more edits.
                if Self.mutations.contains(pending.operation),
                   ["stale_context", "invalid_value", "unsupported_parameter", "unsupported_operation", "not_confirmed"].contains(code),
                   response["session_id"] as? String == session {
                    let text = code == "stale_context" ? Self.deviceName(response).map { "Not applied. \($0) changed it first." } ?? message
                        : code == "not_confirmed" ? (pending.operation == "save" ? "Save outcome unknown. The QC changed scene or preset during it; it will not be retried."
                                                     : "Outcome unknown. The QC changed scene or preset during the edit; it will not be retried.")
                        : message
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
                // A new helper session forgot the listing that allowed each slot, so read it again
                // before switching. No switch survives either.
                presetSwitch = nil; queuedPreset = nil; afterSave = nil
                presetList = nil; presetListError = nil; wantsList = false
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
                // Readback settles a switch whose answer was lost, but only on the preset it was sent
                // on. A scene or preset change elsewhere retires a refusal or an unknown outcome.
                switch presetSwitch {
                case .unknown(let id)? where state.preset_id == id:
                    presetSwitch = nil; outcome = "Loaded \(state.name)"
                case .notApplied?, .unknown?:
                    if state.preset_id != editor.snapshot?.preset_id { presetSwitch = nil }
                default: break
                }
                switch sceneSwitch {
                case .unknown(let scene)? where state.preset_id == sceneSwitchPreset && state.scene == scene:
                    sceneSwitch = .confirmed(scene); sceneSettledAt = now() + sceneConfirmationTime; outcome = nil
                case .notApplied?, .unknown?:
                    if state.preset_id != sceneSwitchPreset || state.scene != editor.snapshot?.scene { sceneSwitch = nil }
                default: break
                }
                guard newRevision > revision || state == editor.snapshot else { throw EditorFailure.staleContext }
                try adopt(state, session: newSession, revision: newRevision)
            case "select_scene":
                let state = try decode(PresetSnapshot.self, result["state"])
                try editor.confirm(id: pending.id, snapshot: state, session: newSession, connection: connection!, revision: newRevision)
                revision = newRevision; error = nil; ready()
                if let next = queuedScene, next != state.scene {
                    try sendScene(next)
                } else {
                    queuedScene = nil; sceneSwitch = .confirmed(state.scene); sceneSettledAt = now() + sceneConfirmationTime
                    pump()
                }
            case "list_presets":
                guard let presets = result["presets"] as? [String: Any], let source = presets["source"] as? String,
                      let slots = integer(presets["slots"]), (1...4096).contains(slots) else { throw EditorFailure.invalidState }
                let entries = try decode([PresetList.Entry].self, presets["entries"])
                guard entries.count <= slots, Set(entries.map(\.preset_id)).count == entries.count,
                      entries.allSatisfy({ (1...slots).contains($0.number) && !$0.preset_id.isEmpty }) else { throw EditorFailure.invalidState }
                presetList = PresetList(source: source, slots: slots, entries: entries, listedAt: Date())
                presetListError = nil
                ready(keepingPoll: true); pump()
            case "select_preset":
                let state = try decode(PresetSnapshot.self, result["state"])
                guard case .text(let target)? = editor.pending?.proposedValue, state.preset_id == target,
                      newRevision > revision || state.preset_id == editor.snapshot?.preset_id else { throw EditorFailure.staleContext }
                editor.reject(id: pending.id, message: nil)
                sceneSwitch = nil; queuedScene = nil; error = nil
                try adopt(state, session: newSession, revision: newRevision)
                if phase == .loading { presetSwitch = .loading(target) }
                else { presetSwitch = nil; outcome = "Loaded \(state.name)"; pump() }
            case "set_parameter", "set_bypass", "save":
                let state = try decode(PresetSnapshot.self, result["state"])
                let proposed = editor.pending
                try editor.confirm(id: pending.id, snapshot: state, session: newSession, connection: connection!, revision: newRevision)
                if pending.operation == "save", let target = afterSave {
                    // Saved: now load what the player picked. The preset is clean, so nothing is discarded.
                    afterSave = nil; revision = newRevision; error = nil; ready()
                    try sendPreset(target, mode: .clean); onChange?(); return
                }
                if pending.operation == "save" { outcome = "Saved on the QC" }
                else if pending.operation == "set_bypass", let block = proposed?.blockID, case .boolean(let wanted)? = proposed?.proposedValue {
                    outcome = editor.bypassed(blockID: block) == wanted ? (wanted ? "Bypassed" : "Enabled") : "Adjusted by the QC"
                }
                else if let block = proposed?.blockID, let parameter = proposed?.parameterID {
                    outcome = editor.value(blockID: block, parameterID: parameter) == proposed?.proposedValue ? "Confirmed" : "Adjusted by the QC"
                }
                revision = newRevision; error = nil; ready()
            case "tuner", "tuner_read", "set_tuner_mute":
                try applyTuner(result["tuner"], operation: pending.operation)
                pump()
                // Readings redraw only the tuner; everything else redraws the screen.
                if pending.operation == "tuner_read" { onTuner?(); return }
                onTuner?()
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
        if case .loading? = presetSwitch { presetSwitch = nil; outcome = "Loaded \(staged.name)" }
        // A fresh session starts with the tuner off; ask for this phone's mode again.
        tunerSeq = 0; tunerTrack = TunerTrack()
        if tunerMode != .off { tunerSync = true; nextTunerRead = now() }
        pump()
    }
    private func ready(keepingPoll: Bool = false) {
        phase = .ready; status = "Confirmed state loaded"
        if !keepingPoll { nextPoll = now() + pollInterval }
    }
}
