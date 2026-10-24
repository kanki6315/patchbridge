import XCTest
@testable import PatchbridgeCore

final class SharedEditorResourcesTests: XCTestCase {
    private var time = 0.0
    private let log = Diagnostics(capacity: 1024)
    private func helper() throws -> HelperClient {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try HelperClient(python: "/opt/homebrew/bin/python3", source: root.appendingPathComponent("src").path, diagnostics: log)
    }
    private func reads(_ operation: String) throws -> Int {
        let report = try JSONSerialization.jsonObject(with: log.reportData()) as! [String: Any]
        return (report["events"] as! [[String: Any]]).filter {
            $0["event"] as? String == "requestStarted" && $0["operation"] as? String == operation
        }.count
    }
    private func warm(_ shared: SharedUSBSession) throws {
        for _ in 0..<3 { time += 0.2; try shared.refreshEditorResources() }
    }
    func testLiveBackendPreloadsAndRefreshesResourcesBeforeAnyClientHello() throws {
        let helper = try helper(), peripheral = TestPeripheral()
        let host = LiveBridgeBackend(peripheral: peripheral, makeHelper: { helper }, now: { self.time })
        try host.start(); defer { host.stop() }
        for _ in 0..<3 { host.tick(); time += 0.2 }
        XCTAssertTrue(host.presentation.devices.isEmpty)
        XCTAssertEqual(try reads("catalog"), 1)
        XCTAssertEqual(try reads("list_presets"), 1)
        time += SharedUSBSession.presetListInterval; host.tick()
        XCTAssertEqual(try reads("list_presets"), 2)
        XCTAssertEqual(host.state?.0, .running)
    }

    func testResourcesLoadWithoutClientsStayFreshAndReloadAfterRecovery() throws {
        let helper = try helper(); defer { helper.stop() }
        let shared = SharedUSBSession(helper: helper, allowsRecovery: true, keepsSession: true, now: { self.time })
        try shared.poll(); try warm(shared)
        XCTAssertTrue(shared.devices.isEmpty)
        XCTAssertEqual(shared.cachedCatalog?["id"] as? String, "sim-catalog-2")
        XCTAssertNotNil(shared.cachedPresets)
        XCTAssertEqual(try reads("catalog"), 1)
        XCTAssertEqual(try reads("list_presets"), 1)
        time += SharedUSBSession.presetListInterval
        try shared.refreshEditorResources()
        XCTAssertEqual(try reads("list_presets"), 2)
        XCTAssertEqual(try reads("catalog"), 1, "An unchanged catalog ID doesn't need another full read")
        let oldSession = shared.helperSession
        try shared.simulateDeviceRemoval()
        XCTAssertNil(shared.cachedCatalog); XCTAssertNil(shared.cachedPresets)
        time += 3; try shared.poll(); try warm(shared)
        XCTAssertNotEqual(shared.helperSession, oldSession)
        XCTAssertNotNil(shared.cachedCatalog); XCTAssertNotNil(shared.cachedPresets)
        XCTAssertEqual(try reads("catalog"), 2)
    }
    func testClientsShareFullCatalogAndDirectoryWithoutExtraHelperReads() throws {
        let helper = try helper(); defer { helper.stop() }
        let shared = SharedUSBSession(helper: helper, keepsSession: true, now: { self.time })
        try shared.poll(); try warm(shared)
        let session = try XCTUnwrap(shared.helperSession)
        for index in 0..<2 {
            let device = try XCTUnwrap(shared.admit()); device.approve()
            func send(_ operation: String, payload: Any = [String: Any]()) throws -> [String: Any] {
                try device.handle(["version": 1, "id": UUID().uuidString, "operation": operation,
                    "connection_id": device.token, "session_id": session, "payload": payload])
            }
            _ = try send("connect")
            let subset = try send("catalog", payload: ["model_ids": ["sim-amp"]])
            XCTAssertEqual(((subset["result"] as? [String: Any])?["models"] as? [String: Any])?.count, 1)
            let empty = try send("catalog", payload: ["model_ids": [String]()])
            XCTAssertEqual(((empty["result"] as? [String: Any])?["models"] as? [String: Any])?.count, 0)
            XCTAssertEqual((shared.cachedCatalog?["models"] as? [String: Any])?.count, 1)
            XCTAssertNotNil((try send("list_presets")["result"] as? [String: Any])?["presets"])
            XCTAssertEqual(try reads("catalog"), 1 + index) // Prior invalid requests reach the helper.
            XCTAssertEqual(try reads("list_presets"), 1)
            let invalid = try send("catalog", payload: ["model_ids": [1]])
            XCTAssertEqual((invalid["error"] as? [String: Any])?["code"] as? String, "invalid_request")
            shared.remove(device)
        }
    }
    func testExternalSaveAsIsObservedWithoutClients() throws {
        let helper = try helper(); defer { helper.stop() }
        let shared = SharedUSBSession(helper: helper, keepsSession: true, now: { self.time })
        try shared.poll(); try warm(shared)
        let session = try XCTUnwrap(shared.helperSession)
        // Bypass the shared session to model a change it must discover on its own.
        let saved = try helper.request(["operation": "save_as", "session_id": session, "revision": 0,
            "preset_id": "1", "scene": "A", "payload": ["preset_id": "2"]])
        XCTAssertEqual(saved["status"] as? String, "confirmed")
        time += SharedUSBSession.pollInterval; try shared.poll()
        XCTAssertNil(shared.cachedPresets)
        try shared.refreshEditorResources()
        let directory = shared.cachedPresets?.result["presets"] as? [String: Any]
        let entries = directory?["entries"] as? [[String: Any]]
        XCTAssertEqual(entries?.first { $0["preset_id"] as? String == "2" }?["name"] as? String, "Simulation 1")
        XCTAssertTrue(shared.devices.isEmpty)
    }

    func testSaveInvalidatesDirectoryAndHostRefreshesItWithoutAClient() throws {
        let helper = try helper(); defer { helper.stop() }
        let shared = SharedUSBSession(helper: helper, keepsSession: true, now: { self.time })
        try shared.poll(); try warm(shared)
        let session = try XCTUnwrap(shared.helperSession)
        let saved = try shared.forward(["operation": "save", "session_id": session, "revision": 0,
                                       "preset_id": "1", "scene": "A"])
        XCTAssertEqual(saved.response["status"] as? String, "confirmed")
        XCTAssertNil(shared.cachedPresets)
        time += 0.2; try shared.refreshEditorResources()
        XCTAssertNotNil(shared.cachedPresets)
        XCTAssertEqual(try reads("list_presets"), 2)
        XCTAssertTrue(shared.devices.isEmpty)
    }
}
