import XCTest
@testable import PatchbridgeCore

final class CentralRouterTests: XCTestCase {
    private let radio = DispatchQueue(label: "test.radio"), owner = DispatchQueue(label: "test.owner")
    private let lock = NSLock()
    private var time: TimeInterval = 0
    private var clock: TimeInterval { get { lock.withLock { time } } set { lock.withLock { time = newValue } } }
    private var router: CentralRouter!
    private var receivers = [UUID: ChunkReceiver]()
    private var replies = [UUID: [[String: Any]]]()
    private var handled = [String]()
    private var left = [UUID]()
    private var resets = 0
    private var transfer: UInt32 = 0

    override func setUp() {
        router = CentralRouter(radio: radio, owner: owner, now: { [unowned self] in clock })
        router.send = { [unowned self] id, data in
            if let message = try? receivers[id, default: ChunkReceiver()].receive(data),
               let object = try? JSONSerialization.jsonObject(with: message) as? [String: Any] { replies[id, default: []].append(object) }
            return true
        }
        router.resetService = { [unowned self] in resets += 1 }
        router.onDisconnect = { [unowned self] id in left.append(id) }
        router.onMessage = { [unowned self] _, message in
            let operation = message["operation"] as? String ?? ""
            handled.append(operation)
            return PeripheralReply(message: ["version": 1, "id": message["id"] ?? "", "status": "confirmed"], admission: operation == "hello" ? .admit : .unchanged)
        }
    }
    private func write(_ id: UUID, _ operation: String, padding: Int = 0) -> CentralRouter.WriteResult {
        var message: [String: Any] = ["version": 1, "id": UUID().uuidString, "operation": operation]
        if padding > 0 { message["padding"] = String(repeating: "x", count: padding) }
        transfer += 1
        let chunks = try! Chunks.split(JSONSerialization.data(withJSONObject: message), limit: 512, transfer: transfer)
        return radio.sync { chunks.map { router.write(id, $0) }.last! }
    }
    /// Lets queued owner work and its replies finish.
    private func flush() { radio.sync {}; owner.sync {}; radio.sync {}; owner.sync {} }
    private func admitted(_ id: UUID = UUID()) -> UUID {
        radio.sync { router.subscribe(id, limit: 185) }
        XCTAssertEqual(write(id, "hello"), .success); flush()
        return id
    }
    private func code(_ reply: [String: Any]?) -> String? { (reply?["error"] as? [String: Any])?["code"] as? String }

    func testRevisionEventsWaitBehindResponsesAndCoalesceUnderBackpressure() {
        let id = admitted()
        var blocked = true
        let original = router.send
        router.send = { central, data in blocked ? false : original?(central, data) ?? false }
        XCTAssertEqual(write(id, "snapshot"), .success); flush()
        radio.sync {
            router.notify(id, message: ["type": "event", "revision": 1])
            router.notify(id, message: ["type": "event", "revision": 2])
            blocked = false; router.drain()
        }
        XCTAssertEqual(replies[id]?.count, 3) // hello, response, newest event
        XCTAssertEqual(replies[id]?.last?["revision"] as? Int, 2)
        XCTAssertNotNil(replies[id]?[1]["id"])
        radio.sync { router.unsubscribe(id); router.notify(id, message: ["revision": 3]) }
        flush(); XCTAssertEqual(replies[id]?.count, 3)
    }
    func testTunerCoalescingPreservesPendingRevision() {
        let id = admitted()
        var blocked = true
        let original = router.send
        router.send = { central, data in blocked ? false : original?(central, data) ?? false }
        XCTAssertEqual(write(id, "snapshot"), .success); flush()
        radio.sync {
            router.notify(id, message: ["type": "event", "event": "revision_changed", "revision": 2])
            for seq in 1...10 {
                router.notify(id, message: ["type": "event", "event": "tuner_updated", "seq": seq])
            }
            blocked = false; router.drain()
        }
        XCTAssertEqual(replies[id]?.count, 4)
        XCTAssertEqual(replies[id]?[2]["revision"] as? Int, 2)
        XCTAssertEqual(replies[id]?[3]["seq"] as? Int, 10)
    }

