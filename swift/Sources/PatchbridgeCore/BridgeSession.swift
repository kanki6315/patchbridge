#if os(macOS)
import Foundation

/// One authorized phone per connection. Dispatch serially on the transport queue.
public final class BridgeSession {
    public private(set) var token = UUID().uuidString
    public private(set) var phoneName = "iPhone"
    public let macName: String
    public var approvalCode: String { DeviceIdentity.approvalCode(token) }
    public private(set) var recovering = false
    private let allowsRecovery: Bool
    private let now: () -> TimeInterval
    private var retryAt: TimeInterval = 0
    private var retryDelay: TimeInterval = 1
    /// Called only for forwarded mutations, on the serialized transport queue.
    var onMutation: (([String: Any], [String: Any]?) -> Void)?
    private var authorized = false
    private var helperSession: String?
    private var requestIDs = Set<String>()
    private let helper: HelperClient
    private let requestTimeout: TimeInterval
    public init(helper: HelperClient, requestTimeout: TimeInterval = 5, allowsRecovery: Bool = false,
                macName: String = DeviceIdentity.macName,
                now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.helper = helper; self.requestTimeout = requestTimeout
        self.allowsRecovery = allowsRecovery; self.now = now
        self.macName = DeviceIdentity.name(macName, fallback: "Mac")
    }
    public func approve() { authorized = true; helper.diagnostics.record(.bridgeApproved) }
    public func revoke() {
        helper.diagnostics.record(.bridgeRevoked)
        authorized = false; token = UUID().uuidString
        if let id = helperSession { _ = try? helper.request(["operation": "disconnect", "session_id": id]) }
        helperSession = nil
        requestIDs.removeAll(); recovering = false; retryDelay = 1; retryAt = 0; phoneName = "iPhone"
    }
    /// Used by the offline shell to exercise a cable interruption, without touching USB.
    public func simulateDeviceRemoval() throws {
        guard allowsRecovery, authorized, let id = helperSession else { throw BridgeFailure.disconnected }
        _ = try helper.request(["operation": "disconnect", "session_id": id])
        helperSession = nil; recovering = true; retryAt = now() + 2; retryDelay = 1
    }
    private func recoveryReply(_ message: [String: Any]) -> [String: Any] {
        return ["version": 1, "id": message["id"] ?? NSNull(), "connection_id": token,
                "status": "error", "retry_after": max(0.5, retryAt - now()),
                "error": ["code": "device_unavailable", "message": "QC unavailable. Editing is paused while the bridge reconnects."]]
    }
    public func handle(_ message: [String: Any]) throws -> [String: Any] {
        guard let operation = message["operation"] as? String,
              let version = message["version"] as? NSNumber, String(cString: version.objCType) != "c", version.doubleValue == 1,
              let id = message["id"] as? String, !id.isEmpty, id.count <= 128 else { throw BridgeFailure.protocolError }
        if operation == "hello" {
            if !authorized { phoneName = DeviceIdentity.name(message["device_name"] as? String, fallback: "iPhone") }
            return ["version": 1, "id": message["id"] ?? NSNull(), "connection_id": token, "authorization_required": true,
                    "mac_name": macName, "approval_code": approvalCode, "max_message_bytes": 1_048_576]
        }
        guard authorized else { helper.diagnostics.record(.requestRejected, operation: operation, code: "unauthorized"); throw BridgeFailure.unauthorized }
        guard message["connection_id"] as? String == token else { helper.diagnostics.record(.requestRejected, operation: operation, code: "stale_session"); throw BridgeFailure.staleSession }
        if helper.readOnly && !["connect", "disconnect", "identify", "capabilities", "snapshot", "catalog", "subscribe", "recover"].contains(operation) {
            helper.diagnostics.record(.writeBlocked, operation: operation, code: "read_only")
            throw BridgeFailure.readOnly
        }
        guard !requestIDs.contains(id), requestIDs.count < 4096 else { throw BridgeFailure.protocolError }
        requestIDs.insert(id) // Consume before forwarding, including uncertain failures.
        if recovering && operation != "recover" { return recoveryReply(message) }
        if operation == "recover" && (!recovering || now() < retryAt) {
            guard recovering else { throw BridgeFailure.protocolError }
            return recoveryReply(message)
        }
        var forwarded = message
        if operation == "recover" { forwarded["operation"] = "connect"; forwarded.removeValue(forKey: "session_id") }
        let mutation = ["set_parameter", "save"].contains(operation)
        var response: [String: Any]
        do { response = try helper.request(forwarded, timeout: requestTimeout) }
        catch { if mutation { onMutation?(message, nil) }; revoke(); throw error }
        if mutation { onMutation?(message, response) }
        let code = (response["error"] as? [String: Any])?["code"] as? String
        if allowsRecovery && ["adapter_failure", "disconnected"].contains(code ?? ""), response["session_id"] as? String == nil {
            recovering = true; helperSession = nil
            retryAt = now() + retryDelay; retryDelay = min(retryDelay * 2, 8)
            return recoveryReply(message)
        }
        if operation == "recover" { recovering = false; retryDelay = 1 }
        response["id"] = message["id"] ?? NSNull()
        response["connection_id"] = token
        helperSession = response["session_id"] as? String
        return response
    }
}
#endif
