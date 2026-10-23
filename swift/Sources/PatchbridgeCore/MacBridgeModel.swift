#if os(macOS)
import Foundation
import Combine

/// One device admitted by the bridge, as the shell shows it.
struct BridgeDevice: Identifiable, Equatable {
    enum State: Equatable { case awaitingApproval, approving, connected }
    let id: UUID
    /// The device's connection token, so an action applies to this connection and no later one.
    let connection: String
    var name: String
    var state: State
    /// The device's entry in the trust list, if it is trusted.
    var trustID: UUID?
    var trusted: Bool { trustID != nil }
}
/// A device trusted to reconnect without a code until its trust is revoked.
struct TrustedDevice: Identifiable, Equatable {
    let id: UUID
    let name: String
    var connected = false
}
struct MacBridgePresentation {
    var macName = DeviceIdentity.macName
    /// The device the approval card, or a single-device title, refers to.
    var phoneName = "iPhone"
    var approvalCode = ""
    /// The connection on the approval card. Approve and Deny act on exactly this one.
    var pendingID: UUID?
    var pendingConnection: String?
    /// Devices queued behind the approval card.
    var waiting = 0
    var devices: [BridgeDevice] = []
    var trusted: [TrustedDevice] = []
    var preset: String?
    var scene: String?
    var dirty = false
    var recovering = false
    /// Devices past approval, in the order they connected.
    var connected: [BridgeDevice] { devices.filter { $0.state != .awaitingApproval } }
}
protocol OfflineBridgeBackend: AnyObject {
    var presentation: MacBridgePresentation { get }
    var isLive: Bool { get }
    var state: (MacBridgeModel.Phase, String)? { get }
    var onChange: (() -> Void)? { get set }
    func start() throws
    func requestPhone() throws
    /// Approves exactly the connection the card showed. If it has left or changed, nothing
    /// is approved, and no other device is affected.
    func approve(device: UUID, connection: String, trust: Bool) throws
    /// Denies exactly the connection the card showed; a stale request does nothing.
    func deny(device: UUID, connection: String)
    /// Ends exactly that connection; a stale request does nothing.
    func disconnect(device: UUID, connection: String)
    func revokeTrust(id: UUID)
    func requestSecondDevice() throws
    func editFromOtherDevice() throws
    func refresh() throws
    func stop()
    func interruptHelper()
    func interruptDevice() throws
    func editSimulation(value: Double, stale: Bool) throws
}
extension OfflineBridgeBackend {
    var isLive: Bool { false }
    var state: (MacBridgeModel.Phase, String)? { nil }
    var onChange: (() -> Void)? { get { nil } set {} }
    var presentation: MacBridgePresentation { MacBridgePresentation() }
    func interruptDevice() throws { throw BridgeFailure.protocolError }
    func editSimulation(value: Double, stale: Bool) throws { throw BridgeFailure.protocolError }
    func approve(device: UUID, connection: String, trust: Bool) throws { throw BridgeFailure.protocolError }
    func deny(device: UUID, connection: String) {}
    func disconnect(device: UUID, connection: String) {}
    func revokeTrust(id: UUID) {}
    func requestSecondDevice() throws { throw BridgeFailure.protocolError }
    func editFromOtherDevice() throws { throw BridgeFailure.protocolError }
}

