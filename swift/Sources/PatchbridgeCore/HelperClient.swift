#if os(macOS)
import Foundation
import Darwin

public enum BridgeFailure: Error { case protocolError, disconnected, timeout, unauthorized, staleSession, overflow, readOnly }

/// Synchronous, serialized process I/O. Call from a worker queue, never the UI queue.
public final class HelperClient {
    public let diagnostics: Diagnostics
    public let readOnly: Bool
    private let process = Process()
    private let input = Pipe(), output = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var live = false
    public private(set) var events: [[String: Any]] = []

    /// Production launch resolves only inside the owning app bundle; never falls back to system Python.
    public convenience init(bundle: Bundle = .main, capturedFixture: URL? = nil, diagnostics: Diagnostics = .shared) throws {
        guard let executable = bundle.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("patchbridge-helper"),
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            diagnostics.record(.helperStartFailed, code: "disconnected")
            throw BridgeFailure.disconnected
        }
        try self.init(executable: executable, arguments: capturedFixture.map { ["--captured-read-only", $0.path] } ?? [], readOnly: capturedFixture != nil, diagnostics: diagnostics, environment: ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"])
    }

    /// Development-only explicit interpreter/source paths.
    public convenience init(python: String, source: String, capturedFixture: URL? = nil, diagnostics: Diagnostics = .shared) throws {
        var env = ProcessInfo.processInfo.environment
        env["PYTHONPATH"] = source
        try self.init(executable: URL(fileURLWithPath: python),
                      arguments: ["-m", "patchbridge.helper", "--adapter", capturedFixture == nil ? "simulated" : "captured-read-only"] + (capturedFixture.map { ["--fixture", $0.path] } ?? []), readOnly: capturedFixture != nil, diagnostics: diagnostics, environment: env)
    }
    private init(executable: URL, arguments: [String], readOnly: Bool, diagnostics: Diagnostics, environment: [String: String]) throws {
        self.diagnostics = diagnostics
        self.readOnly = readOnly
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = executable.deletingLastPathComponent()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        do { try process.run() }
        catch { diagnostics.record(.helperStartFailed, code: "transport_failure"); throw error }
        live = true
        diagnostics.record(.helperStarted, code: readOnly ? "read_only" : nil)
    }

    public func request(_ fields: [String: Any], timeout: TimeInterval = 5) throws -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        guard live, process.isRunning else {
            diagnostics.record(.requestFailed, operation: fields["operation"] as? String, code: "disconnected")
            throw BridgeFailure.disconnected
        }
        let started = ProcessInfo.processInfo.systemUptime
        let operation = fields["operation"] as? String
        diagnostics.record(.requestStarted, operation: operation)
        let id = UUID().uuidString
        var message = fields
        message["id"] = id; message["version"] = 1; message["type"] = "request"
        do {
            var bytes = try JSONSerialization.data(withJSONObject: message)
            bytes.append(10)
            guard bytes.count <= 65536 else { throw BridgeFailure.overflow }
            try input.fileHandleForWriting.write(contentsOf: bytes)
            let deadline = Date().addingTimeInterval(timeout)
            while true {
                if let end = buffer.firstIndex(of: 10) {
                    let line = buffer.prefix(upTo: end)
                    buffer.removeSubrange(...end)
                    guard let reply = try JSONSerialization.jsonObject(with: line) as? [String: Any], reply["version"] as? Int == 1 else { throw BridgeFailure.protocolError }
                    if reply["type"] as? String == "event" {
                        events.append(reply)
                        if events.count > 32 { events.removeFirst() }
                        continue
                    }
                    guard reply["type"] as? String == "response", reply["id"] as? String == id else { throw BridgeFailure.protocolError }
                    diagnostics.record(reply["status"] as? String == "confirmed" ? .requestConfirmed : .requestRejected,
                        operation: operation, code: (reply["error"] as? [String: Any])?["code"] as? String,
                        duration: ProcessInfo.processInfo.systemUptime - started)
                    return reply
                }
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { throw BridgeFailure.timeout }
                var fd = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
                let ready = poll(&fd, 1, Int32(min(remaining * 1000, 1000)))
                if ready < 0 { if errno == EINTR { continue }; throw BridgeFailure.disconnected }
                if ready == 0 { continue }
                var chunk = [UInt8](repeating: 0, count: 8192)
                let count = Darwin.read(fd.fd, &chunk, chunk.count)
                guard count > 0 else { throw BridgeFailure.disconnected }
                buffer.append(contentsOf: chunk.prefix(count))
                guard buffer.count <= 4 * 1024 * 1024 else { throw BridgeFailure.overflow }
            }
        } catch {
            let code: String
            switch error {
            case BridgeFailure.timeout: code = "timeout"
            case BridgeFailure.disconnected: code = "disconnected"
            case BridgeFailure.overflow: code = "overflow"
            default: code = "protocol_error"
            }
            diagnostics.record(.requestFailed, operation: operation, code: code, duration: ProcessInfo.processInfo.systemUptime - started)
            stopLocked() // Never replay an uncertain edit.
            throw error
        }
    }

    public func stop() { lock.lock(); defer { lock.unlock() }; stopLocked() }
    private func stopLocked() {
        guard live else { return }; live = false
        diagnostics.record(.helperStopped)
        try? input.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(0.5)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { process.terminate() }
        let termDeadline = Date().addingTimeInterval(0.5)
        while process.isRunning && Date() < termDeadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        // Foundation reaps Process children. waitUntilExit can strand the caller's
        // run loop when launch and shutdown occur on different threads; keep every
        // shutdown stage bounded, including the post-kill observation.
        let killDeadline = Date().addingTimeInterval(0.5)
        while process.isRunning && Date() < killDeadline { Thread.sleep(forTimeInterval: 0.01) }
        try? output.fileHandleForReading.close()
        buffer.removeAll(); events.removeAll()
    }
    deinit { stop() }
}
#endif
