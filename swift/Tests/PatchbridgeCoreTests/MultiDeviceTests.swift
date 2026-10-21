import XCTest
@testable import PatchbridgeCore

final class MultiDeviceTests: XCTestCase {
    private var clock: TimeInterval = 0
    private func launch() throws -> HelperClient {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try HelperClient(python: "/opt/homebrew/bin/python3", source: root.appendingPathComponent("src").path)
    }
    private func send(_ device: DeviceSession, _ operation: String, _ fields: [String: Any] = [:]) throws -> [String: Any] {
        var message: [String: Any] = ["version": 1, "id": UUID().uuidString, "operation": operation, "connection_id": device.token]
        message.merge(fields) { $1 }
        return try device.handle(message)
    }
    /// Admits, approves and connects a device, returning its connect reply.
    private func join(_ shared: SharedUSBSession, name: String, trusting: Bool = false) throws -> (DeviceSession, [String: Any]) {
        let device = try XCTUnwrap(shared.admit())
        _ = try send(device, "hello", ["device_name": name]); device.approve(trusting: trusting)
        return (device, try send(device, "connect"))
    }
    private func edit(_ device: DeviceSession, session: Any, revision: Any, value: Double) throws -> [String: Any] {
        try send(device, "set_parameter", ["session_id": session, "revision": revision, "preset_id": "1", "scene": "A",
                                           "payload": ["block_id": "amp-1", "parameter_id": "gain", "value": value]])
    }
    private func code(_ reply: [String: Any]) -> String? { (reply["error"] as? [String: Any])?["code"] as? String }

    func testDevicesShareOneHelperSessionAndTheRevisionGuardSettlesConflicts() throws {
        let helper = try launch(); defer { helper.stop() }
        let shared = SharedUSBSession(helper: helper)
        let (phone, first) = try join(shared, name: "iPhone")
        let (pad, second) = try join(shared, name: "iPad")
        // The helper allows one session; a forwarded second connect would fail with already_connected.
        XCTAssertEqual(second["status"] as? String, "confirmed")
        XCTAssertEqual(second["session_id"] as? String, first["session_id"] as? String)
        XCTAssertNotNil((second["result"] as? [String: Any])?["device"] as? [String: Any])
        XCTAssertEqual(second["connection_id"] as? String, pad.token)
        let session = try XCTUnwrap(first["session_id"])
        let revision = try XCTUnwrap(second["revision"])
        XCTAssertEqual(try edit(phone, session: session, revision: revision, value: 7)["status"] as? String, "confirmed")
        let late = try edit(pad, session: session, revision: revision, value: 3)
        XCTAssertEqual(code(late), "stale_context")
    }

    func testHelperSessionClosesOnlyWhenTheLastDeviceLeaves() throws {
        let helper = try launch(); defer { helper.stop() }
        let shared = SharedUSBSession(helper: helper)
        let (phone, first) = try join(shared, name: "iPhone")
        let (pad, _) = try join(shared, name: "iPad")
        let session = try XCTUnwrap(first["session_id"])
        shared.remove(phone)
        XCTAssertEqual(try send(pad, "snapshot", ["session_id": session])["status"] as? String, "confirmed")
        XCTAssertThrowsError(try send(phone, "snapshot", ["session_id": session]))
        XCTAssertEqual(try send(pad, "disconnect", ["session_id": session])["status"] as? String, "confirmed")
        XCTAssertNil(shared.helperSession)
        let (_, fresh) = try join(shared, name: "iPhone")
        XCTAssertNotEqual(fresh["session_id"] as? String, first["session_id"] as? String)
    }

    func testDeviceLimitAndBridgeFullReply() throws {
        let helper = try launch(); defer { helper.stop() }
        let shared = SharedUSBSession(helper: helper)
        let admitted = (0..<shared.deviceLimit).compactMap { _ in shared.admit() }
        XCTAssertEqual(admitted.count, 4)
        XCTAssertNil(shared.admit())
        let full = shared.bridgeFullReply(["id": "h", "operation": "hello"])
        XCTAssertEqual(code(full), "bridge_full"); XCTAssertEqual(full["id"] as? String, "h")
        shared.remove(admitted[0])
        XCTAssertNotNil(shared.admit())
    }

