#if os(macOS)
import Foundation

/// "Trusted until Patchbridge quits" entries. Owned by the bridge, so trust outlives a
/// device's connection but never the bridge: Stop, Quit or helper failure clears it.
public final class TrustRegistry {
    public static let limit = 8
    /// `id` names an entry in the UI; the token never leaves the bridge and its devices.
    private var entries: [(id: UUID, token: String, name: String)] = []
    public var names: [String] { entries.map(\.name) }
    public var list: [(id: UUID, name: String)] { entries.map { ($0.id, $0.name) } }
    func add(name: String) -> String {
        let token = UUID().uuidString + UUID().uuidString
        entries.append((UUID(), token, name))
        if entries.count > Self.limit { entries.removeFirst() }
        return token
    }
    func name(for token: String) -> String? { entries.first { $0.token == token }?.name }
    func id(for token: String) -> UUID? { entries.first { $0.token == token }?.id }
    func rename(_ token: String, to name: String) {
        if let index = entries.firstIndex(where: { $0.token == token }) { entries[index].name = name }
    }
    func remove(_ token: String) { entries.removeAll { $0.token == token } }
    func remove(id: UUID) { entries.removeAll { $0.id == id } }
    func removeAll() { entries.removeAll() }
}

/// The bridge's one helper session, shared by every admitted device. A device joins by
/// adopting the current `generation`; each new helper session increments it, so a device
/// that missed a reconnect is detected before its stale session reaches the helper.
/// Dispatch serially on the transport queue, like the devices that use it.
public final class SharedUSBSession {
    public let deviceLimit: Int
    public let macName: String
    public let trust = TrustRegistry()
    /// Called only for forwarded or refused mutations, with the sending device's name.
    var onMutation: ((String, [String: Any], [String: Any]?) -> Void)?
    public private(set) var generation = 0
    public private(set) var recovering = false
    /// Admitted devices still alive. A device released without `remove` frees its slot.
    public var devices: [DeviceSession] { admitted.compactMap(\.device) }
    let helper: HelperClient
    let requestTimeout: TimeInterval
    private let allowsRecovery: Bool
    private let now: () -> TimeInterval
    private(set) var helperSession: String?
    private var revision: Any = 0
    /// The latest confirmed mutation: the revision it produced and who sent it. Lets a
    /// device learn that a change it didn't make came from another device, not the QC.
    var lastWrite: (revision: Int, device: ObjectIdentifier, name: String)?
    private var joined = Set<ObjectIdentifier>()
    private struct Admitted { weak var device: DeviceSession? }
    private var admitted: [Admitted] = []
    private var retryAt: TimeInterval = 0
    private var retryDelay: TimeInterval = 1
    public init(helper: HelperClient, requestTimeout: TimeInterval = 5, allowsRecovery: Bool = false,
                deviceLimit: Int = 4, macName: String = DeviceIdentity.macName,
                now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.helper = helper; self.requestTimeout = requestTimeout
        self.allowsRecovery = allowsRecovery; self.now = now; self.deviceLimit = deviceLimit
        self.macName = DeviceIdentity.name(macName, fallback: "Mac")
    }

    /// A new device session, or nil when `deviceLimit` devices are already admitted.
    public func admit() -> DeviceSession? {
        guard devices.count < deviceLimit else { return nil }
        let device = DeviceSession(shared: self); register(device)
        return device
    }
    func register(_ device: DeviceSession) { admitted.append(Admitted(device: device)) }
    /// Ends trust for one entry. A connected device keeps this connection; its next one needs a code.
    public func revokeTrust(id: UUID) {
        devices.filter { $0.trustEntryID == id }.forEach { $0.revokeTrust() }
        trust.remove(id: id)
    }
    /// Ends the device's connection and frees its slot. Its trust entry, if any, remains.
    public func remove(_ device: DeviceSession) {
        device.revoke(); admitted.removeAll { $0.device == nil || $0.device === device }
    }
    public func bridgeFullReply(_ message: [String: Any]) -> [String: Any] {
        let devices = deviceLimit == 1 ? "another device" : "\(deviceLimit) devices"
        return ["version": 1, "id": message["id"] as? String ?? "", "status": "error",
                "error": ["code": "bridge_full", "message": "This Mac is already connected to \(devices)."]]
    }

    func isJoined(_ device: DeviceSession) -> Bool { joined.contains(ObjectIdentifier(device)) }
    func isOutdated(_ device: DeviceSession) -> Bool { device.adoptedGeneration.map { $0 < generation } ?? false }
    var retryAfter: TimeInterval { max(0.5, retryAt - now()) }
    var canRecoverNow: Bool { now() >= retryAt }

