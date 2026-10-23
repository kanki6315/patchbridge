#if os(macOS)
import Foundation
import Security

/// Where a `TrustRegistry` keeps its entries between launches. `nil` data means none.
public protocol TrustStorage {
    func load() -> Data?
    func save(_ data: Data?)
}

/// Trusted devices, kept in the Mac's Keychain so trust survives Stop and Quit.
public struct KeychainTrustStorage: TrustStorage {
    private let query: [String: Any]
    public init(service: String = "com.arjunakankipati.patchbridge.bridge-trust") {
        query = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                 kSecAttrAccount as String: "devices"]
    }
    public func load() -> Data? {
        var item: CFTypeRef?
        var search = query; search[kSecReturnData as String] = true
        guard SecItemCopyMatching(search as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }
    public func save(_ data: Data?) {
        SecItemDelete(query as CFDictionary)
        guard let data else { return }
        var item = query; item[kSecValueData as String] = data
        SecItemAdd(item as CFDictionary, nil)
    }
}

/// Devices trusted to reconnect without a code. Owned by the bridge, so trust outlives a
/// device's connection; with `storage` it also outlives Stop, Quit and helper failure, and
/// only Revoke Trust (or eviction past `limit`) ends it.
public final class TrustRegistry {
    public static let limit = 8
    /// `id` names an entry in the UI; the token never leaves the bridge and its devices.
    /// `device` is the phone's own stable ID, so one phone keeps one entry however it's named.
    private struct Entry: Codable { var id: UUID; var token: String; var name: String; var device: String? }
    private var entries: [Entry] = [] { didSet { persist() } }
    private let storage: TrustStorage?
    public init(storage: TrustStorage? = nil) {
        self.storage = storage
        if let data = storage?.load(), let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = Array(saved.suffix(Self.limit))
        }
    }
    public var names: [String] { entries.map(\.name) }
    public var list: [(id: UUID, name: String)] { entries.map { ($0.id, $0.name) } }
    func add(name: String, device: String? = nil) -> String {
        let token = UUID().uuidString + UUID().uuidString
        if let device { entries.removeAll { $0.device == device } }
        entries.append(Entry(id: UUID(), token: token, name: name, device: device))
        if entries.count > Self.limit { entries.removeFirst() }
        return token
    }
    func name(for token: String) -> String? { entries.first { $0.token == token }?.name }
    func id(for token: String) -> UUID? { entries.first { $0.token == token }?.id }
    /// A trusted reconnect refreshes the entry's name and device, dropping older entries
    /// from the same device.
    func refresh(_ token: String, name: String, device: String?) {
        guard let index = entries.firstIndex(where: { $0.token == token }) else { return }
        if let device, entries.contains(where: { $0.device == device && $0.token != token }) {
            var entry = entries[index]; entry.name = name; entry.device = device
            entries = entries.filter { $0.device != device && $0.token != token } + [entry]
        } else if entries[index].name != name || (device != nil && entries[index].device != device) {
            entries[index].name = name; entries[index].device = device ?? entries[index].device
        }
    }
    func remove(_ token: String) { entries.removeAll { $0.token == token } }
    func remove(id: UUID) { entries.removeAll { $0.id == id } }
    func removeAll() { entries.removeAll() }
    private func persist() {
        guard let storage else { return }
        storage.save(entries.isEmpty ? nil : try? JSONEncoder().encode(entries))
    }
}

/// The bridge's one helper session, shared by every admitted device. A device joins by
/// adopting the current `generation`; each new helper session increments it, so a device
/// that missed a reconnect is detected before its stale session reaches the helper.
/// Dispatch serially on the transport queue, like the devices that use it.
public final class SharedUSBSession {
    public let deviceLimit: Int
    public let macName: String
    public let trust: TrustRegistry
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
    /// The QC has one tuner. Each device asks for a mode and the QC gets the strongest anyone
    /// wants (open, then live, then off), so one device closing its tuner never stops another's.
    private var tunerModes = [ObjectIdentifier: String]()
    private static let tunerRank = ["off": 0, "live": 1, "open": 2]
    var tunerMode: String { tunerModes.values.max { Self.tunerRank[$0, default: 0] < Self.tunerRank[$1, default: 0] } ?? "off" }
    private struct Admitted { weak var device: DeviceSession? }
    private var admitted: [Admitted] = []
    /// Diagnostics numbers devices in admission order for this run; never reused.
    private var admissions = 0
    private var retryAt: TimeInterval = 0
    private var retryDelay: TimeInterval = 1
    /// The bridge reads the QC itself (`poll`) and keeps its session open with no device
    /// connected. Otherwise the session lives only while devices are joined.
    let keepsSession: Bool
    /// Delay after the last completed read. Hardware snapshots take about 60 ms;
    /// leave room for edits while keeping physical QC changes visible promptly.
    static let pollInterval: TimeInterval = 0.5
    /// A device's snapshot is answered from `cached` while it is at most this old.
    static let freshFor: TimeInterval = 1
    /// The QC state as last read on the current helper session, by whichever request read it.
    /// When the bridge keeps the session (and so keeps it fresh with `poll`), devices' snapshots
    /// and joins are answered from it, so N devices cost one USB read, not N.
    private(set) var cached: (state: Any, revision: Int, at: TimeInterval)?
    /// The QC's identity from this session's `connect`.
    private var identity: Any?
    public init(helper: HelperClient, requestTimeout: TimeInterval = 5, allowsRecovery: Bool = false,
                deviceLimit: Int = 4, macName: String = DeviceIdentity.macName, trust: TrustRegistry = TrustRegistry(),
                keepsSession: Bool = false, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.helper = helper; self.trust = trust; self.requestTimeout = requestTimeout; self.keepsSession = keepsSession
        self.allowsRecovery = allowsRecovery; self.now = now; self.deviceLimit = deviceLimit
        self.macName = DeviceIdentity.name(macName, fallback: "Mac")
    }

