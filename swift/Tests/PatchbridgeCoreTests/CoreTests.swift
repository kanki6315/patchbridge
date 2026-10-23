import XCTest
@testable import PatchbridgeCore

final class CoreTests: XCTestCase {
    func testLargeSnapshotAtMinimumPayload() throws {
        let original = Data((0..<90000).map { UInt8($0 % 251) })
        var receiver = ChunkReceiver()
        var complete: Data?
        for chunk in try Chunks.split(original, limit: 20, transfer: 42) {
            XCTAssertLessThanOrEqual(chunk.count, 20)
            complete = try receiver.receive(chunk)
        }
        XCTAssertEqual(complete, original)
    }
    func testOutOfOrderAndExpiry() throws {
        let chunks = try Chunks.split(Data(repeating: 8, count: 40), limit: 20, transfer: 1)
        var receiver = ChunkReceiver()
        let now = Date()
        XCTAssertNil(try receiver.receive(chunks[0], now: now))
        XCTAssertThrowsError(try receiver.receive(chunks[2], now: now))
        XCTAssertNil(try receiver.receive(chunks[0], now: now))
        XCTAssertThrowsError(try receiver.receive(chunks[1], now: now.addingTimeInterval(6)))
    }
    func testDeflatedTransfer() throws {
        let original = Data(String(repeating: "{\"bypass\":false,\"parameters\":{\"0\":0.5}},", count: 400).utf8)
        let chunks = try Chunks.split(original, limit: 185, transfer: 7, deflate: true)
        XCTAssertEqual(chunks[0][0], 2)
        XCTAssertLessThan(chunks.count, original.count / 177 / 4, "Repetitive state shrinks severalfold")
        var receiver = ChunkReceiver(), complete: Data?
        for chunk in chunks { complete = try receiver.receive(chunk) }
        XCTAssertEqual(complete, original)
        // Small replies stay plain; a receiver never inflates past its limit.
        XCTAssertEqual(try Chunks.split(Data("{}".utf8), limit: 185, transfer: 8, deflate: true)[0][0], 1)
        var small = ChunkReceiver(limit: 4096)
        XCTAssertThrowsError(try chunks.forEach { _ = try small.receive($0) })
    }
    func testLimits() {
        XCTAssertThrowsError(try Chunks.split(Data(), limit: 8, transfer: 1))
        XCTAssertThrowsError(try Chunks.split(Data(count: 1_048_577), limit: 512, transfer: 1))
    }
    func testProcessAndAuthorization() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let helper = try HelperClient(python: "/opt/homebrew/bin/python3", source: root.appendingPathComponent("src").path)
        defer { helper.stop() }
        let session = DeviceSession(helper: helper)
        XCTAssertThrowsError(try session.handle(["version": 1, "id": UUID().uuidString, "operation": "connect", "connection_id": session.token]))
        session.approve()
        let old = session.token
        let connected = try session.handle(["version": 1, "id": "connect", "operation": "connect", "connection_id": old])
        XCTAssertEqual(connected["status"] as? String, "confirmed")
        session.revoke(); session.approve()
        XCTAssertThrowsError(try session.handle(["version": 1, "id": "stale", "operation": "snapshot", "connection_id": old]))
        let fresh = try session.handle(["version": 1, "id": UUID().uuidString, "operation": "connect", "connection_id": session.token])
        XCTAssertEqual(fresh["status"] as? String, "confirmed")
        XCTAssertNotEqual(connected["session_id"] as? String, fresh["session_id"] as? String)
    }
}

extension CoreTests {
    func testTimeoutInvalidatesProcess() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let package = directory.appendingPathComponent("patchbridge")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: package.appendingPathComponent("__init__.py"))
        try Data("import time\ntime.sleep(30)\n".utf8).write(to: package.appendingPathComponent("helper.py"))
        let helper = try HelperClient(python: "/opt/homebrew/bin/python3", source: directory.path)
        XCTAssertThrowsError(try helper.request(["operation": "connect"], timeout: 0.1))
        XCTAssertThrowsError(try helper.request(["operation": "connect"]))
        helper.stop()
    }
}

extension CoreTests {
    func testDuplicateCommandIDCannotReplayAnEdit() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let helper = try HelperClient(python: "/opt/homebrew/bin/python3", source: root.appendingPathComponent("src").path)
        defer { helper.stop() }
        let session = DeviceSession(helper: helper)
        session.approve()
        let connected = try session.handle(["version": 1, "id": "connect", "operation": "connect", "connection_id": session.token])
        let request: [String: Any] = ["version": 1, "id": "save-once", "operation": "save", "connection_id": session.token,
            "session_id": connected["session_id"]!, "revision": 0, "preset_id": "1", "scene": "A"]
        XCTAssertEqual(try session.handle(request)["status"] as? String, "confirmed")
        XCTAssertThrowsError(try session.handle(request))
        XCTAssertThrowsError(try session.handle(["version": true, "id": "bad", "operation": "hello"]))
    }
}

extension CoreTests {
    func testSimulatedSaveSceneAndReconnectThroughBridge() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let helper = try HelperClient(python: "/opt/homebrew/bin/python3", source: root.appendingPathComponent("src").path)
        defer { helper.stop() }
        let bridge = DeviceSession(helper: helper)
        bridge.approve()
        var response = try bridge.handle(["version": 1, "id": "connect", "operation": "connect", "connection_id": bridge.token])
        func request(_ operation: String, payload: [String: Any] = [:]) throws -> [String: Any] {
            let state = (response["result"] as! [String: Any])["state"] as! [String: Any]
            return try bridge.handle(["version": 1, "id": UUID().uuidString, "operation": operation,
                "connection_id": bridge.token, "session_id": response["session_id"]!, "revision": response["revision"]!,
                "preset_id": state["preset_id"]!, "scene": state["scene"]!, "payload": payload])
        }
        response = try request("set_parameter", payload: ["block_id": "amp-1", "parameter_id": "gain", "value": 7.5])
        XCTAssertEqual(response["status"] as? String, "confirmed")
        response = try request("save")
        response = try request("select_scene", payload: ["scene": "B"])
        response = try request("select_scene", payload: ["scene": "A"])
        response = try request("select_preset", payload: ["preset_id": "2"])
        response = try request("select_preset", payload: ["preset_id": "1"])
        let state = (response["result"] as! [String: Any])["state"] as! [String: Any]
        let amp = (state["blocks"] as! [[String: Any]])[0]
        let scenes = amp["scenes"] as! [String: [String: Any]]
        XCTAssertEqual((scenes["A"]!["parameters"] as! [String: Any])["gain"] as? Double, 7.5)
        XCTAssertEqual(state["dirty"] as? Bool, false)
        let staleSession = response["session_id"]!
        bridge.revoke(); bridge.approve()
        response = try bridge.handle(["version": 1, "id": "new-connect", "operation": "connect", "connection_id": bridge.token])
        let rejected = try bridge.handle(["version": 1, "id": "old-edit", "operation": "save", "connection_id": bridge.token,
            "session_id": staleSession, "revision": 0, "preset_id": "1", "scene": "A"])
        XCTAssertEqual((rejected["error"] as? [String: Any])?["code"] as? String, "stale_session")
    }
}