    func testRequestMayArriveWhileEventChunksAreBackpressured() {
        let id = admitted()
        var blocked = true
        let original = router.send
        router.send = { central, data in blocked ? false : original?(central, data) ?? false }
        radio.sync { router.notify(id, message: ["type": "event", "revision": 1, "padding": String(repeating: "x", count: 500)]) }
        XCTAssertEqual(write(id, "snapshot"), .success); flush()
        radio.sync { blocked = false; router.drain() }
        XCTAssertEqual(replies[id]?.count, 3)
        XCTAssertEqual(replies[id]?[1]["type"] as? String, "event")
        XCTAssertEqual(replies[id]?[2]["status"] as? String, "confirmed")
    }
    func testRepliesAreDeflatedOnlyForPhonesThatOfferIt() {
        var sent = [UUID: [UInt8]]()
        router.send = { [unowned self] id, data in
            sent[id, default: []].append(data[0])
            if let message = try? receivers[id, default: ChunkReceiver()].receive(data),
               let object = try? JSONSerialization.jsonObject(with: message) as? [String: Any] { replies[id, default: []].append(object) }
            return true
        }
        router.onMessage = { _, message in
            PeripheralReply(message: ["version": 1, "id": message["id"] ?? "", "status": "confirmed", "state": String(repeating: "scene ", count: 500)],
                            admission: message["operation"] as? String == "hello" ? .admit : .unchanged)
        }
        let old = admitted(), new = UUID()
        radio.sync { router.subscribe(new, limit: 185) }
        transfer += 1
        let hello = try! Chunks.split(JSONSerialization.data(withJSONObject: ["version": 1, "id": "h", "operation": "hello", "compression": ["deflate"]]), limit: 512, transfer: transfer)
        radio.sync { hello.forEach { _ = router.write(new, $0) } }; flush()
        sent.removeAll()
        _ = write(old, "snapshot"); _ = write(new, "snapshot"); flush()
        XCTAssertEqual(Set(sent[old] ?? []), [1]); XCTAssertEqual(Set(sent[new] ?? []), [2])
        XCTAssertLessThan(sent[new]!.count, sent[old]!.count / 4)
        XCTAssertEqual(replies[new]?.last?["state"] as? String, replies[old]?.last?["state"] as? String)
    }
    func testSlowRequestDoesNotDelayAnotherDevicesWrites() {
        let phone = admitted(), pad = admitted()
        let release = DispatchSemaphore(value: 0)
        router.onMessage = { _, message in
            if message["operation"] as? String == "save" { release.wait() } // A slow USB request.
            return PeripheralReply(message: ["version": 1, "id": message["id"] ?? "", "status": "confirmed"])
        }
        XCTAssertEqual(write(phone, "save"), .success)
        let started = Date()
        XCTAssertEqual(write(pad, "snapshot"), .success) // Acknowledged while the save is still running.
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
        release.signal(); flush()
        XCTAssertEqual(replies[phone]?.last?["status"] as? String, "confirmed")
        XCTAssertEqual(replies[pad]?.last?["status"] as? String, "confirmed")
    }

    func testRequestThatWaitedPastTheDeadlineIsRefusedBeforeReachingUSB() {
        let phone = admitted(), pad = admitted()
        let release = DispatchSemaphore(value: 0)
        router.onMessage = { [unowned self] _, message in
            handled.append(message["operation"] as? String ?? "")
            if message["operation"] as? String == "save" { release.wait() }
            return PeripheralReply(message: ["version": 1, "id": message["id"] ?? "", "status": "confirmed"])
        }
        handled.removeAll()
        XCTAssertEqual(write(phone, "save"), .success)
        radio.sync {}; Thread.sleep(forTimeInterval: 0.05) // The save is executing.
        XCTAssertEqual(write(pad, "set_parameter"), .success)
        clock = CentralRouter.queueDeadline + 1
        release.signal(); flush()
        XCTAssertEqual(handled, ["save"])
        XCTAssertEqual(code(replies[pad]?.last), "busy")
        XCTAssertEqual(replies[pad]?.last?["applied"] as? Bool, false)
        XCTAssertEqual(replies[pad]?.last?["retry_after"] as? TimeInterval, 1)
        // A started request always completes.
        XCTAssertEqual(replies[phone]?.last?["status"] as? String, "confirmed")
    }