/// Only constructs a bundled simulator. No radio or USB transport is available here.
/// A simulated iPhone, and optionally a simulated iPad, share one helper session.
final class BundledOfflineBackend: OfflineBridgeBackend {
    private final class Simulated {
        let id = UUID()
        let session: DeviceSession
        let name: String
        var state = BridgeDevice.State.awaitingApproval
        var helperSession: String?
        var revision = 0
        init(session: DeviceSession, name: String) { self.session = session; self.name = name }
    }
    private let makeHelper: () throws -> HelperClient
    private var helper: HelperClient?
    private var shared: SharedUSBSession?
    private var devices: [Simulated] = []
    private var snapshot: [String: Any]?
    private(set) var presentation = MacBridgePresentation()
    init(makeHelper: @escaping () throws -> HelperClient = { try HelperClient(bundle: .main) }) {
        self.makeHelper = makeHelper
    }
    func start() throws {
        stop(); let helper = try makeHelper(); self.helper = helper
        let shared = SharedUSBSession(helper: helper, allowsRecovery: true)
        self.shared = shared
    }
    private var connected: [Simulated] { devices.filter { $0.state == .connected } }
    private func send(_ device: Simulated, _ operation: String, fields: [String: Any] = [:]) throws -> [String: Any] {
        var message: [String: Any] = ["version": 1, "id": UUID().uuidString, "operation": operation, "connection_id": device.session.token]
        if operation == "hello" { message["device_name"] = device.name }
        if let session = device.helperSession { message["session_id"] = session }
        message.merge(fields) { $1 }
        return try device.session.handle(message)
    }
    private func publish() {
        presentation.devices = devices.map { BridgeDevice(id: $0.id, connection: $0.session.token, name: $0.session.phoneName, state: $0.state, trustID: $0.session.trustEntryID) }
        let active = devices.filter { $0.state != .awaitingApproval }
        presentation.trusted = (shared?.trust.list ?? []).map { entry in
            TrustedDevice(id: entry.id, name: entry.name, connected: active.contains { $0.session.trustEntryID == entry.id })
        }
        let waiting = devices.filter { $0.state == .awaitingApproval }
        presentation.waiting = max(0, waiting.count - 1)
        presentation.pendingID = waiting.first?.id; presentation.pendingConnection = waiting.first?.session.token
        let shown = waiting.first ?? active.first
        presentation.phoneName = shown?.session.phoneName ?? "iPhone"
        presentation.approvalCode = shown?.session.approvalCode ?? ""
    }
    private func admit(_ name: String) throws {
        guard let shared, let session = shared.admit() else { throw BridgeFailure.disconnected }
        let device = Simulated(session: session, name: name); devices.append(device)
        let reply = try send(device, "hello")
        guard reply["authorization_required"] as? Bool == true else { throw BridgeFailure.protocolError }
        publish()
    }
    func requestPhone() throws { try admit(DeviceIdentity.phoneName) }
    func requestSecondDevice() throws { try admit("Simulated iPad") }
    private func device(_ id: UUID, _ connection: String, in state: BridgeDevice.State? = nil) -> Simulated? {
        devices.first { $0.id == id && $0.session.token == connection && (state == nil || $0.state == state) }
    }
    func approve(device id: UUID, connection: String, trust: Bool) throws {
        guard let device = device(id, connection, in: .awaitingApproval) else { publish(); return } // The card changed meanwhile.
        device.session.approve(trusting: trust)
        let reply = try send(device, "connect")
        guard reply["status"] as? String == "confirmed", let session = reply["session_id"] as? String else { throw BridgeFailure.protocolError }
        device.helperSession = session; device.state = .connected
        try refresh(device)
        publish()
    }
    private func edit(from device: Simulated, value: Double, revision: Int) throws {
        guard let snapshot else { throw BridgeFailure.disconnected }
        _ = try send(device, "set_parameter", fields: ["revision": revision, "preset_id": snapshot["preset_id"] ?? "", "scene": snapshot["scene"] ?? "",
                                                         "payload": ["block_id": "amp-1", "parameter_id": "gain", "value": value]])
    }
    func editSimulation(value: Double, stale: Bool) throws {
        guard let device = connected.first else { throw BridgeFailure.disconnected }
        try edit(from: device, value: value, revision: stale ? -1 : device.revision)
        try refresh(device)
    }
    /// The second device edits, leaving the first device's revision behind: its next edit is
    /// rejected as stale until it reloads, exactly as on real devices.
    func editFromOtherDevice() throws {
        guard connected.count > 1 else { throw BridgeFailure.disconnected }
        let other = connected[1]
        try refresh(other)
        try edit(from: other, value: 3.5, revision: other.revision)
        try refresh(other)
    }
    func deny(device id: UUID, connection: String) {
        guard device(id, connection, in: .awaitingApproval) != nil else { publish(); return }
        end(id)
    }
    func disconnect(device id: UUID, connection: String) {
        guard device(id, connection) != nil else { publish(); return }
        end(id)
    }
    private func end(_ id: UUID) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        shared?.remove(devices.remove(at: index).session)
        if connected.isEmpty {
            snapshot = nil
            presentation = MacBridgePresentation()
        }
        publish()
    }
    func revokeTrust(id: UUID) { shared?.revokeTrust(id: id); publish() }
    func interruptDevice() throws {
        guard let device = connected.first else { throw BridgeFailure.disconnected }
        try device.session.simulateDeviceRemoval(); device.helperSession = nil; presentation.recovering = true
    }
    func refresh() throws {
        for device in connected { try refresh(device) }
        publish()
    }
    private func refresh(_ device: Simulated) throws {
        var reply = try send(device, shared?.recovering == true ? "recover" : "snapshot")
        func unavailable() -> Bool { (reply["error"] as? [String: Any])?["code"] as? String == "device_unavailable" }
        // Another device already recovered: this one adopts the new session.
        if unavailable() && shared?.recovering == false { reply = try send(device, "recover") }
        if unavailable() { presentation.recovering = true; device.helperSession = nil; return }
        guard reply["status"] as? String == "confirmed", let session = reply["session_id"] as? String,
              let result = reply["result"] as? [String: Any], let state = result["state"] as? [String: Any],
              let dirty = state["dirty"] as? Bool else { throw BridgeFailure.protocolError }
        device.helperSession = session; device.revision = reply["revision"] as? Int ?? 0; snapshot = state
        presentation.preset = state["name"] as? String
        presentation.scene = state["scene"] as? String
        presentation.dirty = dirty
        presentation.recovering = false
    }
    func stop() {
        devices.forEach { shared?.remove($0.session) }; devices.removeAll()
        snapshot = nil
        presentation = MacBridgePresentation()
        helper?.stop(); shared = nil; helper = nil
    }
    func interruptHelper() { helper?.stop() }
}

