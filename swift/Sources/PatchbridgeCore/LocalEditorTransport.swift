#if os(macOS)
import Foundation

/// The Mac's own editor, talking to the bridge in the same app instead of over Bluetooth.
/// It joins the shared USB session like any device, so the first-write-wins rule, recovery and
/// state pushes are the same as for an iPhone. Being on this Mac is its approval; it never
/// shows a code and is never trusted. Owned and called on the main queue, like `BLECentral`;
/// requests run on the bridge's worker queue.
public final class LocalEditorTransport: EditorTransport {
    public var onReady: (() -> Void)?
    public var onDisconnected: (() -> Void)?
    public var onStatus: ((String) -> Void)?
    public var onResponse: (([String: Any]) -> Void)?
    public private(set) var disconnectionReason: String?
    /// This editor's device ID on the bridge.
    public let id = UUID()
    private let queue: DispatchQueue
    /// Runs on `queue`. Nil means the bridge isn't running.
    private let request: (UUID, [String: Any]) -> [String: Any]?
    /// Runs on `queue` when this editor leaves.
    private let left: (UUID) -> Void
    private var open = false

    init(queue: DispatchQueue, request: @escaping (UUID, [String: Any]) -> [String: Any]?, left: @escaping (UUID) -> Void) {
        self.queue = queue; self.request = request; self.left = left
    }
    public func reconnect() {
        open = true; disconnectionReason = nil
        DispatchQueue.main.async { [weak self] in
            guard let self, self.open else { return }
            self.onStatus?("Connected to this Mac’s bridge"); self.onReady?()
        }
    }
    public func disconnect() {
        guard open else { return }
        open = false
        let id = id, left = left
        queue.async { left(id) }
    }
    public func send(_ message: [String: Any]) throws {
        guard open else { throw BridgeFailure.disconnected }
        let id = id, request = request
        queue.async { [weak self] in
            let reply = request(id, message)
            DispatchQueue.main.async {
                guard let self, self.open else { return }
                if let reply { self.onResponse?(reply) } else { self.end("The bridge stopped. Start it to edit again.") }
            }
        }
    }
    /// An event the bridge pushed to this editor. Main queue, posted from the worker queue in
    /// the order it was sent, so it never overtakes a reply sent after it.
    func deliver(_ event: [String: Any]) {
        guard open else { return }
        onResponse?(event)
    }
    /// The bridge stopped or failed under this editor. Main queue.
    func end(_ reason: String) {
        guard open else { return }
        open = false; disconnectionReason = reason
        let id = id, left = left
        queue.async { left(id) }
        onDisconnected?()
    }
}
#endif