    func testDeviceReturningAfterAnotherRecoveredIsRoutedThroughRecovery() throws {
        let helper = try launch(); defer { helper.stop() }
        let shared = SharedUSBSession(helper: helper, allowsRecovery: true, now: { self.clock })
        var edits: [(String, [String: Any]?)] = []
        shared.onMutation = { name, _, response in edits.append((name, response)) }
        let (phone, first) = try join(shared, name: "iPhone")
        let (pad, _) = try join(shared, name: "iPad")
        let old = try XCTUnwrap(first["session_id"])
        try phone.simulateDeviceRemoval()
        XCTAssertEqual(code(try send(phone, "snapshot", ["session_id": old])), "device_unavailable")
        clock = 2
        let recovered = try send(phone, "recover")
        XCTAssertEqual(recovered["status"] as? String, "confirmed")
        let current = try XCTUnwrap(recovered["session_id"] as? String)
        XCTAssertNotEqual(current, old as? String)

        // The iPad was backgrounded throughout and still holds the old session.
        let stale = try edit(pad, session: old, revision: 0, value: 9)
        XCTAssertEqual(code(stale), "device_unavailable")
        XCTAssertEqual(stale["retry_after"] as? TimeInterval, 0)
        XCTAssertEqual(stale["applied"] as? Bool, false)
        XCTAssertEqual(edits.last?.0, "iPad"); XCTAssertEqual(edits.last?.1?["applied"] as? Bool, false)
        let read = try send(pad, "snapshot", ["session_id": old])
        XCTAssertEqual(code(read), "device_unavailable"); XCTAssertNil(read["applied"])
        // Capabilities would carry the new session the iPad hasn't adopted.
        XCTAssertEqual(code(try send(pad, "capabilities", ["session_id": old])), "device_unavailable")
        // Recovery adopts the iPhone's session without a second helper connect.
        let adopted = try send(pad, "recover")
        XCTAssertEqual(adopted["status"] as? String, "confirmed")
        XCTAssertEqual(adopted["session_id"] as? String, current)
        XCTAssertEqual(try send(pad, "snapshot", ["session_id": current])["status"] as? String, "confirmed")
        // A current device has nothing to recover.
        XCTAssertThrowsError(try send(pad, "recover"))
    }

    func testDeviceFirstConnectingDuringAnOutageJoinsAfterAnotherRecovers() throws {
        let helper = try launch(); defer { helper.stop() }
        let shared = SharedUSBSession(helper: helper, allowsRecovery: true, now: { self.clock })
        let (phone, _) = try join(shared, name: "iPhone")
        try phone.simulateDeviceRemoval()
        let pad = try XCTUnwrap(shared.admit())
        _ = try send(pad, "hello", ["device_name": "iPad"]); pad.approve()
        XCTAssertEqual(code(try send(pad, "connect")), "device_unavailable")
        clock = 2
        let recovered = try send(phone, "recover")
        let adopted = try send(pad, "recover")
        XCTAssertEqual(adopted["status"] as? String, "confirmed")
        XCTAssertEqual(adopted["session_id"] as? String, recovered["session_id"] as? String)
    }

    func testDisconnectedDeviceCannotUseTheSessionAnotherKeepsOpen() throws {
        let helper = try launch(); defer { helper.stop() }
        let shared = SharedUSBSession(helper: helper)
        var edits: [[String: Any]?] = []
        shared.onMutation = { _, _, response in edits.append(response) }
        let (phone, first) = try join(shared, name: "iPhone")
        let (pad, _) = try join(shared, name: "iPad")
        let session = try XCTUnwrap(first["session_id"])
        let revision = try XCTUnwrap(first["revision"])
        XCTAssertEqual(try send(phone, "disconnect", ["session_id": session])["status"] as? String, "confirmed")
        let refused = try edit(phone, session: session, revision: revision, value: 9)
        XCTAssertEqual(code(refused), "disconnected"); XCTAssertEqual(refused["applied"] as? Bool, false)
        XCTAssertEqual(edits.last??["applied"] as? Bool, false)
        XCTAssertEqual(code(try send(phone, "snapshot", ["session_id": session])), "disconnected")
        // The edit never reached the helper: the iPad's revision still applies.
        XCTAssertEqual(try edit(pad, session: session, revision: revision, value: 6)["status"] as? String, "confirmed")
        // Never-connected devices are refused the same way.
        let fresh = try XCTUnwrap(shared.admit())
        _ = try send(fresh, "hello"); fresh.approve()
        XCTAssertEqual(code(try send(fresh, "snapshot", ["session_id": session])), "disconnected")
    }

