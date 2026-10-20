#if os(macOS)
import Foundation

/// Owns USB/session state on the same worker queue as the Bluetooth peripheral.
/// Reads and writes originate only from the explicitly approved phone; no edit is replayed.
final class LiveBridgeBackend: OfflineBridgeBackend {
    let isLive = true
    var onChange: (() -> Void)?
    private(set) var state: (MacBridgeModel.Phase, String)?
    private(set) var presentation = MacBridgePresentation()
    private let makeHelper: () throws -> HelperClient
    private let peripheral: BridgePeripheral
    private var helper: HelperClient?
    private var bridge: BridgeSession?
    private var approved = false
    private var snapshot: [String: Any]?
    private var catalog: [String: Any]?
    private let now: () -> TimeInterval
    init(peripheral: BridgePeripheral, makeHelper: @escaping () throws -> HelperClient = { try HelperClient(bundle: .main, liveUSB: true) },
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.peripheral = peripheral; self.makeHelper = makeHelper; self.now = now
    }
    func start() throws {
        stop()
        let helper = try makeHelper(); self.helper = helper
        let bridge = BridgeSession(helper: helper, requestTimeout: 40, allowsRecovery: true, now: now)
        self.bridge = bridge
        bridge.onMutation = { [weak self] request, response in
            guard let self else { return }
            self.presentation.recentEdits.insert(RecentBridgeEdit(request: request, response: response, snapshot: self.snapshot, catalog: self.catalog), at: 0)
            self.presentation.recentEdits = Array(self.presentation.recentEdits.prefix(12))
        }
        peripheral.onMessage = { [weak self] message in self?.receive(message) ?? [:] }
        peripheral.onDisconnect = { [weak self] in self?.phoneLeft() }
        peripheral.onStatus = { [weak self] message in
            guard let self, self.bridge != nil, self.state?.0 == .running else { return }
            self.update(.running, message)
        }
        update(.running, "Starting Bluetooth. USB opens after you approve a phone and it requests a connection.")
        peripheral.start(name: bridge.macName)
    }
    private func update(_ phase: MacBridgeModel.Phase, _ detail: String) { state = (phase, detail); onChange?() }
    func requestPhone() throws { throw BridgeFailure.protocolError }
    func approve() throws {
        guard let bridge, state?.0 == .awaitingApproval else { throw BridgeFailure.disconnected }
        approved = true; bridge.approve()
        update(.approving, "Approved. Tap ‘I’ve approved it’ on your iPhone to read the QC.")
    }
    private func resetPresentation() {
        let edits = presentation.recentEdits
        presentation = MacBridgePresentation(); presentation.recentEdits = edits
        snapshot = nil; catalog = nil; approved = false
    }
    private func phoneLeft() {
        guard bridge != nil else { return }
        bridge?.revoke(); resetPresentation()
        update(.running, "Phone disconnected. Open Patchbridge on your iPhone to connect with fresh approval.")
    }
    func revoke() { phoneLeft(); peripheral.resetConnection() }
    func refresh() throws {} // The phone polls; the Mac must not create a competing USB session.
    func clearRecentEdits() { presentation.recentEdits.removeAll(); onChange?() }
    func stop() {
        peripheral.onMessage = nil; peripheral.onDisconnect = nil; peripheral.onStatus = nil; peripheral.stop()
        bridge?.revoke(); bridge = nil; helper?.stop(); helper = nil; resetPresentation()
        state = (.stopped, "Bridge stopped. Phone approval has been cleared.")
    }
    func interruptHelper() { helper?.stop() }
    private func receive(_ request: [String: Any]) -> [String: Any] {
        guard let bridge else { return failure(request, code: "disconnected") }
        do {
            let reply = try bridge.handle(request)
            let operation = request["operation"] as? String
            if operation == "hello" && !approved {
                presentation.phoneName = bridge.phoneName; presentation.approvalCode = bridge.approvalCode
                update(.awaitingApproval, "Compare the code on \(presentation.phoneName). Allow this phone to read and edit supported QC parameters?")
            } else if bridge.recovering {
                presentation.recovering = true
                update(.recovering, "QC unavailable. Check the USB cable and close Cortex Control. The phone stays approved; editing resumes after fresh state is loaded.")
            } else if reply["status"] as? String == "confirmed" {
                let result = reply["result"] as? [String: Any]
                if operation == "catalog" { catalog = result }
                if let state = result?["state"] as? [String: Any], let dirty = state["dirty"] as? Bool {
                    snapshot = state
                    presentation.preset = state["name"] as? String; presentation.scene = state["scene"] as? String
                    presentation.dirty = dirty; presentation.recovering = false
                    if operation == "recover" { catalog = nil }
                    update(.connected, "Connected over Bluetooth and USB. Supported edits are confirmed by QC readback.")
                }
                if operation == "disconnect" { revoke() }
            } else if (reply["error"] as? [String: Any])?["code"] as? String == "unsupported_firmware" {
                update(.approving, "This USB adapter requires verified CorOS 4.1.1. Disconnect the phone and use a supported QC firmware.")
            }
            onChange?()
            return reply
        } catch {
            let code: String
            switch error {
            case BridgeFailure.unauthorized: code = "unauthorized"
            case BridgeFailure.staleSession: code = "stale_session"
            case BridgeFailure.readOnly: code = "read_only"
            case BridgeFailure.protocolError: code = "invalid_request"
            default:
                code = "disconnected"
                let response = failure(request, code: code)
                // The helper's transport failed: approval cannot survive this failure.
                stop(); update(.failed, "The USB helper stopped responding. Restart the bridge and approve the phone again. An uncertain edit is never replayed.")
                return response
            }
            return failure(request, code: code)
        }
    }
    private func failure(_ request: [String: Any], code: String) -> [String: Any] {
        ["version": 1, "id": request["id"] as? String ?? "", "connection_id": bridge?.token ?? "",
         "status": "error", "error": ["code": code, "message": code == "unauthorized" ? "Approve this phone on the Mac first." : "Reconnect to reload the device state."]]
    }
}
#endif