    /// Sends one request to the helper. A transport failure ends every device; an adapter
    /// failure starts shared recovery. Returns the raw response and whether recovery began.
    func forward(_ message: [String: Any]) throws -> (response: [String: Any], recovering: Bool) {
        let response: [String: Any]
        do { response = try helper.request(message, timeout: requestTimeout) }
        catch { failAll(); throw error }
        let code = (response["error"] as? [String: Any])?["code"] as? String
        if allowsRecovery && ["adapter_failure", "disconnected"].contains(code ?? ""), response["session_id"] as? String == nil {
            recovering = true; helperSession = nil
            retryAt = now() + retryDelay; retryDelay = min(retryDelay * 2, 8)
            return (response, true)
        }
        adopt(response)
        return (response, false)
    }
    private func adopt(_ response: [String: Any]) {
        let session = response["session_id"] as? String
        if session != helperSession { helperSession = session; lastWrite = nil; if session != nil { generation += 1 } }
        if let value = response["revision"], !(value is NSNull) { revision = value }
    }

    /// Joins the device to the current helper session, opening one if none exists. Later
    /// joiners never send `connect` (the helper allows one session); they get a
    /// connect-shaped reply built from a snapshot and the stored device identity.
    func join(_ device: DeviceSession, _ message: [String: Any]) throws -> (response: [String: Any], recovering: Bool) {
        var result: (response: [String: Any], recovering: Bool)
        if let session = helperSession {
            result = try forward(["operation": "snapshot", "session_id": session])
            guard !result.recovering, result.response["status"] as? String == "confirmed" else { return result }
            let identity = try forward(["operation": "identify", "session_id": session])
            guard !identity.recovering, identity.response["status"] as? String == "confirmed" else { return identity }
            let state = (result.response["result"] as? [String: Any])?["state"] ?? NSNull()
            result.response["result"] = ["device": identity.response["result"] ?? NSNull(), "state": state]
        } else {
            var forwarded = message
            forwarded["operation"] = "connect"; forwarded.removeValue(forKey: "session_id")
            result = try forward(forwarded)
            guard !result.recovering, result.response["status"] as? String == "confirmed" else { return result }
        }
        if recovering { recovering = false; retryDelay = 1 }
        joined.insert(ObjectIdentifier(device)); device.adoptedGeneration = generation
        return result
    }
    /// The last device to leave closes the helper session; earlier ones leave it open.
    /// A device's own `disconnect` is forwarded only when it is the last one.
    func leave(_ device: DeviceSession, forwarding message: [String: Any]? = nil) throws -> [String: Any] {
        joined.remove(ObjectIdentifier(device)); device.adoptedGeneration = nil
        var response: [String: Any] = ["version": 1, "status": "confirmed", "result": [String: Any](),
                                       "session_id": helperSession ?? NSNull(), "revision": revision]
        guard joined.isEmpty else { return response }
        if var message {
            if let helperSession { message["session_id"] = helperSession }
            response = try forward(message).response
        }
        else if let session = helperSession { _ = try? helper.request(["operation": "disconnect", "session_id": session]); helperSession = nil }
        if helperSession == nil { recovering = false; retryDelay = 1; retryAt = 0 }
        return response
    }
    /// Used by the offline shell to exercise a cable interruption, without touching USB.
    func simulateDeviceRemoval() throws {
        guard allowsRecovery, let session = helperSession else { throw BridgeFailure.disconnected }
        _ = try helper.request(["operation": "disconnect", "session_id": session])
        helperSession = nil; recovering = true; retryAt = now() + 2; retryDelay = 1
    }
    /// Called from a device's deinit, so a released device never holds the helper session open.
    func forget(_ id: ObjectIdentifier) {
        admitted.removeAll { $0.device == nil }
        guard joined.remove(id) != nil, joined.isEmpty, let session = helperSession else { return }
        _ = try? helper.request(["operation": "disconnect", "session_id": session])
        helperSession = nil; recovering = false; retryDelay = 1; retryAt = 0
    }
    /// The helper's transport failed: no approval or trust survives.
    private func failAll() {
        let all = devices; joined.removeAll(); helperSession = nil
        if !all.isEmpty { helper.diagnostics.record(.bridgeRevoked) }
        recovering = false; retryDelay = 1; retryAt = 0
        for device in all { device.endConnection() }
        trust.removeAll()
    }
}
#endif
