#if os(macOS)
import Foundation

/// The bridge owner's answer to one message, and what it means for the sender's admission.
struct PeripheralReply {
    enum Admission { case unchanged, admit, release }
    var message: [String: Any]
    var admission: Admission = .unchanged
}

/// Per-central transport state for the Mac peripheral, independent of CoreBluetooth.
/// Everything here runs on the radio queue. Complete messages are handed to the owner's
/// queue (where USB requests run) without waiting, so one device's slow request never
/// delays another device's Bluetooth writes or their acknowledgements.
final class CentralRouter {
    static let unadmittedLimit = 4
    static let unadmittedMessageBytes = 4096
    static let unadmittedTimeout: TimeInterval = 10
    /// The editor's 60 s timeout minus the 40 s helper timeout, less margin for transfer.
    static let queueDeadline: TimeInterval = 15
    static let mutations: Set<String> = ["set_parameter", "save", "set_bypass", "select_scene", "select_preset", "save_as"]
    enum WriteResult { case success, busy, notPermitted, failed }
    private struct Entry {
        let epoch: Int
        let since: TimeInterval
        var limit: Int
        var admitted = false
        var inFlight = false
        var releasing = false
        var transfer: UInt32 = 0
        /// The phone said in its hello that it reads deflated replies.
        var deflate = false
        var outgoing: [Data] = []
        var sendingEvent = false
        var pendingEvent: [String: Any]?
        var pendingTunerEvent: [String: Any]?
        var receiver = ChunkReceiver(limit: CentralRouter.unadmittedMessageBytes)
    }
    /// Owner queue. Returns the reply for one message from the device with that identifier.
    var onMessage: ((UUID, [String: Any]) -> PeripheralReply)?
    /// Owner queue. The device's transport state is gone; drop its session.
    var onDisconnect: ((UUID) -> Void)?
    /// Radio queue. Sends one chunk; false when the transmit queue is full.
    var send: ((UUID, Data) -> Bool)?
    /// Radio queue. Invalidates every central's characteristics, forcing rediscovery.
    var resetService: (() -> Void)?
    private var entries: [UUID: Entry] = [:] { didSet { publishLive() } }
    private var epoch = 0
    /// Epochs of current connections, readable from the owner's queue. Updated on the radio
    /// queue whenever entries change, before any disconnect is scheduled, so queued work for
    /// a connection that has ended is never started.
    private var live = Set<Int>()
    private let liveLock = NSLock()
    private let owner: DispatchQueue
    private let radio: DispatchQueue
    private let now: () -> TimeInterval
    private let diagnostics: Diagnostics
    init(radio: DispatchQueue, owner: DispatchQueue, diagnostics: Diagnostics = .shared,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.radio = radio; self.owner = owner; self.diagnostics = diagnostics; self.now = now
    }
    private func refuseBusy(_ message: [String: Any]) -> PeripheralReply {
        diagnostics.record(.requestRejected, operation: message["operation"] as? String, code: "busy")
        return PeripheralReply(message: Self.busyReply(message))
    }

    static func errorReply(_ message: [String: Any], code: String, text: String, retryAfter: TimeInterval? = nil) -> [String: Any] {
        var reply: [String: Any] = ["version": 1, "id": message["id"] as? String ?? "", "connection_id": message["connection_id"] ?? NSNull(),
                                    "status": "error", "error": ["code": code, "message": text]]
        if let retryAfter { reply["retry_after"] = retryAfter }
        // Refused before reaching USB, so the outcome is certain.
        if mutations.contains(message["operation"] as? String ?? "") { reply["applied"] = false }
        return reply
    }
    static func busyReply(_ message: [String: Any]) -> [String: Any] {
        errorReply(message, code: "busy", text: "The bridge is busy with another device. Try again.", retryAfter: 1)
    }

    func subscribe(_ id: UUID, limit: Int) {
        expireUnadmitted()
        if entries[id] != nil { entries[id]?.limit = limit; return }
        // Excess devices get no entry; their writes are refused at the Bluetooth level.
        guard entries.values.filter({ !$0.admitted }).count < Self.unadmittedLimit else { return }
        epoch += 1; entries[id] = Entry(epoch: epoch, since: now(), limit: limit)
    }
    func unsubscribe(_ id: UUID) {
        guard entries.removeValue(forKey: id) != nil else { return }
        notifyDisconnect(id)
    }
    /// Drops every central, as when Bluetooth turns off or the bridge stops.
    func removeAll() {
        let ids = Array(entries.keys); entries.removeAll()
        ids.forEach(notifyDisconnect)
    }

