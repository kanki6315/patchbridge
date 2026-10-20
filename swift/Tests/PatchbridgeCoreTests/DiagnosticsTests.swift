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
