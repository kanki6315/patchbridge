#if os(macOS)
import Foundation

/// Holds off App Nap and idle sleep while a phone is approved on the bridge. A throttled or
/// sleeping Mac answers late or drops the Bluetooth link. The hold outlasts the last phone by
/// `grace`, so a phone whose link dropped can find the Mac again before it sleeps.
/// The display may still sleep. Safe to call from any queue.
final class KeepAwake {
    static let grace: TimeInterval = 90
    private let lock = NSLock()
    private let begin: () -> NSObjectProtocol
    private let end: (NSObjectProtocol) -> Void
    private let after: (TimeInterval, DispatchWorkItem) -> Void
    private let grace: TimeInterval
    private var activity: NSObjectProtocol?
    private var release: DispatchWorkItem?
    private var generation = 0
    var holding: Bool { lock.withLock { activity != nil } }

    init(grace: TimeInterval = KeepAwake.grace,
         begin: @escaping () -> NSObjectProtocol = {
             ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                   reason: "A phone is editing the Quad Cortex through this Mac.")
         },
         end: @escaping (NSObjectProtocol) -> Void = { ProcessInfo.processInfo.endActivity($0) },
         after: @escaping (TimeInterval, DispatchWorkItem) -> Void = { DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + $0, execute: $1) }) {
        self.grace = grace; self.begin = begin; self.end = end; self.after = after
    }
    deinit { stop() }
    /// True while any phone is approved. Letting go waits out the grace period.
    func hold(_ wanted: Bool) {
        lock.lock(); defer { lock.unlock() }
        if wanted {
            release?.cancel(); release = nil
            if activity == nil { activity = begin() }
            return
        }
        guard activity != nil, release == nil else { return }
        generation += 1
        let expected = generation
        let item = DispatchWorkItem { [weak self] in self?.expire(expected) }
        release = item; after(grace, item)
    }
    /// A release that already started when a phone came back must not end the new hold, so
    /// the check and the release happen under one lock.
    private func expire(_ expected: Int) {
        lock.lock(); defer { lock.unlock() }
        guard generation == expected, release != nil else { return }
        endLocked()
    }
    /// Lets go at once, as when the bridge stops.
    func stop() {
        lock.lock(); defer { lock.unlock() }
        endLocked()
    }
    private func endLocked() {
        release?.cancel(); release = nil
        if let activity { end(activity) }
        activity = nil
    }
}
#endif
