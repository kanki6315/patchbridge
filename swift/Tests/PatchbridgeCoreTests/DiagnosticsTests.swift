import XCTest
@testable import PatchbridgeCore

final class DiagnosticsTests: XCTestCase {
    func testBoundedAllowlistAndClear() throws {
        let log = Diagnostics(capacity: 3)
        for _ in 0..<10 { log.record(.requestRejected, operation: "PRIVATE PRESET", code: "/Users/private/file", duration: .infinity) }
        let data = try log.reportData()
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(object["droppedEvents"] as? Int, 7)
        XCTAssertEqual((object["events"] as? [Any])?.count, 3)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("PRIVATE PRESET")); XCTAssertFalse(text.contains("/Users/private"))
        XCTAssertTrue(text.contains("unknown"))
        log.clear()
        let empty = try JSONSerialization.jsonObject(with: log.reportData()) as! [String: Any]
        XCTAssertEqual((empty["events"] as? [Any])?.count, 0)
    }
    func testConcurrentRecordingAndPrivateAtomicExport() throws {
        let log = Diagnostics(capacity: 100)
        DispatchQueue.concurrentPerform(iterations: 1000) { _ in log.record(.requestConfirmed, operation: "snapshot") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("report.json")
        try log.export(to: destination); try log.export(to: destination)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as! [String: Any]
        XCTAssertEqual(object["droppedEvents"] as? Int, 900)
        XCTAssertEqual((object["events"] as? [Any])?.count, 100)
        XCTAssertEqual(object["presetContentsIncluded"] as? Bool, false)
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["report.json"])
        XCTAssertThrowsError(try log.export(to: directory.appendingPathComponent("missing/report.json")))
    }
    func testHelperAndBridgeReportNeverIncludesFixtureOrCommands() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let log = Diagnostics()
        let helper = try HelperClient(python: "/opt/homebrew/bin/python3", source: root.appendingPathComponent("src").path,
            capturedFixture: root.appendingPathComponent("tests/fixtures/qc-editor.json"), diagnostics: log)
        defer { helper.stop() }
        let bridge = DeviceSession(helper: helper); bridge.approve()
        let response = try bridge.handle(["version": 1, "id": "secret-request-id", "connection_id": bridge.token, "operation": "connect"])
        XCTAssertEqual(response["status"] as? String, "confirmed")
        XCTAssertThrowsError(try bridge.handle(["version": 1, "id": "secret-save-id", "connection_id": bridge.token,
            "operation": "save", "payload": ["name": "PRIVATE PRESET", "gain": 0.3577812612]]))
        bridge.revoke(); helper.stop()
        let text = String(decoding: try log.reportData(), as: UTF8.self)
        for secret in ["Tremonti", "PRIVATE PRESET", "0.357781", "secret-request-id", "secret-save-id", root.path,
                       response["session_id"] as! String, bridge.token, "qc-editor.json"] {
            XCTAssertFalse(text.contains(secret), secret)
        }
        XCTAssertTrue(text.contains("writeBlocked")); XCTAssertTrue(text.contains("read_only"))
        XCTAssertTrue(text.contains("helperStopped")); XCTAssertTrue(text.contains("requestConfirmed"))
    }
}


extension DiagnosticsTests {
    func testTimeoutRecordsCodeAndStopsHelperWithoutRecordingInput() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = directory.appendingPathComponent("SECRET-fixture.json")
        var document = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("tests/fixtures/qc-editor.json"))) as! [String: Any]
        try JSONSerialization.data(withJSONObject: document).write(to: fixture)
        let log = Diagnostics()
        let helper = try HelperClient(python: "/opt/homebrew/bin/python3", source: root.appendingPathComponent("src").path, capturedFixture: fixture, diagnostics: log)
        defer { helper.stop() }
        let connected = try helper.request(["operation": "connect"])
        document["offline_fault"] = "slow"
        try JSONSerialization.data(withJSONObject: document).write(to: fixture)
        XCTAssertThrowsError(try helper.request(["operation": "snapshot", "session_id": connected["session_id"]!], timeout: 0.1))
        let text = String(decoding: try log.reportData(), as: UTF8.self)
        XCTAssertTrue(text.contains("timeout")); XCTAssertTrue(text.contains("helperStopped"))
        XCTAssertTrue(text.contains("durationMilliseconds"))
        XCTAssertFalse(text.contains("SECRET")); XCTAssertFalse(text.contains("Tremonti"))
    }
}