    /// A new device session, or nil when `deviceLimit` devices are already admitted.
    public func admit() -> DeviceSession? {
        guard devices.count < deviceLimit else { return nil }
        let device = DeviceSession(shared: self); register(device)
        return device
    }
    func register(_ device: DeviceSession) {
        admissions += 1; device.index = admissions; admitted.append(Admitted(device: device))
    }
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
    func forward(_ message: [String: Any], for device: DeviceSession? = nil) throws -> (response: [String: Any], recovering: Bool) {
        let response: [String: Any]
        do { response = try helper.request(message, timeout: requestTimeout, device: device?.index) }
        catch { failAll(); throw error }
        let code = (response["error"] as? [String: Any])?["code"] as? String
        if allowsRecovery && ["adapter_failure", "disconnected"].contains(code ?? ""), response["session_id"] as? String == nil {
            recovering = true; helperSession = nil; cached = nil; identity = nil
            retryAt = now() + retryDelay; retryDelay = min(retryDelay * 2, 8)
            return (response, true)
        }
        adopt(response)
        remember(response, operation: message["operation"] as? String)
        return (response, false)
    }
    private func adopt(_ response: [String: Any]) {
        let session = response["session_id"] as? String
        if session != helperSession {
            helperSession = session; lastWrite = nil; tunerModes.removeAll() // A new helper session starts with the tuner off.
            cached = nil; identity = nil
            if session != nil { generation += 1 }
        }
        if let value = response["revision"], !(value is NSNull) { revision = value }
    }
    private static func number(_ value: Any?) -> Int? {
        (value as? NSNumber).flatMap { String(cString: $0.objCType) == "c" ? nil : $0.intValue }
    }
    /// Every confirmed state the helper sends is the newest reading of the QC; an edit whose
    /// outcome isn't confirmed leaves the QC unknown until it is read again.
    private func remember(_ response: [String: Any], operation: String?) {
        guard helperSession != nil, let revision = Self.number(response["revision"]) else { cached = nil; return }
        let result = response["result"] as? [String: Any]
        if response["status"] as? String == "confirmed", let state = result?["state"], !(state is NSNull) {
            cached = (state, revision, now())
            if operation == "connect" { identity = result?["device"] }
        } else if response["status"] as? String == "confirmed", result?["unchanged"] as? Bool == true, cached?.revision == revision {
            cached?.at = now()
        } else if CentralRouter.mutations.contains(operation ?? "") || response["status"] as? String != "confirmed" && operation == "snapshot" {
            cached = nil
        }
    }

    /// The bridge's own read of the QC, run every `pollInterval` whether or not any device is
    /// connected: opens the USB session when there is none (with the recovery backoff), and
    /// otherwise refreshes `cached`. Returns the helper's reply, or nil when nothing was due.
    @discardableResult
    func poll() throws -> [String: Any]? {
        guard let session = helperSession else {
            guard canRecoverNow else { return nil }
            let opened = try forward(["operation": "connect"])
            if !opened.recovering, opened.response["status"] as? String == "confirmed" { recovering = false; retryDelay = 1 }
            else if !opened.recovering { retryAt = now() + retryDelay; retryDelay = min(retryDelay * 2, 8) }
            return opened.response
        }
        guard now() - (cached?.at ?? -.infinity) >= Self.pollInterval else { return nil }
        return try forward(["operation": "snapshot", "session_id": session]).response
    }
    /// A snapshot for a device: from `cached` while fresh, otherwise read from the QC. A device
    /// that names the revision it already holds gets `unchanged` instead of the state again.
    func snapshot(_ device: DeviceSession, _ message: [String: Any]) throws -> (response: [String: Any], recovering: Bool) {
        guard keepsSession, let session = helperSession, message["session_id"] as? String == session,
              let cached, now() - cached.at <= Self.freshFor else { return try forward(message, for: device) }
        let known = Self.number((message["payload"] as? [String: Any])?["known_revision"])
        let result: [String: Any] = known == cached.revision ? ["unchanged": true] : ["state": cached.state]
        let response: [String: Any] = ["version": 1, "type": "response", "status": "confirmed", "session_id": session,
                                       "revision": cached.revision, "result": result]
        return (response, false)
    }

