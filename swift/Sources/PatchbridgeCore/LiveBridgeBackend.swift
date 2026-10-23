#if os(macOS)
import Foundation

/// Owns USB and session state on the host's worker queue. The Bluetooth peripheral runs on
/// its own queue and delivers each device's messages here, so USB requests never block it.
/// The bridge opens USB and reads the QC itself from Start to Stop, whether or not any device
/// is connected, and answers every device's reads from that one reading. Writes originate
/// only from explicitly approved devices; no edit is replayed.
final class LiveBridgeBackend: OfflineBridgeBackend {
    static let deviceLimit = 4
    let isLive = true
    var onChange: (() -> Void)?
    private(set) var state: (MacBridgeModel.Phase, String)?
    private(set) var presentation = MacBridgePresentation()
    private let makeHelper: () throws -> HelperClient
    private let peripheral: BridgePeripheral
    private var helper: HelperClient?
    private var shared: SharedUSBSession?
    private var devices = [UUID: DeviceSession]()
    private var states = [UUID: BridgeDevice.State]()
    /// Admission order: the approval card shows the earliest waiting device.
    private var order = [UUID]()
    /// Devices disconnected from the Mac. CoreBluetooth can't drop one central, so their
    /// requests are refused until they say hello again or leave.
    /// Value: the device's diagnostics number.
    private var revoked = [UUID: Int]()
    private var status = LiveBridgeBackend.startingStatus
    private static let startingStatus = "Starting Bluetooth and reading the QC over USB. Close Cortex Control while the bridge runs."
    private let now: () -> TimeInterval
    /// The worker queue the bridge's own QC reads run on; nil leaves them to `tick()`'s caller.
    private let queue: DispatchQueue?
    private var poller: DispatchSourceTimer?
    /// The last poll couldn't reach the QC; its status stays until a read succeeds.
    private var qcMissing = false
    /// Outlives each start's shared session, so Stop keeps trusted devices.
    private let trust: TrustRegistry
    /// Held while any device is approved, so the Mac neither naps nor sleeps under it.
    let keepAwake: KeepAwake
    init(peripheral: BridgePeripheral, makeHelper: @escaping () throws -> HelperClient = { try HelperClient(bundle: .main, liveUSB: true) },
         trust: TrustRegistry = TrustRegistry(), keepAwake: KeepAwake = KeepAwake(), queue: DispatchQueue? = nil,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.peripheral = peripheral; self.makeHelper = makeHelper; self.trust = trust; self.keepAwake = keepAwake
        self.queue = queue; self.now = now
    }
    func start() throws {
        stop()
        let helper = try makeHelper(); self.helper = helper
        let shared = SharedUSBSession(helper: helper, requestTimeout: 40, allowsRecovery: true, deviceLimit: Self.deviceLimit, trust: trust, keepsSession: true, now: now)
        self.shared = shared
        peripheral.onMessage = { [weak self] id, message in
            self?.receive(id, message) ?? PeripheralReply(message: CentralRouter.errorReply(message, code: "disconnected", text: "The bridge stopped."))
        }
        peripheral.onDisconnect = { [weak self] id in self?.deviceLeft(id) }
        peripheral.onStatus = { [weak self] message in
            guard let self, self.shared != nil else { return }
            self.status = message; self.publish()
        }
        status = Self.startingStatus; qcMissing = false
        publish()
        peripheral.start(name: shared.macName)
        if let queue {
            // The first read runs after Start returns, so the window shows the bridge running at once.
            let poller = DispatchSource.makeTimerSource(queue: queue)
            poller.schedule(deadline: .now(), repeating: 0.25)
            poller.setEventHandler { [weak self] in self?.tick() }
            poller.resume(); self.poller = poller
        }
    }

    /// The bridge's own read of the QC: opens USB when it isn't open, otherwise refreshes the
    /// state every device is answered from. Called every quarter second; reads only when due.
    func tick() {
        guard let shared else { return }
        let reply: [String: Any]?
        do { reply = try shared.poll() } catch { helperFailed(); return }
        guard let reply else { return }
        if reply["status"] as? String == "confirmed" {
            if let state = (reply["result"] as? [String: Any])?["state"] as? [String: Any] { show(state) }
            if qcMissing { qcMissing = false; status = "QC connected. Open Patchbridge on your iPhone and choose this Mac." }
        } else {
            let code = (reply["error"] as? [String: Any])?["code"] as? String
            guard code != "device_busy" else { return } // Mid scene or preset change; the next read settles it.
            qcMissing = true
            status = code == "unsupported_firmware" ? "This USB adapter requires verified CorOS 4.1.1. Use a QC on a supported firmware."
                : "QC not reachable over USB. Check the cable and close Cortex Control; the bridge keeps trying."
        }
        notifyRevisions()
        publish()
    }
    private func show(_ state: [String: Any]) {
        guard let dirty = state["dirty"] as? Bool else { return }
        presentation.preset = state["name"] as? String; presentation.scene = state["scene"] as? String; presentation.dirty = dirty
    }
    private func helperFailed() {
        // The helper's transport failed: approval cannot survive this failure.
        stop(); state = (.failed, "The USB helper stopped responding. Restart the bridge and approve your devices again. An uncertain edit is never replayed.")
        onChange?()
    }