    func write(_ id: UUID, _ bytes: Data) -> WriteResult {
        expireUnadmitted()
        guard var entry = entries[id] else { return .notPermitted }
        guard (entry.outgoing.isEmpty || entry.sendingEvent), !entry.releasing else { return .busy }
        let object: [String: Any]
        do {
            guard let message = try entry.receiver.receive(bytes) else { entries[id] = entry; return .success }
            guard let decoded = try JSONSerialization.jsonObject(with: message) as? [String: Any] else { throw BridgeFailure.protocolError }
            object = decoded
        } catch { fail(id); return .failed }
        if object["operation"] as? String == "hello" { entry.deflate = (object["compression"] as? [String])?.contains("deflate") == true }
        entries[id] = entry
        if !entry.admitted && object["operation"] as? String != "hello" {
            reply(id, entry.epoch, PeripheralReply(message: Self.errorReply(object, code: "invalid_request", text: "Say hello before sending requests.")))
            return .success
        }
        // The editor sends one request at a time; a second is refused, never queued.
        guard !entry.inFlight else { reply(id, entry.epoch, refuseBusy(object)); return .success }
        entries[id]?.inFlight = true
        let epoch = entry.epoch, received = now()
        owner.async { [weak self] in
            guard let self else { return }
            // The device left while this waited. Work that already started finishes normally.
            guard self.liveLock.withLock({ self.live.contains(epoch) }) else { return }
            // A request that would finish after its client gave up is refused, never run late.
            // `hello` needs no USB, so it is always answered.
            let late = self.now() - received > Self.queueDeadline && object["operation"] as? String != "hello"
            let answer = late ? self.refuseBusy(object)
                : self.onMessage?(id, object) ?? PeripheralReply(message: Self.errorReply(object, code: "disconnected", text: "The bridge stopped."))
            self.radio.async { self.reply(id, epoch, answer, completing: true) }
        }
        return .success
    }

    private func reply(_ id: UUID, _ epoch: Int, _ answer: PeripheralReply, completing: Bool = false) {
        guard var entry = entries[id], entry.epoch == epoch else { return } // The device left meanwhile.
        if completing { entry.inFlight = false }
        switch answer.admission {
        case .admit: entry.admitted = true; entry.receiver.limit = 1_048_576
        case .release: entry.releasing = true
        case .unchanged: break
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: answer.message)
            entry.transfer &+= 1
            entry.sendingEvent = false
            entry.outgoing += try Chunks.split(data, limit: min(entry.limit, 512), transfer: entry.transfer, deflate: entry.deflate)
        } catch { fail(id); return }
        entries[id] = entry
        drain()
    }
    /// Coalesce unsent hints; complete messages always share the same chunk queue.
    func notify(_ id: UUID, message: [String: Any]) {
        guard entries[id]?.admitted == true, entries[id]?.releasing == false else { return }
        if message["event"] as? String == "tuner_updated" { entries[id]?.pendingTunerEvent = message }
        else { entries[id]?.pendingEvent = message }
        drain()
    }
    func drain() {
        for id in Array(entries.keys) {
            guard var entry = entries[id] else { continue }
            while let chunk = entry.outgoing.first {
                guard send?(id, chunk) ?? true else { entries[id] = entry; return } // Resumes when ready.
                entry.outgoing.removeFirst()
            }
            entry.sendingEvent = false
            if !entry.inFlight, !entry.releasing, let event = entry.pendingEvent ?? entry.pendingTunerEvent {
                if entry.pendingEvent != nil { entry.pendingEvent = nil }
                else { entry.pendingTunerEvent = nil }
                do {
                    entry.transfer &+= 1
                    entry.outgoing = try Chunks.split(JSONSerialization.data(withJSONObject: event), limit: min(entry.limit, 512), transfer: entry.transfer, deflate: entry.deflate)
                    entry.sendingEvent = true
                } catch { fail(id); continue }
                entries[id] = entry
                drain()
                continue
            }
            // An unadmitted device is dropped once it has its answer.
            if entry.releasing { entries[id] = nil; notifyDisconnect(id) } else { entries[id] = entry }
        }
    }
    /// An invalid transfer needs a fresh start. Other devices keep their state; when none
    /// remain, the service is also reset so the phone rediscovers it, as before.
    private func fail(_ id: UUID) {
        guard let old = entries[id] else { return }
        epoch += 1; entries[id] = Entry(epoch: epoch, since: now(), limit: old.limit)
        notifyDisconnect(id)
        if entries.count == 1 { entries.removeAll(); resetService?() }
    }
    private func expireUnadmitted() {
        let cutoff = now() - Self.unadmittedTimeout
        for (id, entry) in entries where !entry.admitted && !entry.inFlight && entry.outgoing.isEmpty && entry.since < cutoff {
            entries[id] = nil; notifyDisconnect(id)
        }
    }
    private func publishLive() {
        let epochs = Set(entries.values.map(\.epoch))
        liveLock.withLock { live = epochs }
    }
    private func notifyDisconnect(_ id: UUID) { owner.async { [weak self] in self?.onDisconnect?(id) } }
}
#endif