    func testTrustOutlivesTheDeviceSessionWithoutTakingASlot() throws {
        let helper = try launch(); defer { helper.stop() }
        let shared = SharedUSBSession(helper: helper)
        let (pad, connected) = try join(shared, name: "iPad", trusting: true)
        let token = try XCTUnwrap(connected["trust_token"] as? String)
        shared.remove(pad)
        XCTAssertEqual(shared.trust.names, ["iPad"])

        let fillers = (0..<shared.deviceLimit).compactMap { _ in shared.admit() }
        XCTAssertEqual(fillers.count, 4) // The trust entry reserves no slot.
        XCTAssertNil(shared.admit())
        fillers.forEach(shared.remove)

        let returning = try XCTUnwrap(shared.admit())
        let hello = try send(returning, "hello", ["device_name": "Studio iPad", "trust_token": token])
        XCTAssertEqual(hello["authorization_required"] as? Bool, false)
        XCTAssertEqual(try send(returning, "connect")["trust_token"] as? String, token)
        XCTAssertEqual(returning.trustedPhoneName, "Studio iPad")

        returning.revokeTrust(); shared.remove(returning)
        let refused = try XCTUnwrap(shared.admit())
        XCTAssertEqual(try send(refused, "hello", ["trust_token": token])["authorization_required"] as? Bool, true)
        XCTAssertThrowsError(try send(refused, "connect"))
    }

    func testHelperFailureEndsEveryDeviceButKeepsTrust() throws {
        let helper = try launch(); defer { helper.stop() }
        let shared = SharedUSBSession(helper: helper)
        let (phone, first) = try join(shared, name: "iPhone", trusting: true)
        let token = try XCTUnwrap(first["trust_token"] as? String)
        let (pad, _) = try join(shared, name: "iPad")
        let session = try XCTUnwrap(first["session_id"])
        helper.stop()
        XCTAssertThrowsError(try send(phone, "snapshot", ["session_id": session]))
        XCTAssertThrowsError(try send(pad, "snapshot", ["session_id": session])) { error in
            guard case BridgeFailure.unauthorized = error else { return XCTFail("Wrong error: \(error)") }
        }
        XCTAssertEqual(shared.trust.names, ["iPhone"])
        // The phone's next hello is trusted again; only its connection ended.
        XCTAssertEqual(try send(phone, "hello", ["device_name": "iPhone", "trust_token": token])["authorization_required"] as? Bool, false)
    }

    func testStoredTrustSurvivesANewRegistryAndRevokeClearsIt() throws {
        final class Memory: TrustStorage {
            var data: Data?
            func load() -> Data? { data }
            func save(_ data: Data?) { self.data = data }
        }
        let storage = Memory()
        let helper = try launch(); defer { helper.stop() }
        let first = SharedUSBSession(helper: helper, trust: TrustRegistry(storage: storage))
        let (pad, connected) = try join(first, name: "iPad", trusting: true)
        let token = try XCTUnwrap(connected["trust_token"] as? String)
        first.remove(pad)
        XCTAssertNotNil(storage.data)

        // As after quitting and reopening Patchbridge: a fresh registry loads the entry.
        let reopened = TrustRegistry(storage: storage)
        XCTAssertEqual(reopened.names, ["iPad"])
        let second = SharedUSBSession(helper: helper, trust: reopened)
        let returning = try XCTUnwrap(second.admit())
        XCTAssertEqual(try send(returning, "hello", ["device_name": "Studio iPad", "trust_token": token])["authorization_required"] as? Bool, false)
        XCTAssertEqual(TrustRegistry(storage: storage).names, ["Studio iPad"]) // Renames are kept too.

        second.revokeTrust(id: try XCTUnwrap(returning.trustEntryID))
        XCTAssertNil(storage.data)
        XCTAssertTrue(TrustRegistry(storage: storage).names.isEmpty)
    }
}