/// Main-queue UI owner; helper/session work is serialized off the UI thread.
final class MacBridgeModel: ObservableObject {
    enum Phase: Equatable { case stopped, starting, running, awaitingApproval, approving, connected, recovering, stopping, failed }
    @Published private(set) var phase: Phase = .stopped
    @Published private(set) var presentation = MacBridgePresentation()
    private var recoveryTimer: Timer?
    @Published private(set) var busy = false
    @Published private(set) var detail = "Start the bridge to try a simulated phone connection."
    var onChange: (() -> Void)?
    private var backend: OfflineBridgeBackend
    private let queue = DispatchQueue(label: "patchbridge.mac-host")
    @Published private(set) var isSimulation = false
    private var generation = UUID()
    /// The live bridge's trusted devices, shared by every live backend this app creates.
    private static let trust = TrustRegistry(storage: KeychainTrustStorage())
    init(backend: OfflineBridgeBackend? = nil) {
        self.backend = backend ?? LiveBridgeBackend(peripheral: BLEPeripheral(queue: queue), trust: Self.trust, queue: queue)
        isSimulation = !self.backend.isLive
        detail = isSimulation ? "Start the bridge to try a simulated phone connection." : "Connect your QC over USB and close Cortex Control. Start the bridge to connect your iPhone or iPad."
    }
    func setSimulation(_ enabled: Bool) {
        guard phase == .stopped, !busy else { return }
        backend = enabled ? BundledOfflineBackend() : LiveBridgeBackend(peripheral: BLEPeripheral(queue: queue), trust: Self.trust, queue: queue)
        isSimulation = enabled
        presentation = MacBridgePresentation()
        detail = enabled ? "Simulation uses no Bluetooth or USB." : "Connect your QC over USB and close Cortex Control. Start the bridge to connect your iPhone or iPad."
        onChange?()
    }
    var title: String {
        switch phase {
        case .stopped: return "Bridge stopped"
        case .starting: return "Starting bridge…"
        case .running: return isSimulation ? "Ready for a simulated phone" : "Waiting for your iPhone or iPad"
        case .awaitingApproval: return "Approval requested"
        case .approving: return "Verifying connection…"
        case .connected:
            let names = presentation.connected.map(\.name)
            switch names.count {
            case 0, 1: return isSimulation ? "Simulated device connected" : "\(names.first ?? presentation.phoneName) connected"
            case 2: return "\(names[0]) and \(names[1]) connected"
            default: return "\(names.count) devices connected"
            }
        case .recovering: return "QC connection interrupted"
        case .stopping: return "Stopping bridge…"
        case .failed: return "Bridge needs attention"
        }
    }
    private func perform(_ work: @escaping (OfflineBridgeBackend) throws -> Void,
                         success: Phase, message: String, failureMessage: String = "The helper stopped responding. Start the bridge again; the phone will need fresh approval.") {
        let epoch = generation
        busy = true; onChange?()
        queue.async { [self] in
            let failed: Bool
            do { try work(backend); failed = false }
            catch { backend.stop(); failed = true }
            let presentation = backend.presentation
            let state = backend.state
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == epoch else { return }
                self.busy = false
                self.presentation = presentation
                self.phase = failed ? .failed : state?.0 ?? (presentation.recovering ? .recovering : success)
                self.detail = failed ? failureMessage : state?.1 ?? message
                self.recoveryTimer?.invalidate(); self.recoveryTimer = nil
                if self.phase == .recovering && self.isSimulation {
                    self.detail = "Simulated USB interruption. The phone stays approved. Reloading state before editing resumes."
                    self.recoveryTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in self?.refresh() }
                }
                self.onChange?()
            }
        }
    }
    func start() {
        guard phase == .stopped || phase == .failed else { return }
        generation = UUID(); phase = .starting; detail = isSimulation ? "Launching the bundled simulation helper." : "Starting the USB helper and Bluetooth service."
        let epoch = generation
        backend.onChange = { [weak self] in
            guard let self else { return }
            let presentation = self.backend.presentation
            let state = self.backend.state
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == epoch, let state else { return }
                self.presentation = presentation; self.phase = state.0; self.detail = state.1; self.onChange?()
            }
        }
        perform({ try $0.start() }, success: .running, message: "The helper is running. Simulate a phone to test approval.",
                failureMessage: "The helper couldn’t start. Restart the bridge, or export a report if it happens again.")
    }
    func stop() {
        guard phase != .stopped && phase != .stopping else { return }
        generation = UUID(); phase = .stopping; detail = "Ending the session and clearing approval."
        perform({ $0.stop() }, success: .stopped, message: "Bridge stopped. Any phone approval has been cleared.")
    }
    func requestPhone() {
        guard phase == .running && !busy else { return }
        perform({ try $0.requestPhone() }, success: .awaitingApproval,
                message: "Allow this simulated phone to read the simulation? Approval lasts for this connection only.")
    }
    /// Approves the device whose code is on screen, captured now: if it leaves before the
    /// worker runs, nothing is approved, rather than whichever device is waiting next.
    func approve(trust: Bool = false) {
        guard phase == .awaitingApproval && !busy, let id = presentation.pendingID, let connection = presentation.pendingConnection else { return }
        phase = .approving; detail = "Approving this connection and requesting a snapshot."
        perform({ try $0.approve(device: id, connection: connection, trust: trust) }, success: .connected, message: "Approval granted. A snapshot was confirmed by the bundled helper.")
    }
    /// Ends trust without disconnecting; the device's next connection shows a code.
    func revokeTrust(_ entry: TrustedDevice) {
        guard presentation.trusted.contains(entry) && !busy else { return }
        perform({ $0.revokeTrust(id: entry.id) }, success: phase, message: entry.connected ? "Trust revoked for \(entry.name). This connection continues; the next one needs approval." : "Trust revoked for \(entry.name). Its next connection needs approval.")
    }
    func disconnect(_ device: BridgeDevice) {
        guard presentation.devices.contains(where: { $0.id == device.id }) && !busy else { return }
        let others = presentation.connected.contains { $0.id != device.id && $0.state == .connected }
        perform({ $0.disconnect(device: device.id, connection: device.connection) }, success: others ? .connected : .running, message: "\(device.name) disconnected. A new connection will need approval.")
    }
    func requestSecondDevice() {
        guard phase == .connected && isSimulation && !busy else { return }
        perform({ try $0.requestSecondDevice() }, success: .awaitingApproval,
                message: "Allow this simulated iPad to read the simulation? Approval lasts for this connection only.")
    }
    func simulateOtherDeviceEdit() {
        guard phase == .connected && isSimulation && !busy else { return }
        perform({ try $0.editFromOtherDevice() }, success: .connected,
                message: "The simulated iPad changed the gain. The next edit from the other device is rejected until it reloads.")
    }
    /// Denies the device on the approval card, or disconnects the device being verified,
    /// captured now so a stale tap never reaches a different connection.
    func disconnectPhone() {
        guard (phase == .awaitingApproval || phase == .approving || phase == .connected || phase == .recovering) && !busy else { return }
        if phase == .awaitingApproval {
            guard let id = presentation.pendingID, let connection = presentation.pendingConnection else { return }
            // Denying a second device leaves the first one connected.
            perform({ $0.deny(device: id, connection: connection) }, success: presentation.connected.contains { $0.state == .connected } ? .connected : .running,
                    message: "Request denied. Simulate another phone when you’re ready.")
        } else if let device = presentation.connected.first {
            disconnect(device)
        }
    }
    func refresh() {
        guard (phase == .connected || phase == .recovering) && !busy else { return }
        perform({ try $0.refresh() }, success: .connected, message: "Connection checked. The helper returned a confirmed snapshot.")
    }
    func simulateEdit(rejected: Bool = false) {
        guard phase == .connected && !busy else { return }
        perform({ try $0.editSimulation(value: 7.5, stale: rejected) }, success: .connected,
                message: rejected ? "The simulated edit was rejected. Confirmed state was reloaded." : "Gain confirmed by the simulator.")
    }
    func simulateUSBRemoval() {
        guard phase == .connected && !busy else { return }
        perform({ try $0.interruptDevice() }, success: .recovering, message: "Recovering simulated USB connection.")
    }
    func simulateFailure() {
        guard phase == .connected && !busy else { return }
        perform({ $0.interruptHelper(); try $0.refresh() }, success: .connected, message: "Connection checked.")
    }
    func shutdown() { recoveryTimer?.invalidate(); recoveryTimer = nil; generation = UUID(); queue.sync { backend.stop() } }
}
#endif