    private func ids(_ state: BridgeDevice.State) -> [UUID] { order.filter { states[$0] == state } }
    /// Derives the bridge's phase from every device: a waiting approval comes first, then
    /// USB recovery, then any connected device. An event's own wording is kept when its
    /// phase is still the bridge's phase; otherwise the phase's usual wording is shown.
    private func publish(_ event: MacBridgeModel.Phase? = nil, _ detail: String? = nil) {
        guard let shared else { return }
        presentation.devices = order.compactMap { id in
            devices[id].map { BridgeDevice(id: id, connection: $0.token, name: $0.phoneName, state: states[id] ?? .awaitingApproval, trustID: $0.trustEntryID) }
        }
        let active = order.filter { states[$0] != .awaitingApproval }
        keepAwake.hold(!active.isEmpty)
        presentation.trusted = shared.trust.list.map { entry in
            TrustedDevice(id: entry.id, name: entry.name, connected: active.contains { devices[$0]?.trustEntryID == entry.id })
        }
        presentation.recovering = shared.recovering && !active.isEmpty
        let waiting = ids(.awaitingApproval)
        presentation.waiting = max(0, waiting.count - 1)
        presentation.pendingID = waiting.first; presentation.pendingConnection = waiting.first.flatMap { devices[$0]?.token }
        let phase: MacBridgeModel.Phase, text: String
        if let id = waiting.first, let device = devices[id] {
            presentation.phoneName = device.phoneName; presentation.approvalCode = device.approvalCode
            phase = .awaitingApproval
            text = "Compare the code on \(device.phoneName). Allow this device to read and edit supported QC parameters?"
                + (presentation.waiting > 0 ? " \(presentation.waiting) more waiting." : "")
        } else if let id = active.first, let device = devices[id] {
            presentation.phoneName = device.phoneName; presentation.approvalCode = device.approvalCode
            if shared.recovering {
                phase = .recovering
                text = "QC unavailable. Check the USB cable and close Cortex Control. Devices stay approved; editing resumes after fresh state is loaded."
            } else if let connected = ids(.connected).first.flatMap({ devices[$0] }) {
                phase = .connected; presentation.phoneName = connected.phoneName
                text = "Connected over Bluetooth and USB. Supported edits are confirmed by QC readback."
            } else {
                phase = .approving
                text = "Approved. Tap ‘I’ve approved it’ on \(device.phoneName) to read the QC."
            }
        } else {
            presentation.phoneName = "iPhone"; presentation.approvalCode = ""
            phase = .running; text = status
        }
        state = (phase, event == phase ? detail ?? text : text); onChange?()
    }

    func requestPhone() throws { throw BridgeFailure.protocolError }
    /// The device on that exact connection, optionally only in one state. Device identifiers
    /// outlive connections (a device can leave and say hello again), so the token is checked too.
    private func device(_ id: UUID, _ connection: String, in state: BridgeDevice.State? = nil) -> DeviceSession? {
        guard let device = devices[id], device.token == connection, state.map({ states[id] == $0 }) ?? true else { return nil }
        return device
    }
    func approve(device id: UUID, connection: String, trust: Bool) throws {
        // The card changed before this ran (its device left or reconnected): approve nothing.
        guard let device = device(id, connection, in: .awaitingApproval) else { publish(); return }
        device.approve(trusting: trust); states[id] = .approving
        publish(.approving, "Approved. Tap ‘I’ve approved it’ on \(device.phoneName) to read the QC.")
    }
    private func resetQCState() {
        presentation = MacBridgePresentation()
    }
    private func deviceLeft(_ id: UUID) {
        notificationDevices.remove(id); announced[id] = nil
        revoked[id] = nil
        guard let shared, let device = devices.removeValue(forKey: id) else { return }
        let name = device.phoneName, trusted = device.trustEntryID != nil
        states[id] = nil; order.removeAll { $0 == id }
        shared.remove(device)
        publish(.running, trusted ? "\(name) disconnected. It can reconnect without a code until you revoke trust."
                : "\(name) disconnected. Open Patchbridge on it to connect with fresh approval.")
    }
    func deny(device id: UUID, connection: String) {
        guard device(id, connection, in: .awaitingApproval) != nil else { publish(); return }
        end(id)
    }
    func disconnect(device id: UUID, connection: String) {
        guard device(id, connection) != nil else { publish(); return }
        end(id)
    }
    /// Ends one device's session; its next request learns it was disconnected.
    private func end(_ id: UUID) {
        notificationDevices.remove(id); announced[id] = nil
        guard let index = devices[id]?.index else { return }
        deviceLeft(id); revoked[id] = index
    }
    func revokeTrust(id: UUID) { shared?.revokeTrust(id: id); publish() }
    func refresh() throws {} // The bridge reads the QC on its own schedule (`tick`).
    func stop() {
        notificationDevices.removeAll(); announced.removeAll()
        poller?.cancel(); poller = nil
        peripheral.onMessage = nil; peripheral.onDisconnect = nil; peripheral.onStatus = nil; peripheral.stop()
        if let shared { shared.devices.forEach(shared.remove) }
        devices.removeAll(); states.removeAll(); order.removeAll(); revoked.removeAll()
        shared = nil; helper?.stop(); helper = nil; resetQCState(); keepAwake.stop()
        state = (.stopped, "Bridge stopped. Connections ended; trusted devices reconnect without a code.")
    }
    func interruptHelper() { helper?.stop() }