    /// Joins the device to the current helper session, opening one if none exists. Later
    /// joiners never send `connect` (the helper allows one session); they get a
    /// connect-shaped reply built from a snapshot and the stored device identity.
    func join(_ device: DeviceSession, _ message: [String: Any]) throws -> (response: [String: Any], recovering: Bool) {
        var result: (response: [String: Any], recovering: Bool)
        if let session = helperSession {
            // The bridge already holds the QC's state and identity: usually no USB at all.
            result = try snapshot(device, ["operation": "snapshot", "session_id": session])
            guard !result.recovering, result.response["status"] as? String == "confirmed" else { return result }
            if identity == nil || !keepsSession {
                let identified = try forward(["operation": "identify", "session_id": session], for: device)
                guard !identified.recovering, identified.response["status"] as? String == "confirmed" else { return identified }
                identity = identified.response["result"]
            }
            let state = (result.response["result"] as? [String: Any])?["state"] ?? NSNull()
            result.response["result"] = ["device": identity ?? NSNull(), "state": state]
        } else {
            var forwarded = message
            forwarded["operation"] = "connect"; forwarded.removeValue(forKey: "session_id")
            result = try forward(forwarded, for: device)
            guard !result.recovering, result.response["status"] as? String == "confirmed" else { return result }
        }
        if recovering { recovering = false; retryDelay = 1 }
        joined.insert(ObjectIdentifier(device)); device.adoptedGeneration = generation
        return result
    }
    /// Sends the QC the strongest mode any device wants, after recording this device's request.
    /// A refused request leaves the device's previous mode in place.
    func tuner(_ device: DeviceSession, _ message: [String: Any]) throws -> (response: [String: Any], recovering: Bool) {
        let id = ObjectIdentifier(device)
        guard var payload = message["payload"] as? [String: Any], let mode = payload["mode"] as? String,
              Self.tunerRank[mode] != nil else { return try forward(message, for: device) }
        let previous = tunerModes[id]
        tunerModes[id] = mode == "off" ? nil : mode
        payload["mode"] = tunerMode
        var forwarded = message; forwarded["payload"] = payload
        let result = try forward(forwarded, for: device)
        if result.response["status"] as? String != "confirmed" { tunerModes[id] = previous }
        return result
    }
    /// A departing device's tuner request ends; the others keep theirs.
    private func releaseTuner(_ id: ObjectIdentifier) {
        guard tunerModes.removeValue(forKey: id) != nil, !joined.isEmpty, let session = helperSession else { return }
        _ = try? helper.request(["operation": "tuner", "session_id": session, "payload": ["mode": tunerMode]])
    }

    /// The last device to leave closes the helper session, unless the bridge keeps it; earlier
    /// ones leave it open. A device's own `disconnect` is forwarded only when it closes it.
    func leave(_ device: DeviceSession, forwarding message: [String: Any]? = nil) throws -> [String: Any] {
        joined.remove(ObjectIdentifier(device)); device.adoptedGeneration = nil
        releaseTuner(ObjectIdentifier(device))
        var response: [String: Any] = ["version": 1, "status": "confirmed", "result": [String: Any](),
                                       "session_id": helperSession ?? NSNull(), "revision": revision]
        guard joined.isEmpty, !keepsSession else { return response }
        if var message {
            if let helperSession { message["session_id"] = helperSession }
            response = try forward(message, for: device).response
        }
        else if let session = helperSession { _ = try? helper.request(["operation": "disconnect", "session_id": session], device: device.index); helperSession = nil; cached = nil; identity = nil }
        if helperSession == nil { recovering = false; retryDelay = 1; retryAt = 0 }
        return response
    }
    /// Used by the offline shell to exercise a cable interruption, without touching USB.
    func simulateDeviceRemoval() throws {
        guard allowsRecovery, let session = helperSession else { throw BridgeFailure.disconnected }
        _ = try helper.request(["operation": "disconnect", "session_id": session])
        helperSession = nil; cached = nil; identity = nil; recovering = true; retryAt = now() + 2; retryDelay = 1
    }
    /// Called from a device's deinit, so a released device never holds the helper session open.
    func forget(_ id: ObjectIdentifier) {
        admitted.removeAll { $0.device == nil }
        let wasJoined = joined.remove(id) != nil
        releaseTuner(id)
        guard wasJoined, joined.isEmpty, !keepsSession, let session = helperSession else { return }
        _ = try? helper.request(["operation": "disconnect", "session_id": session])
        helperSession = nil; cached = nil; identity = nil; recovering = false; retryDelay = 1; retryAt = 0
    }
    /// The helper's transport failed: no approval survives. Trust belongs to the devices, not
    /// the helper, so trusted devices reconnect without a code once the bridge is back.
    private func failAll() {
        let all = devices; joined.removeAll(); helperSession = nil; tunerModes.removeAll(); cached = nil; identity = nil
        if !all.isEmpty { helper.diagnostics.record(.bridgeRevoked) }
        recovering = false; retryDelay = 1; retryAt = 0
        for device in all { device.endConnection() }
    }
}
#endif
