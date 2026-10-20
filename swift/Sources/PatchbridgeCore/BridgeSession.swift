#if os(macOS)
import Foundation

/// One authorized phone per connection. Dispatch serially on the transport queue.
public final class BridgeSession {
    public private(set) var token = UUID().uuidString
    private var authorized = false
    private var helperSession: String?
    private var requestIDs = Set<String>()
    private let helper: HelperClient
    private let requestTimeout: TimeInterval
    public init(helper: HelperClient, requestTimeout: TimeInterval = 5) {
        self.helper = helper; self.requestTimeout = requestTimeout
    }
    public func approve() { authorized = true; helper.diagnostics.record(.bridgeApproved) }
    public func revoke() {
        helper.diagnostics.record(.bridgeRevoked)
        authorized = false; token = UUID().uuidString
        if let id = helperSession { _ = try? helper.request(["operation": "disconnect", "session_id": id]) }
        helperSession = nil
        requestIDs.removeAll()
    }
    public func handle(_ message: [String: Any]) throws -> [String: Any] {
        guard let operation = message["operation"] as? String,
              let version = message["version"] as? NSNumber, String(cString: version.objCType) != "c", version.doubleValue == 1,
              let id = message["id"] as? String, !id.isEmpty, id.count <= 128 else { throw BridgeFailure.protocolError }
        if operation == "hello" {
            return ["version": 1, "id": message["id"] ?? NSNull(), "connection_id": token, "authorization_required": true, "max_message_bytes": 1_048_576]
        }
        guard authorized else { helper.diagnostics.record(.requestRejected, operation: operation, code: "unauthorized"); throw BridgeFailure.unauthorized }
        guard message["connection_id"] as? String == token else { helper.diagnostics.record(.requestRejected, operation: operation, code: "stale_session"); throw BridgeFailure.staleSession }
        if helper.readOnly && !["connect", "disconnect", "identify", "capabilities", "snapshot", "catalog", "subscribe"].contains(operation) {
            helper.diagnostics.record(.writeBlocked, operation: operation, code: "read_only")
            throw BridgeFailure.readOnly
        }
        guard !requestIDs.contains(id), requestIDs.count < 4096 else { throw BridgeFailure.protocolError }
        requestIDs.insert(id) // Consume before forwarding, including uncertain failures.
        var response: [String: Any]
        do { response = try helper.request(message, timeout: requestTimeout) }
        catch { revoke(); throw error }
        response["id"] = message["id"] ?? NSNull()
        response["connection_id"] = token
        helperSession = response["session_id"] as? String
        return response
    }
}
#endif
