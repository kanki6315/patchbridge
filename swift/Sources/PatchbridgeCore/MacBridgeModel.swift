#if os(macOS)
import Foundation
import Combine

protocol OfflineBridgeBackend: AnyObject {
    func start() throws
    func requestPhone() throws
    func approve() throws
    func revoke()
    func refresh() throws
    func stop()
    func interruptHelper()
}

/// Only constructs a bundled simulator. No radio or USB transport is available here.
final class BundledOfflineBackend: OfflineBridgeBackend {
    private let makeHelper: () throws -> HelperClient
    private var helper: HelperClient?
    private var bridge: BridgeSession?
    private var session: String?
    init(makeHelper: @escaping () throws -> HelperClient = { try HelperClient(bundle: .main) }) {
        self.makeHelper = makeHelper
    }
    func start() throws { stop(); let helper = try makeHelper(); self.helper = helper; bridge = BridgeSession(helper: helper) }
    private func send(_ operation: String) throws -> [String: Any] {
        guard let bridge else { throw BridgeFailure.disconnected }
        var message: [String: Any] = ["version": 1, "id": UUID().uuidString, "operation": operation, "connection_id": bridge.token]
        if let session { message["session_id"] = session }
        return try bridge.handle(message)
    }
    func requestPhone() throws {
        let reply = try send("hello")
        guard reply["authorization_required"] as? Bool == true else { throw BridgeFailure.protocolError }
    }
    func approve() throws {
        guard let bridge else { throw BridgeFailure.disconnected }
        bridge.approve()
        let reply = try send("connect")
        guard reply["status"] as? String == "confirmed", let session = reply["session_id"] as? String else { throw BridgeFailure.protocolError }
        self.session = session
        try refresh()
    }
    func revoke() { bridge?.revoke(); session = nil }
    func refresh() throws {
        let reply = try send("snapshot")
        guard reply["status"] as? String == "confirmed",
              let result = reply["result"] as? [String: Any], result["state"] is [String: Any] else { throw BridgeFailure.protocolError }
    }
    func stop() { revoke(); helper?.stop(); bridge = nil; helper = nil }
    func interruptHelper() { helper?.stop() }
}

/// Main-queue UI owner; helper/session work is serialized off the UI thread.
final class MacBridgeModel: ObservableObject {
    enum Phase: Equatable { case stopped, starting, running, awaitingApproval, approving, connected, stopping, failed }
    @Published private(set) var phase: Phase = .stopped
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
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == epoch else { return }
                self.busy = false
                self.phase = failed ? .failed : success
                self.detail = failed ? failureMessage : message
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
        guard (phase == .awaitingApproval || phase == .connected) && !busy else { return }
        let denied = phase == .awaitingApproval
        perform({ $0.revoke() }, success: .running,
                message: denied ? "Request denied. Simulate another phone when you’re ready." : "Phone disconnected. A new connection will need approval.")
    }
    func refresh() {
        guard phase == .connected && !busy else { return }
        perform({ try $0.refresh() }, success: .connected, message: "Connection checked. The helper returned a confirmed snapshot.")
    }
    func simulateFailure() {
        guard phase == .connected && !busy else { return }
        perform({ $0.interruptHelper(); try $0.refresh() }, success: .connected, message: "Connection checked.")
    }
    func shutdown() { generation = UUID(); queue.sync { backend.stop() } }
}
#endif
