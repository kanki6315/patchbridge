#if os(macOS)
import Foundation

/// Owns USB and session state on the host's worker queue. The Bluetooth peripheral runs on
/// its own queue and delivers each device's messages here, so USB requests never block it.
/// Reads and writes originate only from explicitly approved devices; no edit is replayed.
final class LiveBridgeBackend: OfflineBridgeBackend {
    /// Devices admitted at once. The Mac shell presents one device until its multi-device UI lands.
    static let deviceLimit = 1
    let isLive = true
    var onChange: (() -> Void)?
    private(set) var state: (MacBridgeModel.Phase, String)?
    private(set) var presentation = MacBridgePresentation()
    private let makeHelper: () throws -> HelperClient
    private let peripheral: BridgePeripheral
    private var helper: HelperClient?
    private var shared: SharedUSBSession?
    private var devices = [UUID: DeviceSession]()
    /// The device the shell presents and approves.
    private var current: UUID?
    /// Devices disconnected from the Mac. CoreBluetooth can't drop one central, so their
    /// requests are refused until they say hello again or leave.
    private var revoked = Set<UUID>()
    private var approved = false
    private var snapshot: [String: Any]?
    private var catalog: [String: Any]?
    private let now: () -> TimeInterval
    private var bridge: DeviceSession? { current.flatMap { devices[$0] } }
    init(peripheral: BridgePeripheral, makeHelper: @escaping () throws -> HelperClient = { try HelperClient(bundle: .main, liveUSB: true) },
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.peripheral = peripheral; self.makeHelper = makeHelper; self.now = now
    }
    func start() throws {
        stop()
        let helper = try makeHelper(); self.helper = helper
        let shared = SharedUSBSession(helper: helper, requestTimeout: 40, allowsRecovery: true, deviceLimit: Self.deviceLimit, now: now)
        self.shared = shared
        shared.onMutation = { [weak self] _, request, response in
            guard let self else { return }
            self.presentation.recentEdits.insert(RecentBridgeEdit(request: request, response: response, snapshot: self.snapshot, catalog: self.catalog), at: 0)
            self.presentation.recentEdits = Array(self.presentation.recentEdits.prefix(12))
        }
        peripheral.onMessage = { [weak self] id, message in
            self?.receive(id, message) ?? PeripheralReply(message: CentralRouter.errorReply(message, code: "disconnected", text: "The bridge stopped."))
        }
        peripheral.onDisconnect = { [weak self] id in self?.deviceLeft(id) }
        peripheral.onStatus = { [weak self] message in
            guard let self, self.shared != nil, self.state?.0 == .running else { return }
            self.update(.running, message)
        }
        update(.running, "Starting Bluetooth. USB opens after you approve a phone and it requests a connection.")
        peripheral.start(name: shared.macName)
    }
    private func update(_ phase: MacBridgeModel.Phase, _ detail: String) {
        presentation.trustedPhone = shared?.trust.names.last; state = (phase, detail); onChange?()
    }
    func requestPhone() throws { throw BridgeFailure.protocolError }
    func approve() throws { try approve(trust: false) }
    func approve(trust: Bool) throws {
        guard let bridge, state?.0 == .awaitingApproval else { throw BridgeFailure.disconnected }
        // The shell shows one trusted phone until its multi-device UI lands; trusting
        // another replaces it, as before.
        if trust { shared?.trust.removeAll() }
        approved = true; bridge.approve(trusting: trust)
        update(.approving, "Approved. Tap ‘I’ve approved it’ on your iPhone to read the QC.")
    }
    private func resetPresentation() {
        let edits = presentation.recentEdits
        presentation = MacBridgePresentation(); presentation.recentEdits = edits
        snapshot = nil; catalog = nil; approved = false
    }
    private func deviceLeft(_ id: UUID) {
        revoked.remove(id)
        guard let shared, let device = devices.removeValue(forKey: id) else { return }
        shared.remove(device)
        guard id == current else { return }
        current = nil; resetPresentation()
        if let trusted = shared.trust.names.last {
            update(.running, "\(trusted) disconnected. It can reconnect without a code until Patchbridge quits.")
        } else {
            update(.running, "Phone disconnected. Open Patchbridge on your iPhone to connect with fresh approval.")
        }
    }
    func revokeTrust() {
        bridge?.revokeTrust(); shared?.trust.removeAll()
        if let state { update(state.0, state.1) }
    }
    /// Ends the presented device's session; its next request learns it was disconnected.
    func revoke() {
        guard let id = current else { return }
        deviceLeft(id); revoked.insert(id)
    }
    func refresh() throws {} // The phone polls; the Mac must not create a competing USB session.
    func clearRecentEdits() { presentation.recentEdits.removeAll(); onChange?() }
    func stop() {
        peripheral.onMessage = nil; peripheral.onDisconnect = nil; peripheral.onStatus = nil; peripheral.stop()
        if let shared { shared.devices.forEach(shared.remove) }
        devices.removeAll(); revoked.removeAll(); current = nil
        shared = nil; helper?.stop(); helper = nil; resetPresentation()
        state = (.stopped, "Bridge stopped. Phone approval has been cleared.")
    }
    func interruptHelper() { helper?.stop() }
    private func receive(_ id: UUID, _ request: [String: Any]) -> PeripheralReply {
        guard let shared else { return PeripheralReply(message: failure(request, code: "disconnected")) }
        var admission = PeripheralReply.Admission.unchanged
        if request["operation"] as? String == "hello" {
            revoked.remove(id) // A fresh hello starts over.
            if devices[id] == nil {
                guard let device = shared.admit() else { return PeripheralReply(message: shared.bridgeFullReply(request), admission: .release) }
                devices[id] = device; admission = .admit
                if current == nil { current = id }
            }
        } else if revoked.contains(id) {
            return PeripheralReply(message: CentralRouter.errorReply(request, code: "revoked", text: "This device was disconnected on the Mac."))
        }
        guard let device = devices[id] else { return PeripheralReply(message: failure(request, code: "unauthorized")) }
        return PeripheralReply(message: receive(request, from: device, presented: id == current), admission: admission)
    }
    private func receive(_ request: [String: Any], from bridge: DeviceSession, presented: Bool) -> [String: Any] {
        do {
            let reply = try bridge.handle(request)
            guard presented else { return reply }
            let operation = request["operation"] as? String
            if operation == "hello" && !approved && bridge.isTrustedConnection {
                approved = true; presentation.phoneName = bridge.phoneName
                update(.approving, "\(presentation.phoneName) is trusted until Patchbridge quits. Reconnecting without a code.")
            } else if operation == "hello" && !approved {
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
                let response = failure(request, code: code, token: bridge.token)
                // The helper's transport failed: approval cannot survive this failure.
                stop(); update(.failed, "The USB helper stopped responding. Restart the bridge and approve the phone again. An uncertain edit is never replayed.")
                return response
            }
            return failure(request, code: code, token: bridge.token)
        }
    }
    private func failure(_ request: [String: Any], code: String, token: String = "") -> [String: Any] {
        ["version": 1, "id": request["id"] as? String ?? "", "connection_id": token,
         "status": "error", "error": ["code": code, "message": code == "unauthorized" ? "Approve this phone on the Mac first." : "Reconnect to reload the device state."]]
    }
}
#endif
