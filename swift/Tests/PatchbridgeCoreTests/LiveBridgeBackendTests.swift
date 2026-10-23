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

extension OfflineBridgeBackend {
    /// Acts on the card currently shown, as a click does at that moment.
    func approvePending(trust: Bool = false) throws {
        guard let id = presentation.pendingID, let connection = presentation.pendingConnection else { throw BridgeFailure.disconnected }
        try approve(device: id, connection: connection, trust: trust)
    }
    func denyPending() {
        guard let id = presentation.pendingID, let connection = presentation.pendingConnection else { return }
        deny(device: id, connection: connection)
    }
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
        try host.approvePending(); XCTAssertEqual(host.state?.0, .approving)
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
        XCTAssertEqual(host.presentation.preset, "Simulation 1") // The bridge keeps the QC open with no device.
        let next = phone.send("hello")
        XCTAssertNotEqual(next["connection_id"] as? String, token)
        XCTAssertEqual(host.presentation.phoneName, "iPhone")
        XCTAssertEqual((phone.send("connect", token: token)["error"] as? [String: Any])?["code"] as? String, "unauthorized")
    }
    func testBridgeReadsTheQCItselfAndAnswersEveryDeviceFromOneRead() throws {
        let log = Diagnostics()
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let helper = try HelperClient(python: "/opt/homebrew/bin/python3", source: root.appendingPathComponent("src").path, diagnostics: log)
        let phone = TestPeripheral(), pad = UUID()
        var time = 10.0
        let host = LiveBridgeBackend(peripheral: phone, makeHelper: { helper }, now: { time })
        defer { host.stop() }
        try host.start()
        func reads() throws -> Int {
            let report = try JSONSerialization.jsonObject(with: log.reportData()) as! [String: Any]
            return (report["events"] as! [[String: Any]]).filter { $0["event"] as? String == "requestStarted" && ["connect", "snapshot"].contains($0["operation"] as? String) }.count
        }
        // No device yet: the bridge opens USB and reads the QC on its own.
        host.tick()
        XCTAssertEqual(host.presentation.preset, "Simulation 1"); XCTAssertEqual(try reads(), 1)
        host.tick(); XCTAssertEqual(try reads(), 1, "Not due yet")
        func joined(_ id: UUID, _ name: String) throws -> (token: String, reply: [String: Any]) {
            let token = try XCTUnwrap(phone.send("hello", from: id, fields: ["device_name": name])["connection_id"] as? String)
            try host.approvePending()
            return (token, phone.send("connect", from: id, token: token))
        }
        let first = try joined(phone.device, "iPhone"), second = try joined(pad, "iPad")
        let session = try XCTUnwrap(first.reply["session_id"] as? String)
        XCTAssertEqual(second.reply["session_id"] as? String, session)
        XCTAssertNotNil((second.reply["result"] as? [String: Any])?["device"] as? [String: Any])
        // Both devices poll; neither poll reaches USB, and one that already holds the state gets "unchanged".
        let revision = try XCTUnwrap(first.reply["revision"] as? Int)
        let full = phone.send("snapshot", token: first.token, session: session)
        XCTAssertNotNil((full["result"] as? [String: Any])?["state"])
        let same = phone.send("snapshot", from: pad, token: second.token, session: session, fields: ["payload": ["known_revision": revision]])
        XCTAssertEqual((same["result"] as? [String: Any])?["unchanged"] as? Bool, true)
        XCTAssertEqual(try reads(), 1)
        // The bridge's next read refreshes what every device sees; an edit's state does too.
        time += SharedUSBSession.pollInterval; host.tick(); XCTAssertEqual(try reads(), 2)
        let edit: [String: Any] = ["revision": revision, "preset_id": "1", "scene": "A", "payload": ["block_id": "amp-1", "parameter_id": "gain", "value": 7.5]]
        XCTAssertEqual(phone.send("set_parameter", from: pad, token: second.token, session: session, fields: edit)["status"] as? String, "confirmed")
        let after = phone.send("snapshot", token: first.token, session: session, fields: ["payload": ["known_revision": revision]])
        XCTAssertEqual(after["revision"] as? Int, revision + 1); XCTAssertNotNil((after["result"] as? [String: Any])?["state"])
        XCTAssertEqual(after["changed_by"] as? String, "iPad")
        XCTAssertEqual(try reads(), 2)
        // Everyone leaving keeps the session; the bridge goes on reading.
        phone.leave(); phone.leave(pad)
        time += SharedUSBSession.pollInterval; host.tick(); XCTAssertEqual(try reads(), 3)
        XCTAssertEqual(host.state?.0, .running)
    }
    func testHelperFailurePreservesUnknownOutcomeAndRequiresNewApproval() throws {
        let helper = try helper(), phone = TestPeripheral()
        let host = LiveBridgeBackend(peripheral: phone, makeHelper: { helper })
        defer { host.stop() }
        try host.start()
        let token = try XCTUnwrap(phone.send("hello")["connection_id"] as? String)
        try host.approvePending()
        let session = try XCTUnwrap(phone.send("connect", token: token)["session_id"] as? String)
        helper.stop()
        _ = phone.send("set_parameter", token: token, session: session,
                       fields: ["revision": 0, "preset_id": "1", "scene": "A", "payload": ["block_id": "amp-1", "parameter_id": "gain", "value": 7.5]])
        XCTAssertEqual(host.state?.0, .failed)
        XCTAssertEqual(host.presentation.recentEdits.first?.outcome, .unknown)
        XCTAssertNil(phone.onMessage)
        XCTAssertTrue(host.presentation.approvalCode.isEmpty)
    }
    func testTrustSurvivesStopAndStart() throws {
        let phone = TestPeripheral()
        let host = LiveBridgeBackend(peripheral: phone, makeHelper: { try self.helper() })
        defer { host.stop() }
        try host.start()
        let token = try XCTUnwrap(phone.send("hello", fields: ["device_name": "iPhone"])["connection_id"] as? String)
        try host.approvePending(trust: true)
        let trustToken = try XCTUnwrap(phone.send("connect", token: token)["trust_token"] as? String)
        host.stop()
        XCTAssertEqual(host.state?.0, .stopped)
        try host.start()
        XCTAssertEqual(host.presentation.trusted.map(\.name), ["iPhone"])
        XCTAssertEqual(phone.send("hello", fields: ["device_name": "iPhone", "trust_token": trustToken])["authorization_required"] as? Bool, false)
    }
    func testBluetoothStatusAndDenialClearApproval() throws {
        let phone = TestPeripheral()
        let host = LiveBridgeBackend(peripheral: phone, makeHelper: helper)
        defer { host.stop() }
        try host.start(); phone.onStatus?("Bluetooth is off")
        XCTAssertEqual(host.state?.1, "Bluetooth is off")
        let token = try XCTUnwrap(phone.send("hello")["connection_id"] as? String)
        host.denyPending()
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
    func testDevicesQueueForApprovalConnectTogetherAndLeaveSeparately() throws {
        let helper = try helper(), phone = TestPeripheral(), pad = UUID()
        let host = LiveBridgeBackend(peripheral: phone, makeHelper: { helper })
        defer { host.stop() }
        try host.start()
        let phoneToken = try XCTUnwrap(phone.send("hello", fields: ["device_name": "iPhone"])["connection_id"] as? String)
        let padToken = try XCTUnwrap(phone.send("hello", from: pad, fields: ["device_name": "iPad"])["connection_id"] as? String)
        XCTAssertEqual(phone.lastAdmission, .admit)
        // One approval card at a time, earliest first.
        XCTAssertEqual(host.state?.0, .awaitingApproval)
        XCTAssertEqual(host.presentation.phoneName, "iPhone"); XCTAssertEqual(host.presentation.waiting, 1)
        XCTAssertEqual(host.presentation.approvalCode, DeviceIdentity.approvalCode(phoneToken))
        XCTAssertTrue(host.state?.1.contains("1 more waiting") == true)
        try host.approvePending(trust: true)
        XCTAssertEqual(host.presentation.phoneName, "iPad") // The next card.
        XCTAssertEqual(host.presentation.approvalCode, DeviceIdentity.approvalCode(padToken))
        let connected = phone.send("connect", token: phoneToken)
        let session = try XCTUnwrap(connected["session_id"] as? String)
        let trustToken = try XCTUnwrap(connected["trust_token"] as? String)
        XCTAssertEqual(host.state?.0, .awaitingApproval) // A waiting device still comes first.
        try host.approvePending()
        XCTAssertEqual(phone.send("connect", from: pad, token: padToken)["session_id"] as? String, session)
        XCTAssertEqual(host.state?.0, .connected)
        XCTAssertEqual(host.presentation.connected.map(\.name), ["iPhone", "iPad"])
        XCTAssertEqual(host.presentation.trusted.map(\.name), ["iPhone"])
        XCTAssertEqual(host.presentation.trusted.first?.connected, true)
        // Edits record which device sent them.
        let edit: [String: Any] = ["revision": 0, "preset_id": "1", "scene": "A", "payload": ["block_id": "amp-1", "parameter_id": "gain", "value": 7.5]]
        _ = phone.send("set_parameter", from: pad, token: padToken, session: session, fields: edit)
        XCTAssertEqual(host.presentation.recentEdits.first?.device, "iPad")

        // Disconnecting the iPhone on the Mac leaves the iPad editing.
        let iPhone = try XCTUnwrap(host.presentation.devices.first { $0.name == "iPhone" })
        host.disconnect(device: iPhone.id, connection: iPhone.connection)
        XCTAssertEqual(host.state?.0, .connected)
        XCTAssertEqual((phone.send("snapshot", token: phoneToken, session: session)["error"] as? [String: Any])?["code"] as? String, "revoked")
        XCTAssertEqual(phone.send("snapshot", from: pad, token: padToken, session: session)["status"] as? String, "confirmed")
        XCTAssertEqual(host.presentation.trusted.first?.connected, false) // Trust outlives the connection.
        // A trusted reconnect skips the card; revoking trust on the Mac ends that.
        let back = phone.send("hello", fields: ["device_name": "iPhone", "trust_token": trustToken])
        XCTAssertEqual(back["authorization_required"] as? Bool, false)
        XCTAssertEqual(host.presentation.devices.first { $0.name == "iPhone" }?.state, .approving)
        XCTAssertEqual(host.state?.0, .connected)
        let entry = try XCTUnwrap(host.presentation.trusted.first)
        XCTAssertTrue(entry.connected)
        host.revokeTrust(id: entry.id)
        XCTAssertTrue(host.presentation.trusted.isEmpty)
        let iPhoneAgain = try XCTUnwrap(host.presentation.devices.first { $0.name == "iPhone" })
        host.disconnect(device: iPhoneAgain.id, connection: iPhoneAgain.connection)
        XCTAssertEqual(phone.send("hello", fields: ["trust_token": trustToken])["authorization_required"] as? Bool, true)

        // Up to four devices; a fifth is told the bridge is full.
        for _ in 0..<2 { _ = phone.send("hello", from: UUID()) } // With the iPad and the iPhone again.
        XCTAssertEqual(host.presentation.devices.count, 4)
        let full = phone.send("hello", from: UUID())
        XCTAssertEqual((full["error"] as? [String: Any])?["code"] as? String, "bridge_full")
        XCTAssertEqual(phone.lastAdmission, .release)
        phone.leave(pad)
        XCTAssertEqual(host.presentation.devices.count, 3)
        XCTAssertEqual(host.state?.0, .awaitingApproval)
    }
    func testApprovalAppliesOnlyToTheConnectionOnTheCard() throws {
        let helper = try helper(), phone = TestPeripheral(), pad = UUID()
        let host = LiveBridgeBackend(peripheral: phone, makeHelper: { helper })
        defer { host.stop() }
        try host.start()
        let phoneToken = try XCTUnwrap(phone.send("hello", fields: ["device_name": "iPhone"])["connection_id"] as? String)
        let padToken = try XCTUnwrap(phone.send("hello", from: pad, fields: ["device_name": "iPad"])["connection_id"] as? String)
        // The card shows the iPhone; the click is captured with it.
        let shown = (id: try XCTUnwrap(host.presentation.pendingID), connection: try XCTUnwrap(host.presentation.pendingConnection))
        XCTAssertEqual(shown.connection, phoneToken)
        phone.leave() // The iPhone leaves before the worker runs the click.
        try host.approve(device: shown.id, connection: shown.connection, trust: true)
        XCTAssertEqual(host.state?.0, .awaitingApproval)
        XCTAssertEqual(host.presentation.pendingConnection, padToken) // The iPad's own card, still unanswered.
        XCTAssertEqual(host.presentation.devices.first?.state, .awaitingApproval)
        XCTAssertTrue(host.presentation.trusted.isEmpty)
        XCTAssertEqual((phone.send("connect", from: pad, token: padToken)["error"] as? [String: Any])?["code"] as? String, "unauthorized")
        host.deny(device: shown.id, connection: shown.connection) // A stale deny leaves the iPad alone too.
        XCTAssertEqual(host.presentation.devices.count, 1)

        // The same device back on a new connection is a different card.
        let iPad = try XCTUnwrap(host.presentation.devices.first)
        host.disconnect(device: iPad.id, connection: iPad.connection)
        let again = try XCTUnwrap(phone.send("hello", from: pad, fields: ["device_name": "iPad"])["connection_id"] as? String)
        XCTAssertNotEqual(again, padToken)
        try host.approve(device: pad, connection: padToken, trust: false)
        XCTAssertEqual(host.presentation.devices.first?.state, .awaitingApproval)
        host.disconnect(device: pad, connection: padToken)
        XCTAssertEqual(host.presentation.devices.count, 1)
        try host.approve(device: pad, connection: again, trust: false)
        XCTAssertEqual(host.presentation.devices.first?.state, .approving)
    }
}