extension DiagnosticsTests {
    private func events(_ log: Diagnostics) throws -> [[String: Any]] {
        let report = try JSONSerialization.jsonObject(with: log.reportData()) as! [String: Any]
        return report["events"] as! [[String: Any]]
    }
    func testDeviceNumbersAreBoundedAndOmittedWhenNotDeviceSpecific() throws {
        let log = Diagnostics()
        log.record(.helperStarted)
        log.record(.bridgeApproved, device: 2)
        log.record(.bridgeApproved, device: 0)
        log.record(.bridgeApproved, device: 10_000)
        let recorded = try events(log)
        XCTAssertNil(recorded[0]["device"]); XCTAssertEqual(recorded[1]["device"] as? Int, 2)
        XCTAssertNil(recorded[2]["device"]); XCTAssertNil(recorded[3]["device"])
    }
    func testBridgeTagsEachDevicesEventsWithoutIdentifyingIt() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let log = Diagnostics()
        let helper = try HelperClient(python: "/opt/homebrew/bin/python3", source: root.appendingPathComponent("src").path, diagnostics: log)
        defer { helper.stop() }
        let phone = TestPeripheral(), pad = UUID()
        let host = LiveBridgeBackend(peripheral: phone, makeHelper: { helper })
        defer { host.stop() }
        try host.start()
        let phoneToken = try XCTUnwrap(phone.send("hello", fields: ["device_name": "Jamie’s iPhone"])["connection_id"] as? String)
        try host.approvePending()
        let session = try XCTUnwrap(phone.send("connect", token: phoneToken)["session_id"] as? String)
        let padToken = try XCTUnwrap(phone.send("hello", from: pad, fields: ["device_name": "Jamie’s iPad"])["connection_id"] as? String)
        try host.approvePending()
        _ = phone.send("connect", from: pad, token: padToken)
        _ = phone.send("catalog", from: pad, token: padToken, session: session)
        for _ in 0..<3 { _ = phone.send("hello", from: UUID()) }
        _ = phone.send("hello", from: UUID()) // A fifth device.
        let iPhone = try XCTUnwrap(host.presentation.devices.first { $0.name == "Jamie’s iPhone" })
        host.disconnect(device: iPhone.id, connection: iPhone.connection)
        _ = phone.send("snapshot", token: phoneToken, session: session)

        let recorded = try events(log)
        func tagged(_ event: String, _ operation: String? = nil) -> [Int?] {
            recorded.filter { $0["event"] as? String == event && (operation == nil || $0["operation"] as? String == operation) }.map { $0["device"] as? Int }
        }
        XCTAssertEqual(tagged("bridgeApproved"), [1, 2])
        XCTAssertEqual(tagged("requestStarted", "connect"), [1]) // The iPad joined without a second connect.
        XCTAssertEqual(tagged("requestStarted", "identify"), []) // Its identity came from the bridge's own connect.
        XCTAssertTrue(tagged("requestStarted", "catalog").contains(2))
        XCTAssertTrue(recorded.contains { $0["code"] as? String == "bridge_full" && $0["device"] == nil })
        XCTAssertTrue(recorded.contains { $0["code"] as? String == "revoked" && $0["device"] as? Int == 1 })
        XCTAssertEqual(tagged("bridgeRevoked").first, 1)
        let text = String(decoding: try log.reportData(), as: UTF8.self)
        for secret in ["Jamie", phoneToken, padToken, session, pad.uuidString, phone.device.uuidString] {
            XCTAssertFalse(text.contains(secret), secret)
        }
    }
    func testBusyRefusalsAreRecorded() {
        let log = Diagnostics()
        let radio = DispatchQueue(label: "test.radio"), owner = DispatchQueue(label: "test.owner")
        let router = CentralRouter(radio: radio, owner: owner, diagnostics: log)
        let release = DispatchSemaphore(value: 0)
        router.send = { _, _ in true }
        router.onMessage = { _, message in
            if message["operation"] as? String == "snapshot" { release.wait() }
            return PeripheralReply(message: ["version": 1, "id": message["id"] ?? "", "status": "confirmed"], admission: message["operation"] as? String == "hello" ? .admit : .unchanged)
        }
        let id = UUID()
        func write(_ operation: String, _ transfer: UInt32) -> CentralRouter.WriteResult {
            let data = try! JSONSerialization.data(withJSONObject: ["version": 1, "id": UUID().uuidString, "operation": operation])
            return radio.sync { router.write(id, try! Chunks.split(data, limit: 185, transfer: transfer)[0]) }
        }
        radio.sync { router.subscribe(id, limit: 185) }
        _ = write("hello", 1); radio.sync {}; owner.sync {}; radio.sync {}
        _ = write("snapshot", 2); _ = write("save", 3)
        release.signal(); radio.sync {}; owner.sync {}; radio.sync {}
        let report = String(decoding: try! log.reportData(), as: UTF8.self)
        XCTAssertTrue(report.contains("\"busy\"")); XCTAssertTrue(report.contains("\"save\""))
    }
}