    func testQueuedRequestFromADeviceThatLeftNeverStarts() {
        let phone = admitted(), pad = admitted()
        let release = DispatchSemaphore(value: 0)
        router.onMessage = { [unowned self] _, message in
            handled.append(message["operation"] as? String ?? "")
            if message["operation"] as? String == "save" { release.wait() }
            return PeripheralReply(message: ["version": 1, "id": message["id"] ?? "", "status": "confirmed"])
        }
        handled.removeAll()
        XCTAssertEqual(write(phone, "save"), .success)
        radio.sync {}; Thread.sleep(forTimeInterval: 0.05) // The save holds the owner's queue.
        let answered = replies[pad]?.count
        XCTAssertEqual(write(pad, "set_parameter"), .success)
        radio.sync { router.unsubscribe(pad) }
        release.signal(); flush()
        XCTAssertEqual(handled, ["save"]) // The iPad's edit never reached USB.
        XCTAssertEqual(replies[pad]?.count, answered)
        XCTAssertEqual(left, [pad])
        XCTAssertEqual(replies[phone]?.last?["status"] as? String, "confirmed") // Started work finishes.
        // The same holds when Bluetooth or the bridge drops every device at once.
        router.onMessage = { [unowned self] _, message in
            handled.append(message["operation"] as? String ?? "")
            if message["operation"] as? String == "save" { release.wait() }
            return PeripheralReply(message: ["version": 1, "id": message["id"] ?? "", "status": "confirmed"])
        }
        let other = admitted()
        XCTAssertEqual(write(phone, "save"), .success)
        radio.sync {}; Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(write(other, "save"), .success)
        radio.sync { router.removeAll() }
        release.signal(); flush()
        XCTAssertEqual(handled.filter { $0 == "save" }.count, 2) // The phone's started save, not the other's.
    }

    func testSecondRequestFromTheSameDeviceIsRefusedNotQueued() {
        let phone = admitted()
        let release = DispatchSemaphore(value: 0)
        router.onMessage = { _, message in
            release.wait(); return PeripheralReply(message: ["version": 1, "id": message["id"] ?? "", "status": "confirmed"])
        }
        XCTAssertEqual(write(phone, "snapshot"), .success)
        XCTAssertEqual(write(phone, "save"), .success)
        radio.sync {}
        XCTAssertEqual(code(replies[phone]?.last), "busy")
        XCTAssertEqual(replies[phone]?.last?["applied"] as? Bool, false)
        release.signal(); flush()
        XCTAssertEqual(replies[phone]?.last?["status"] as? String, "confirmed")
    }

    func testUnadmittedDevicesAreBoundedAndMayOnlySayHello() {
        let first = UUID()
        radio.sync { router.subscribe(first, limit: 185) }
        XCTAssertEqual(write(first, "snapshot"), .success); flush()
        XCTAssertEqual(code(replies[first]?.last), "invalid_request")
        XCTAssertEqual(handled, [])
        // An unadmitted device can't send a large message.
        XCTAssertEqual(write(first, "hello", padding: CentralRouter.unadmittedMessageBytes), .failed)
        XCTAssertEqual(resets, 1) // It was the only device, so the service was reset too.
        // At most four unadmitted devices are tracked.
        let crowd = (0...CentralRouter.unadmittedLimit).map { _ in UUID() }
        radio.sync { crowd.forEach { router.subscribe($0, limit: 185) } }
        XCTAssertEqual(write(crowd.last!, "hello"), .notPermitted)
        // Idle unadmitted entries expire after ten seconds.
        clock = CentralRouter.unadmittedTimeout + 1
        XCTAssertEqual(write(crowd[0], "hello"), .notPermitted); flush()
        XCTAssertTrue(left.contains(crowd[0]))
        // Admitted devices accept full-size messages.
        let phone = admitted()
        XCTAssertEqual(write(phone, "snapshot", padding: 8000), .success); flush()
        XCTAssertEqual(handled.last, "snapshot")
    }

    func testReleasedDeviceIsAnsweredThenDropped() {
        let pad = UUID()
        router.onMessage = { _, message in
            PeripheralReply(message: ["version": 1, "id": message["id"] ?? "", "status": "error", "error": ["code": "bridge_full"]], admission: .release)
        }
        radio.sync { router.subscribe(pad, limit: 185) }
        XCTAssertEqual(write(pad, "hello"), .success); flush()
        XCTAssertEqual(code(replies[pad]?.last), "bridge_full")
        XCTAssertEqual(left, [pad])
        XCTAssertEqual(write(pad, "hello"), .notPermitted)
    }

    func testInvalidTransferResetsOnlyThatDevice() {
        let phone = admitted(), pad = admitted()
        XCTAssertEqual(radio.sync { router.write(pad, Data([9, 9])) }, .failed); flush()
        XCTAssertEqual(left, [pad]); XCTAssertEqual(resets, 0)
        XCTAssertEqual(write(phone, "snapshot"), .success); flush()
        XCTAssertEqual(replies[phone]?.last?["status"] as? String, "confirmed")
        XCTAssertEqual(write(pad, "snapshot"), .success); flush() // Starts over, unadmitted.
        XCTAssertEqual(code(replies[pad]?.last), "invalid_request")
        radio.sync { router.unsubscribe(pad) }
        // Alone, a failure also resets the service so the phone rediscovers it.
        XCTAssertEqual(radio.sync { router.write(phone, Data([9, 9])) }, .failed)
        XCTAssertEqual(resets, 1)
    }
}