    private var notificationDevices = Set<UUID>()
    private var announced = [UUID: String]()
    private func notifyRevisions(except origin: UUID? = nil) {
        guard let shared, let session = shared.helperSession, let cached = shared.cached else { return }
        let key = "\(session):\(cached.revision)"
        for (id, device) in devices where notificationDevices.contains(id) && shared.isJoined(device) && !shared.isOutdated(device) {
            guard announced[id] != key else { continue }
            announced[id] = key
            guard id != origin else { continue }
            peripheral.notify(id, message: ["version": 1, "type": "event", "event": "revision_changed",
                "connection_id": device.token, "session_id": session, "revision": cached.revision])
        }
    }
    private func receive(_ id: UUID, _ request: [String: Any]) -> PeripheralReply {
        guard let shared else { return PeripheralReply(message: failure(request, code: "disconnected")) }
        var admission = PeripheralReply.Admission.unchanged
        if request["operation"] as? String == "hello" {
            revoked[id] = nil // A fresh hello starts over.
            if devices[id] == nil {
                guard let device = shared.admit() else {
                    shared.helper.diagnostics.record(.requestRejected, operation: "hello", code: "bridge_full")
                    return PeripheralReply(message: shared.bridgeFullReply(request), admission: .release)
                }
                devices[id] = device; order.append(id); admission = .admit
            }
        } else if let index = revoked[id] {
            shared.helper.diagnostics.record(.requestRejected, operation: request["operation"] as? String, code: "revoked", device: index)
            return PeripheralReply(message: CentralRouter.errorReply(request, code: "revoked", text: "This device was disconnected on the Mac."))
        }
        guard let device = devices[id] else { return PeripheralReply(message: failure(request, code: "unauthorized")) }
        var reply = receive(request, from: device, id: id)
        if request["operation"] as? String == "hello" {
            if request["revision_notifications"] as? Bool == true { notificationDevices.insert(id) }
            else { notificationDevices.remove(id) }
            announced[id] = nil
            reply["revision_notifications"] = true
        }
        let result = reply["result"] as? [String: Any]
        let carriesState = reply["status"] as? String == "confirmed" && (result?["state"] != nil || result?["unchanged"] as? Bool == true)
        notifyRevisions(except: carriesState ? id : nil)
        return PeripheralReply(message: reply, admission: admission)
    }
    private func receive(_ request: [String: Any], from device: DeviceSession, id: UUID) -> [String: Any] {
        do {
            let reply = try device.handle(request)
            let operation = request["operation"] as? String
            var event: (MacBridgeModel.Phase, String)?
            if operation == "hello" {
                if states[id] == nil || states[id] == .awaitingApproval {
                    states[id] = device.isTrustedConnection ? .approving : .awaitingApproval
                }
                if device.isTrustedConnection {
                    event = (.approving, "\(device.phoneName) is trusted. Reconnecting without a code.")
                }
            } else if reply["status"] as? String == "confirmed" {
                let result = reply["result"] as? [String: Any]
                if let state = result?["state"] as? [String: Any], state["dirty"] is Bool {
                    show(state); states[id] = .connected
                } else if result?["unchanged"] as? Bool == true { states[id] = .connected }
                if operation == "disconnect" { end(id); return reply }
            } else if (reply["error"] as? [String: Any])?["code"] as? String == "unsupported_firmware" {
                event = (.approving, "This USB adapter requires verified CorOS 4.1.1. Disconnect the device and use a supported QC firmware.")
            }
            publish(event?.0, event?.1)
            return reply
        } catch {
            let code: String
            switch error {
            case BridgeFailure.unauthorized: code = "unauthorized"
            case BridgeFailure.staleSession: code = "stale_session"
            case BridgeFailure.readOnly: code = "read_only"
            case BridgeFailure.protocolError: code = "invalid_request"
            default:
                let response = failure(request, code: "disconnected", token: device.token)
                helperFailed()
                return response
            }
            return failure(request, code: code, token: device.token)
        }
    }
    private func failure(_ request: [String: Any], code: String, token: String = "") -> [String: Any] {
        ["version": 1, "id": request["id"] as? String ?? "", "connection_id": token,
         "status": "error", "error": ["code": code, "message": code == "unauthorized" ? "Approve this device on the Mac first." : "Reconnect to reload the device state."]]
    }
}
#endif
