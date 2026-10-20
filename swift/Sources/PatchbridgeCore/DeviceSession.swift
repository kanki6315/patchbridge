#if os(macOS)
import Foundation

/// One admitted device's approval and requests. The USB session, recovery and trust are
/// shared through `SharedUSBSession`. Dispatch serially on the transport queue.
public final class DeviceSession {
    public let shared: SharedUSBSession
    public private(set) var token = UUID().uuidString
    public private(set) var phoneName = "iPhone"
    public var macName: String { shared.macName }
    public var approvalCode: String { DeviceIdentity.approvalCode(token) }
    public var recovering: Bool { shared.recovering }
    /// The shared session generation this device last joined; nil while not joined.
    var adoptedGeneration: Int?
    private var authorized = false
    /// This device's entry in the bridge's trust registry. Kept across connections.
    private var trustToken: String?
    private var trustedConnection = false
    public var trustedPhoneName: String? { trustToken.flatMap(shared.trust.name(for:)) }
    public var isTrustedConnection: Bool { trustedConnection && trustedPhoneName != nil }
    private var requestIDs = Set<String>()
    private var helper: HelperClient { shared.helper }
    init(shared: SharedUSBSession) { self.shared = shared }
    /// A bridge serving exactly this device, for the single-device shells and tests.
    public convenience init(helper: HelperClient, requestTimeout: TimeInterval = 5, allowsRecovery: Bool = false,
                            macName: String = DeviceIdentity.macName,
                            now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.init(shared: SharedUSBSession(helper: helper, requestTimeout: requestTimeout, allowsRecovery: allowsRecovery, macName: macName, now: now))
        shared.register(self)
    }
    deinit { shared.forget(ObjectIdentifier(self)) }
    public func approve(trusting: Bool = false) {
        authorized = true; helper.diagnostics.record(.bridgeApproved)
        if trusting { trustToken = shared.trust.add(name: phoneName); trustedConnection = true }
    }
    /// The connected phone keeps its current approval; its next connection needs a code.
    public func revokeTrust() {
        if let trustToken { shared.trust.remove(trustToken) }
        trustToken = nil; trustedConnection = false
    }
    public func revoke() {
        helper.diagnostics.record(.bridgeRevoked)
        _ = try? shared.leave(self)
        endConnection()
    }
    /// Clears this connection's approval; trust lives in the registry.
    func endConnection() {
        authorized = false; trustedConnection = false; token = UUID().uuidString
        adoptedGeneration = nil; requestIDs.removeAll(); phoneName = "iPhone"
    }
    /// Used by the offline shell to exercise a cable interruption, without touching USB.
    public func simulateDeviceRemoval() throws {
        guard authorized else { throw BridgeFailure.disconnected }
        try shared.simulateDeviceRemoval()
    }
    private func unavailable(_ message: [String: Any], retryAfter: TimeInterval, notApplied: Bool = false) -> [String: Any] {
        var reply: [String: Any] = ["version": 1, "id": message["id"] ?? NSNull(), "connection_id": token,
                "status": "error", "retry_after": retryAfter,
                "error": ["code": "device_unavailable", "message": "QC unavailable. Editing is paused while the bridge reconnects."]]
        if notApplied { reply["applied"] = false }
        return reply
    }
    public func handle(_ message: [String: Any]) throws -> [String: Any] {
        guard let operation = message["operation"] as? String,
              let version = message["version"] as? NSNumber, String(cString: version.objCType) != "c", version.doubleValue == 1,
              let id = message["id"] as? String, !id.isEmpty, id.count <= 128 else { throw BridgeFailure.protocolError }
        if operation == "hello" {
            if !authorized {
                phoneName = DeviceIdentity.name(message["device_name"] as? String, fallback: "iPhone")
                if let offered = message["trust_token"] as? String, shared.trust.name(for: offered) != nil {
                    authorized = true; trustedConnection = true; trustToken = offered
                    shared.trust.rename(offered, to: phoneName)
                    helper.diagnostics.record(.bridgeApproved)
                }
            }
            return ["version": 1, "id": message["id"] ?? NSNull(), "connection_id": token, "authorization_required": !isTrustedConnection,
                    "mac_name": macName, "approval_code": approvalCode, "max_message_bytes": 1_048_576]
        }
        guard authorized else { helper.diagnostics.record(.requestRejected, operation: operation, code: "unauthorized"); throw BridgeFailure.unauthorized }
        guard message["connection_id"] as? String == token else { helper.diagnostics.record(.requestRejected, operation: operation, code: "stale_session"); throw BridgeFailure.staleSession }
        if helper.readOnly && !["connect", "disconnect", "identify", "capabilities", "snapshot", "catalog", "subscribe", "recover"].contains(operation) {
            helper.diagnostics.record(.writeBlocked, operation: operation, code: "read_only")
            throw BridgeFailure.readOnly
        }
        let mutation = ["set_parameter", "save", "set_bypass", "select_scene", "select_preset", "save_as"].contains(operation)
        if mutation {
            guard !requestIDs.contains(id), requestIDs.count < 4096 else { throw BridgeFailure.protocolError }
            requestIDs.insert(id) // Consume before forwarding, including uncertain failures.
        }
        if shared.recovering && operation != "recover" { return unavailable(message, retryAfter: shared.retryAfter) }
        let outdated = shared.isOutdated(self), joined = shared.isJoined(self)
        // Only the session-free `capabilities` may skip membership; an outdated device never does,
        // because the reply would carry a session its editor hasn't adopted.
        let sessionFree = ["connect", "recover", "disconnect"].contains(operation)
        if !sessionFree && (outdated || (!joined && operation != "capabilities")) {
            // Outdated: another device reconnected the helper while this one wasn't looking, so
            // route it through recovery instead of letting the helper reject its stale session.
            // Not joined (never connected, or disconnected): the shared session isn't its to use.
            var reply = unavailable(message, retryAfter: 0, notApplied: mutation)
            if !outdated {
                reply["error"] = ["code": "disconnected", "message": "Connect to the QC before sending requests."]
                reply.removeValue(forKey: "retry_after")
            }
            if mutation { shared.onMutation?(phoneName, message, reply) }
            return reply
        }
        if operation == "recover" {
            // Recovery is for a paused bridge, or for a device not on the current session:
            // one that missed another's reconnect, or first connected during the outage.
            guard shared.recovering || outdated || !joined else { throw BridgeFailure.protocolError }
            if shared.recovering && !shared.canRecoverNow { return unavailable(message, retryAfter: shared.retryAfter) }
        }
        var result: (response: [String: Any], recovering: Bool)
        do {
            switch operation {
            case "connect", "recover": result = try shared.join(self, message)
            case "disconnect": result = (try shared.leave(self, forwarding: message), false)
            default: result = try shared.forward(message)
            }
        } catch {
            if mutation { shared.onMutation?(phoneName, message, nil) }
            throw error
        }
        if mutation { shared.onMutation?(phoneName, message, result.response) }
        if result.recovering { return unavailable(message, retryAfter: shared.retryAfter) }
        var response = result.response
        response["id"] = message["id"] ?? NSNull()
        response["connection_id"] = token
        if operation == "connect", isTrustedConnection, let trustToken { response["trust_token"] = trustToken }
        return response
    }
}
#endif
