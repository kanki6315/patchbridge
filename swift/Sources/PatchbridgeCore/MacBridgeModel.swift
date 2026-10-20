#if os(macOS)
import Foundation
import Combine

struct MacBridgePresentation {
    var macName = DeviceIdentity.macName
    var phoneName = "iPhone"
    var approvalCode = ""
    var preset: String?
    var scene: String?
    var dirty = false
    var recovering = false
    var recentEdits: [RecentBridgeEdit] = []
}
protocol OfflineBridgeBackend: AnyObject {
    var presentation: MacBridgePresentation { get }
    func start() throws
    func requestPhone() throws
    func approve() throws
    func revoke()
    func refresh() throws
    func stop()
    func interruptHelper()
    func interruptDevice() throws
    func editSimulation(value: Double, stale: Bool) throws
    func clearRecentEdits()
}
extension OfflineBridgeBackend {
    var presentation: MacBridgePresentation { MacBridgePresentation() }
    func interruptDevice() throws { throw BridgeFailure.protocolError }
    func editSimulation(value: Double, stale: Bool) throws { throw BridgeFailure.protocolError }
    func clearRecentEdits() {}
}

/// Only constructs a bundled simulator. No radio or USB transport is available here.
final class BundledOfflineBackend: OfflineBridgeBackend {
    private let makeHelper: () throws -> HelperClient
    private var helper: HelperClient?
    private var bridge: BridgeSession?
    private var session: String?
    private var snapshot: [String: Any]?
    private var catalog: [String: Any]?
    private var revision = 0
    private(set) var presentation = MacBridgePresentation()
    init(makeHelper: @escaping () throws -> HelperClient = { try HelperClient(bundle: .main) }) {
        self.makeHelper = makeHelper
    }
    func start() throws {
        stop(); let helper = try makeHelper(); self.helper = helper
        let bridge = BridgeSession(helper: helper, allowsRecovery: true)
        bridge.onMutation = { [weak self] request, response in
            guard let self else { return }
            self.presentation.recentEdits.insert(RecentBridgeEdit(request: request, response: response, snapshot: self.snapshot, catalog: self.catalog), at: 0)
            self.presentation.recentEdits = Array(self.presentation.recentEdits.prefix(12))
        }
        self.bridge = bridge
    }
    private func send(_ operation: String) throws -> [String: Any] {
        guard let bridge else { throw BridgeFailure.disconnected }
        var message: [String: Any] = ["version": 1, "id": UUID().uuidString, "operation": operation, "connection_id": bridge.token]
        if operation == "hello" { message["device_name"] = DeviceIdentity.phoneName }
        if let session { message["session_id"] = session }
        return try bridge.handle(message)
    }
    func requestPhone() throws {
        let reply = try send("hello")
        guard reply["authorization_required"] as? Bool == true else { throw BridgeFailure.protocolError }
        presentation.phoneName = bridge?.phoneName ?? "iPhone"
        presentation.approvalCode = bridge?.approvalCode ?? ""
    }
    func approve() throws {
        guard let bridge else { throw BridgeFailure.disconnected }
        bridge.approve()
        let reply = try send("connect")
        guard reply["status"] as? String == "confirmed", let session = reply["session_id"] as? String else { throw BridgeFailure.protocolError }
        self.session = session
        try refresh()
        let catalogReply = try send("catalog")
        catalog = catalogReply["result"] as? [String: Any]
    }
    func editSimulation(value: Double, stale: Bool) throws {
        guard let bridge, let session, let snapshot else { throw BridgeFailure.disconnected }
        let request: [String: Any] = ["version": 1, "id": UUID().uuidString, "operation": "set_parameter",
            "connection_id": bridge.token, "session_id": session, "revision": stale ? -1 : revision,
            "preset_id": snapshot["preset_id"] ?? "", "scene": snapshot["scene"] ?? "",
            "payload": ["block_id": "amp-1", "parameter_id": "gain", "value": value]]
        _ = try bridge.handle(request)
        try refresh()
    }
    func clearRecentEdits() { presentation.recentEdits.removeAll() }
    func revoke() { bridge?.revoke(); session = nil; snapshot = nil; catalog = nil
        let history = presentation.recentEdits
        presentation = MacBridgePresentation(); presentation.recentEdits = history }
    func interruptDevice() throws {
        guard let bridge else { throw BridgeFailure.disconnected }
        try bridge.simulateDeviceRemoval(); session = nil; presentation.recovering = true
    }
    func refresh() throws {
        let reply = try send(bridge?.recovering == true ? "recover" : "snapshot")
        if (reply["error"] as? [String: Any])?["code"] as? String == "device_unavailable" {
            presentation.recovering = true; session = nil; return
        }
        guard reply["status"] as? String == "confirmed", let session = reply["session_id"] as? String,
              let result = reply["result"] as? [String: Any], let state = result["state"] as? [String: Any],
              let dirty = state["dirty"] as? Bool else { throw BridgeFailure.protocolError }
        self.session = session; snapshot = state; revision = reply["revision"] as? Int ?? 0
        presentation.preset = state["name"] as? String
        presentation.scene = state["scene"] as? String
        presentation.dirty = dirty
        presentation.recovering = false
    }
    func stop() { revoke(); helper?.stop(); bridge = nil; helper = nil }
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
    private let backend: OfflineBridgeBackend
    private let queue = DispatchQueue(label: "patchbridge.offline-shell")
    private var generation = UUID()
    init(backend: OfflineBridgeBackend = BundledOfflineBackend()) { self.backend = backend }
    var title: String {
        switch phase {
        case .stopped: return "Bridge stopped"
        case .starting: return "Starting bridge…"
        case .running: return "Ready for a simulated phone"
        case .awaitingApproval: return "Approval requested"
        case .approving: return "Verifying connection…"
        case .connected: return "Simulated iPhone connected"
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
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == epoch else { return }
                self.busy = false
                self.presentation = presentation
                self.phase = failed ? .failed : presentation.recovering ? .recovering : success
                self.detail = failed ? failureMessage : message
                self.recoveryTimer?.invalidate(); self.recoveryTimer = nil
                if self.phase == .recovering {
                    self.detail = "Simulated USB interruption. The phone stays approved. Reloading state before editing resumes."
                    self.recoveryTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in self?.refresh() }
                }
                self.onChange?()
            }
        }
    }
    func start() {
        guard phase == .stopped || phase == .failed else { return }
        generation = UUID(); phase = .starting; detail = "Launching the bundled simulation helper."
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
    func approve() {
        guard phase == .awaitingApproval && !busy else { return }
        phase = .approving; detail = "Approving this connection and requesting a snapshot."
        perform({ try $0.approve() }, success: .connected, message: "Approval granted. A snapshot was confirmed by the bundled helper.")
    }
    func disconnectPhone() {
        guard (phase == .awaitingApproval || phase == .connected || phase == .recovering) && !busy else { return }
        let denied = phase == .awaitingApproval
        perform({ $0.revoke() }, success: .running,
                message: denied ? "Request denied. Simulate another phone when you’re ready." : "Phone disconnected. A new connection will need approval.")
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
    func clearRecentEdits() {
        guard !busy else { return }
        perform({ $0.clearRecentEdits() }, success: phase, message: detail)
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
