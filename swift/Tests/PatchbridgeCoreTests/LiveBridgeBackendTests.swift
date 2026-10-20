import XCTest
@testable import PatchbridgeCore

final class TestPeripheral: BridgePeripheral {
    var onMessage: ((UUID, [String: Any]) -> PeripheralReply)?
    var onDisconnect: ((UUID) -> Void)?
    var onStatus: ((String) -> Void)?
    var starts = 0
    let device = UUID()
    private(set) var lastAdmission = PeripheralReply.Admission.unchanged
    func start(name: String) { starts += 1 }
    func stop() {}
    func send(_ operation: String, from id: UUID? = nil, token: String? = nil, session: String? = nil, fields: [String: Any] = [:]) -> [String: Any] {
        var request: [String: Any] = ["version": 1, "id": UUID().uuidString, "operation": operation]
        request["connection_id"] = token; request["session_id"] = session
        request.merge(fields) { _, new in new }
        guard let reply = onMessage?(id ?? device, request) else { return [:] }
        lastAdmission = reply.admission
        return reply.message
    }
    func leave(_ id: UUID? = nil) { onDisconnect?(id ?? device) }
}

final class LiveBridgeBackendTests: XCTestCase {
    private func helper() throws -> HelperClient {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try HelperClient(python: "/opt/homebrew/bin/python3", source: root.appendingPathComponent("src").path)
    }
    func testLiveHostApprovalIdentityEditsRecoveryAndDisconnectUsingSimulatorIO() throws {
        let helper = try helper(), phone = TestPeripheral()
        var time = 10.0
        let host = LiveBridgeBackend(peripheral: phone, makeHelper: { helper }, now: { time })
        defer { host.stop() }
        XCTAssertEqual(phone.starts, 0)
        try host.start(); XCTAssertEqual(phone.starts, 1)
        let hello = phone.send("hello", fields: ["device_name": "  Stage Phone\n  "])
        let token = try XCTUnwrap(hello["connection_id"] as? String)
        XCTAssertEqual(host.presentation.phoneName, "Stage Phone")
        XCTAssertEqual(host.presentation.approvalCode, DeviceIdentity.approvalCode(token))
        XCTAssertEqual(host.state?.0, .awaitingApproval)
        XCTAssertEqual((phone.send("connect", token: token)["error"] as? [String: Any])?["code"] as? String, "unauthorized")
        try host.approve(); XCTAssertEqual(host.state?.0, .approving)
        XCTAssertNil(host.presentation.preset) // Approval alone does not access USB.
        let connected = phone.send("connect", token: token)
        let session = try XCTUnwrap(connected["session_id"] as? String)
        XCTAssertEqual(host.state?.0, .connected)
        _ = phone.send("catalog", token: token, session: session)
        let edit: [String: Any] = ["revision": 0, "preset_id": "1", "scene": "A", "payload": ["block_id": "amp-1", "parameter_id": "gain", "value": 7.5]]
        XCTAssertEqual(phone.send("set_parameter", token: token, session: session, fields: edit)["status"] as? String, "confirmed")
        XCTAssertEqual(host.presentation.recentEdits.first?.outcome, .confirmed)
        XCTAssertEqual(host.presentation.recentEdits.first?.value, "7.5")
        _ = phone.send("set_parameter", token: token, session: session, fields: edit)
        XCTAssertEqual(host.presentation.recentEdits.first?.outcome, .rejected)
        // External device loss invalidates the helper session; the phone token survives.
        _ = try helper.request(["operation": "disconnect", "session_id": session])
        let lost = phone.send("snapshot", token: token, session: session)
        XCTAssertEqual((lost["error"] as? [String: Any])?["code"] as? String, "device_unavailable")
        XCTAssertEqual(host.state?.0, .recovering)
        XCTAssertEqual(host.presentation.approvalCode, DeviceIdentity.approvalCode(token))
        _ = phone.send("recover", token: token)
        XCTAssertEqual(host.state?.0, .recovering) // Backoff is honored.
        time += 2
        let recovered = phone.send("recover", token: token)
        XCTAssertEqual(recovered["status"] as? String, "confirmed")
        XCTAssertNotEqual(recovered["session_id"] as? String, session)
        XCTAssertEqual(host.state?.0, .connected)
        XCTAssertEqual(host.presentation.recentEdits.count, 2) // No mutation replay.
        phone.leave()
        XCTAssertEqual(host.state?.0, .running)
        XCTAssertNil(host.presentation.preset)
        let next = phone.send("hello")
        XCTAssertNotEqual(next["connection_id"] as? String, token)
        XCTAssertEqual(host.presentation.phoneName, "iPhone")
        XCTAssertEqual((phone.send("connect", token: token)["error"] as? [String: Any])?["code"] as? String, "unauthorized")
    }
    func testHelperFailurePreservesUnknownOutcomeAndRequiresNewApproval() throws {
        let helper = try helper(), phone = TestPeripheral()
        let host = LiveBridgeBackend(peripheral: phone, makeHelper: { helper })
        defer { host.stop() }
        try host.start()
        let token = try XCTUnwrap(phone.send("hello")["connection_id"] as? String)
        try host.approve()
        let session = try XCTUnwrap(phone.send("connect", token: token)["session_id"] as? String)
        helper.stop()
        _ = phone.send("set_parameter", token: token, session: session,
                       fields: ["revision": 0, "preset_id": "1", "scene": "A", "payload": ["block_id": "amp-1", "parameter_id": "gain", "value": 7.5]])
        XCTAssertEqual(host.state?.0, .failed)
        XCTAssertEqual(host.presentation.recentEdits.first?.outcome, .unknown)
        XCTAssertNil(phone.onMessage)
        XCTAssertTrue(host.presentation.approvalCode.isEmpty)
    }
    func testBluetoothStatusAndDenialClearApproval() throws {
        let phone = TestPeripheral()
        let host = LiveBridgeBackend(peripheral: phone, makeHelper: helper)
        defer { host.stop() }
        try host.start(); phone.onStatus?("Bluetooth is off")
        XCTAssertEqual(host.state?.1, "Bluetooth is off")
        let token = try XCTUnwrap(phone.send("hello")["connection_id"] as? String)
        host.revoke()
        XCTAssertEqual(host.state?.0, .running)
        XCTAssertTrue(host.presentation.approvalCode.isEmpty)
        // CoreBluetooth can't drop one central, so its requests are refused until it starts over.
        XCTAssertEqual((phone.send("connect", token: token)["error"] as? [String: Any])?["code"] as? String, "revoked")
        XCTAssertNotNil(phone.send("hello")["connection_id"] as? String)
        XCTAssertEqual(host.state?.0, .awaitingApproval)
    }
    func testLargeTransferUsesInactivityDeadline() throws {
        var receiver = ChunkReceiver()
        let bytes = Data(repeating: 42, count: 80)
        let chunks = try Chunks.split(bytes, limit: 28, transfer: 1)
        var result: Data?
        for (i, chunk) in chunks.enumerated() {
            result = try receiver.receive(chunk, now: Date(timeIntervalSince1970: Double(i * 3)))
        }
        XCTAssertEqual(result, bytes)
    }
    func testSecondDeviceIsToldTheBridgeIsFullAndTheFirstKeepsWorking() throws {
        let helper = try helper(), phone = TestPeripheral(), pad = UUID()
        let host = LiveBridgeBackend(peripheral: phone, makeHelper: { helper })
        defer { host.stop() }
        try host.start()
        let token = try XCTUnwrap(phone.send("hello", fields: ["device_name": "iPhone"])["connection_id"] as? String)
        XCTAssertEqual(phone.lastAdmission, .admit)
        try host.approve()
        let session = try XCTUnwrap(phone.send("connect", token: token)["session_id"] as? String)
        let full = phone.send("hello", from: pad, fields: ["device_name": "iPad"])
        XCTAssertEqual((full["error"] as? [String: Any])?["code"] as? String, "bridge_full")
        XCTAssertEqual(phone.lastAdmission, .release)
        XCTAssertEqual(host.presentation.phoneName, "iPhone")
        phone.leave(pad) // The refused device leaving never touches the admitted one.
        XCTAssertEqual(phone.send("snapshot", token: token, session: session)["status"] as? String, "confirmed")
        phone.leave()
        XCTAssertNotNil(phone.send("hello", from: pad)["connection_id"] as? String)
        XCTAssertEqual(phone.lastAdmission, .admit)
    }
}
