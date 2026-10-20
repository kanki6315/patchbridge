import Foundation

/// Structured, bounded diagnostics. Never accepts message bodies, paths, IDs, or free-form details.
public final class Diagnostics {
    public static let shared = Diagnostics()
    public enum Event: String, Codable {
        case helperStarted, helperStartFailed, helperStopped, requestStarted, requestConfirmed, requestRejected, requestFailed
        case bridgeApproved, bridgeRevoked, writeBlocked, editorStarted, editorDisconnected, editorFailed
    }
    private struct Entry: Codable {
        let sequence: Int
        let elapsedMilliseconds: Int
        let event: Event
        let operation: String?
        let code: String?
        let durationMilliseconds: Int?
    }
    private struct Report: Encodable {
        let schemaVersion = 1
        let protocolVersion = 1
        let appVersion: String
        let presetContentsIncluded = false
        let scope = "In-memory structured events only; no raw messages, stderr, paths, device/session identifiers, or preset data."
        let platform: String
        let osVersion: String
        let capacity: Int
        let droppedEvents: Int
        let events: [Entry]
    }
    private let lock = NSLock()
    private let capacity: Int
    private let started = ProcessInfo.processInfo.systemUptime
    private var entries = [Entry]()
    private var sequence = 0
    private var dropped = 0
    public init(capacity: Int = 256) { self.capacity = min(1024, max(1, capacity)) }
    private static let operations: Set<String> = ["hello", "connect", "disconnect", "identify", "capabilities", "snapshot", "catalog", "subscribe", "set_parameter", "set_bypass", "select_scene", "select_preset", "save", "save_as"]
    private static let codes: Set<String> = ["timeout", "disconnected", "protocol_error", "unauthorized", "stale_session", "stale_context", "read_only", "overflow", "invalid_value", "invalid_request", "unsupported_operation", "unsupported_parameter", "unsupported_firmware", "adapter_failure", "already_connected", "transport_failure"]
    public func record(_ event: Event, operation: String? = nil, code: String? = nil, duration: TimeInterval? = nil) {
        lock.lock(); defer { lock.unlock() }
        sequence += 1
        let safeDuration = duration.flatMap { $0.isFinite ? Int(min(3_600_000, max(0, $0 * 1000))) : nil }
        entries.append(Entry(sequence: sequence, elapsedMilliseconds: Int(min(2_147_483_647, max(0, (ProcessInfo.processInfo.systemUptime - started) * 1000))),
                             event: event, operation: operation.map { Self.operations.contains($0) ? $0 : "unknown" },
                             code: code.map { Self.codes.contains($0) ? $0 : "unknown" }, durationMilliseconds: safeDuration))
        if entries.count > capacity { entries.removeFirst(); dropped += 1 }
    }
    public func clear() { lock.lock(); defer { lock.unlock() }; entries.removeAll(); sequence = 0; dropped = 0 }
    public func reportData() throws -> Data {
        lock.lock(); let copy = entries; let lost = dropped; lock.unlock()
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if os(macOS)
        let platform = "macOS"
        #else
        let platform = "iOS"
        #endif
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let safeVersion = version.count <= 32 && version.range(of: "^[0-9]+(\\.[0-9]+)*$", options: .regularExpression) != nil ? version : "unknown"
        let report = Report(appVersion: safeVersion, platform: platform, osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", capacity: capacity, droppedEvents: lost, events: copy)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(report)
    }
    /// Only an explicit export persists data. Writes privately and replaces an existing report atomically.
    public func export(to destination: URL) throws {
        let data = try reportData()
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".patchbridge-\(UUID().uuidString).tmp")
        let manager = FileManager.default
        guard manager.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? manager.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: temporary)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        } else { try manager.moveItem(at: temporary, to: destination) }
    }
}
