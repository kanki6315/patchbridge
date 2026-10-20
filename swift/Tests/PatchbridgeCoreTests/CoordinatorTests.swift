import XCTest
@testable import PatchbridgeCore

private final class OfflineTransport: DiscoverableEditorTransport {
    var onDiscovered: ((String, String) -> Void)?
    var autoReady = true
    var selectedPeripheral: String?
    func selectPeripheral(_ id: String) { selectedPeripheral = id; onReady?() }
    var onReady: (() -> Void)?
    var onDisconnected: (() -> Void)?
    var onStatus: ((String) -> Void)?
    var onResponse: (([String: Any]) -> Void)?
    var messages = [[String: Any]]()
    var handler: (([String: Any]) throws -> [String: Any])?
    var held: [String: Any]?
    var hold = false
    func reconnect() { if autoReady { onReady?() } }
    func disconnect() {}
    func send(_ message: [String: Any]) throws {
        messages.append(message)
        if let handler {
            let response = try handler(message)
            if hold { held = response } else { onResponse?(response) }
        }
    }
    func deliver() { let response = held; held = nil; if let response { onResponse?(response) } }
}

final class CoordinatorTests: XCTestCase {
    private var clock: TimeInterval = 0
    private func fixture() throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("tests/fixtures/qc-editor.json"))) as! [String: Any]
    }
    private func coordinator(_ transport: OfflineTransport) -> EditorCoordinator {
        EditorCoordinator(pollInterval: 2, timeout: 5, automaticPolling: false, now: { self.clock }, makeTransport: { transport })
    }
    private func reply(_ t: OfflineTransport, result: [String: Any], revision: Int = 0, session: String = "s") {
        t.onResponse?(["version": 1, "id": t.messages.last!["id"]!, "connection_id": "c", "session_id": session,
                       "revision": revision, "status": "confirmed", "result": result])
    }
    private func connect(_ c: EditorCoordinator, _ t: OfflineTransport, fixture f: [String: Any], catalog: Bool = true) {
        c.start()
        t.onResponse?(["version": 1, "id": t.messages.last!["id"]!, "connection_id": "c", "authorization_required": true])
        XCTAssertEqual(c.phase, .awaitingApproval)
        c.authorize(); reply(t, result: ["state": f["snapshot"]!])
        reply(t, result: ["protocol_version": 1, "operations": ["snapshot", "catalog", "set_parameter", "save"]])
        if catalog { reply(t, result: f["catalog"] as! [String: Any]) }
        XCTAssertEqual(c.phase, .ready)
    }
    func testBluetoothFailureRetainsActionableReason() {
        let t = OfflineTransport(); t.autoReady = false
        let c = coordinator(t); c.start()
        t.onStatus?("Bluetooth is off. Turn it on in Settings, then reconnect.")
        t.onDisconnected?()
        XCTAssertEqual(c.phase, .failed)
        XCTAssertTrue(c.error?.hasPrefix("Bluetooth is off") == true)
    }
    func testDiscoveryRequiresSelectionAndExpiresWhenNothingIsFound() {
        let t = OfflineTransport(); t.autoReady = false
        let c = coordinator(t)
        c.start(); XCTAssertTrue(t.messages.isEmpty)
        t.onDiscovered?("one", "Studio Mac"); t.onDiscovered?("two", "Laptop")
        XCTAssertEqual(c.nearbyMacs.count, 2)
        c.chooseMac("two")
        XCTAssertEqual(t.selectedPeripheral, "two")
        XCTAssertEqual(c.macName, "Laptop")
        XCTAssertEqual(t.messages.last?["operation"] as? String, "hello")
        c.disconnect(); c.start()
        clock = 31; c.tick()
        XCTAssertEqual(c.phase, .failed)
        XCTAssertTrue(c.error?.contains("No Mac replied") == true)
        c.disconnect(); XCTAssertNil(c.error); XCTAssertNil(c.outcome)
    }
    func testSaveOutcomeDoesNotLeakIntoNextSession() throws {
        let t = OfflineTransport(); let c = coordinator(t); let f = try fixture()
        connect(c, t, fixture: f)
        try c.save()
        var state = f["snapshot"] as! [String: Any]; state["dirty"] = false
        reply(t, result: ["state": state], revision: 1)
        XCTAssertEqual(c.outcome, "Saved on the QC")
        c.disconnect(); XCTAssertNil(c.outcome)
    }
    func testCapturedLoadAndBoundedPolling() throws {
        let t = OfflineTransport(); let c = coordinator(t); let f = try fixture()
        connect(c, t, fixture: f)
        XCTAssertEqual(c.editor.snapshot?.blocks.count, 16)
        XCTAssertNil(c.editor.readOnlyReason(blockID: "0:1", parameterID: "0"))
        let count = t.messages.count
        clock = 1; c.tick(); XCTAssertEqual(t.messages.count, count)
        clock = 2; c.tick(); XCTAssertEqual(t.messages.count, count + 1)
        c.tick(); c.refresh(); XCTAssertEqual(t.messages.count, count + 1)
        XCTAssertThrowsError(try c.save())
        var state = f["snapshot"] as! [String: Any]; state["scene"] = "A"
        reply(t, result: ["state": state], revision: 1)
        XCTAssertEqual(c.editor.snapshot?.scene, "A")
        XCTAssertEqual(c.outcome, "Changed on the QC")
        clock = 3; c.tick(); XCTAssertEqual(t.messages.count, count + 1)
        clock = 4; c.tick(); XCTAssertEqual(t.messages.count, count + 2)
        c.disconnect(); clock = 100; c.tick(); XCTAssertEqual(t.messages.count, count + 2)
    }
    func testCacheReuseAndCatalogChange() throws {
        let t = OfflineTransport(); let c = coordinator(t); let f = try fixture()
        connect(c, t, fixture: f); connect(c, t, fixture: f, catalog: false)
        XCTAssertEqual(t.messages.filter { $0["operation"] as? String == "catalog" }.count, 1)
        var state = f["snapshot"] as! [String: Any]; state["catalog_id"] = "new"
        c.refresh(); reply(t, result: ["state": state], revision: 1)
        XCTAssertEqual(c.phase, .loading); XCTAssertNil(c.editor.snapshot)
        XCTAssertEqual(t.messages.last?["operation"] as? String, "catalog")
        var catalog = f["catalog"] as! [String: Any]; catalog["id"] = "new"
        reply(t, result: catalog, revision: 1)
        XCTAssertEqual(c.editor.catalog?.id, "new"); XCTAssertEqual(c.phase, .ready)
    }
    func testUncertainEditTimeoutAndOldCallbackNeverReplay() throws {
        let t = OfflineTransport(); let c = coordinator(t); let f = try fixture()
        connect(c, t, fixture: f)
        let oldCallback = t.onResponse
        try c.edit(blockID: "0:1", parameterID: "0", value: .number(0.5))
        XCTAssertNotNil(c.editor.pending)
        let oldID = t.messages.last!["id"]!
        clock = 5; c.tick()
        XCTAssertEqual(c.phase, .failed); XCTAssertNil(c.editor.pending); XCTAssertNil(c.editor.snapshot)
        connect(c, t, fixture: f, catalog: false)
        oldCallback?(["version": 1, "id": oldID, "connection_id": "c", "session_id": "s", "revision": 99,
                      "status": "confirmed", "result": ["state": f["snapshot"]!]])
        XCTAssertEqual(c.phase, .ready)
        XCTAssertEqual(t.messages.filter { $0["operation"] as? String == "set_parameter" }.count, 1)
    }
    func testExplicitRejectionResyncsBeforeMoreEdits() throws {
        let t = OfflineTransport(); let c = coordinator(t); let f = try fixture(); connect(c, t, fixture: f)
        try c.edit(blockID: "0:1", parameterID: "0", value: .number(0.5))
        t.onResponse?(["version": 1, "id": t.messages.last!["id"]!, "connection_id": "c", "session_id": "s", "revision": 0,
                       "status": "error", "error": ["code": "stale_context", "message": "Physical edit occurred"]])
        XCTAssertEqual(c.phase, .loading); XCTAssertNil(c.editor.pending)
        XCTAssertEqual(t.messages.last?["operation"] as? String, "snapshot")
        XCTAssertThrowsError(try c.save())
        reply(t, result: ["state": f["snapshot"]!], revision: 1)
        XCTAssertEqual(c.phase, .ready); XCTAssertNotNil(c.error)
    }
    func testMalformedAndChangedSessionFailClosed() throws {
        for mode in ["session", "state", "revision", "version"] {
            let t = OfflineTransport(); let c = coordinator(t); let f = try fixture(); connect(c, t, fixture: f)
            c.refresh()
            var response: [String: Any] = ["version": 1, "id": t.messages.last!["id"]!, "connection_id": "c",
                "session_id": "s", "revision": 0, "status": "confirmed", "result": ["state": f["snapshot"]!]]
            if mode == "session" { response["session_id"] = "another" }
            if mode == "state" { response["result"] = [:] as [String: Any] }
            if mode == "revision" { response["revision"] = true }
            if mode == "version" { response["version"] = true }
            t.onResponse?(response)
            XCTAssertEqual(c.phase, .failed, mode); XCTAssertNil(c.editor.snapshot)
        }
    }
    func testCatalogMismatchAndReadOnlyCapabilities() throws {
        let t = OfflineTransport(); let c = coordinator(t); let f = try fixture()
        connect(c, t, fixture: f)
        var state = f["snapshot"] as! [String: Any]; state["catalog_id"] = "changed"
        c.refresh(); reply(t, result: ["state": state], revision: 1)
        reply(t, result: f["catalog"] as! [String: Any], revision: 1)
        XCTAssertEqual(c.phase, .failed)
        c.start(); t.onResponse?(["version": 1, "id": t.messages.last!["id"]!, "connection_id": "c", "authorization_required": true])
        c.authorize(); reply(t, result: ["state": f["snapshot"]!])
        reply(t, result: ["protocol_version": 1, "operations": ["snapshot", "catalog"]])
        reply(t, result: f["catalog"] as! [String: Any])
        XCTAssertEqual(c.phase, .ready); XCTAssertThrowsError(try c.save())
        XCTAssertThrowsError(try c.edit(blockID: "0:1", parameterID: "0", value: .number(0.5)))
    }
    func testNewModelInSameCatalogFetchesSubsetAndUnknownStaysReadOnly() throws {
        let t = OfflineTransport(); let c = coordinator(t); let f = try fixture(); connect(c, t, fixture: f)
        var state = f["snapshot"] as! [String: Any]
        var blocks = state["blocks"] as! [[String: Any]]; blocks[0]["model_id"] = "unrecognized"
        state["blocks"] = blocks
        c.refresh(); reply(t, result: ["state": state], revision: 1)
        XCTAssertEqual(c.phase, .loading)
        let payload = t.messages.last!["payload"] as! [String: Any]
        XCTAssertTrue((payload["model_ids"] as! [String]).contains("unrecognized"))
        reply(t, result: f["catalog"] as! [String: Any], revision: 1)
        XCTAssertEqual(c.phase, .ready)
        XCTAssertNotNil(c.editor.readOnlyReason(blockID: blocks[0]["id"] as! String, parameterID: "0"))
        let count = t.messages.count
        c.refresh(); reply(t, result: ["state": state], revision: 1)
        XCTAssertEqual(t.messages.count, count + 1) // Missing definition is cached as missing.
    }
    func testApprovalRetryAndUnsolicitedResponse() throws {
        let t = OfflineTransport(); let c = coordinator(t)
        c.start()
        t.onResponse?(["version": 1, "id": "unsolicited"])
        XCTAssertTrue(c.busy); XCTAssertEqual(c.phase, .connecting)
        t.onResponse?(["version": 1, "id": t.messages.last!["id"]!, "connection_id": "c", "authorization_required": true])
        c.authorize()
        t.onResponse?(["version": 1, "id": t.messages.last!["id"]!, "connection_id": "c", "status": "error", "error": "unauthorized"])
        XCTAssertEqual(c.phase, .awaitingApproval); XCTAssertFalse(c.busy)
        c.authorize(); XCTAssertEqual(t.messages.last?["operation"] as? String, "connect")
        t.onDisconnected?(); XCTAssertEqual(c.phase, .failed)
    }
    func testChangedCatalogAtSameRevisionIsRejected() throws {
        let t = OfflineTransport(); let c = coordinator(t); let f = try fixture(); connect(c, t, fixture: f)
        var state = f["snapshot"] as! [String: Any]; state["catalog_id"] = "changed"
        c.refresh(); reply(t, result: ["state": state])
        XCTAssertEqual(c.phase, .failed)
    }
    func testRealSimulatedProcessEditSaveAndHelperCrash() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var helper = try HelperClient(python: "/opt/homebrew/bin/python3", source: root.appendingPathComponent("src").path)
        defer { helper.stop() }
        var bridge = BridgeSession(helper: helper); bridge.approve()
        func roundTrip(_ object: [String: Any]) throws -> [String: Any] {
            let data = try JSONSerialization.data(withJSONObject: object)
            var receiver = ChunkReceiver(); var complete: Data?
            for packet in try Chunks.split(data, limit: 20, transfer: 1) { complete = try receiver.receive(packet) }
            return try JSONSerialization.jsonObject(with: XCTUnwrap(complete)) as! [String: Any]
        }
        let t = OfflineTransport(); t.handler = { try roundTrip(bridge.handle(roundTrip($0))) }
        let c = coordinator(t); c.start(); c.authorize()
        XCTAssertEqual(c.phase, .ready)
        XCTAssertEqual(c.editor.value(blockID: "amp-1", parameterID: "gain"), .number(5))
        t.hold = true
        try c.edit(blockID: "amp-1", parameterID: "gain", value: .number(7.5))
        XCTAssertEqual(c.editor.value(blockID: "amp-1", parameterID: "gain"), .number(5))
        XCTAssertNotNil(c.editor.pending)
        t.hold = false; t.deliver()
        XCTAssertEqual(c.editor.value(blockID: "amp-1", parameterID: "gain"), .number(7.5))
        XCTAssertEqual(c.editor.snapshot?.dirty, true)
        try c.save(); XCTAssertEqual(c.editor.snapshot?.dirty, false)
        bridge.revoke(); bridge.approve(); c.start(); c.authorize()
        XCTAssertEqual(c.phase, .ready)
        XCTAssertEqual(c.editor.value(blockID: "amp-1", parameterID: "gain"), .number(7.5))
        helper.stop(); c.refresh()
        XCTAssertEqual(c.phase, .failed); XCTAssertNil(c.editor.snapshot)
        helper = try HelperClient(python: "/opt/homebrew/bin/python3", source: root.appendingPathComponent("src").path)
        bridge = BridgeSession(helper: helper); bridge.approve()
        c.start(); c.authorize()
        XCTAssertEqual(c.phase, .ready)
        XCTAssertEqual(c.editor.value(blockID: "amp-1", parameterID: "gain"), .number(5))
        XCTAssertEqual(t.messages.filter { $0["operation"] as? String == "set_parameter" }.count, 1)
    }
}


extension CoordinatorTests {
    private func exerciseCapturedRecovery(bundled: Bool) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixtureURL = directory.appendingPathComponent("captured.json")
        let original = try fixture()
        func write(_ document: [String: Any]) throws {
            try JSONSerialization.data(withJSONObject: document).write(to: fixtureURL, options: .atomic)
        }
        try write(original)
        func launch() throws -> HelperClient {
            if bundled {
                let app = try XCTUnwrap(Bundle(url: root.appendingPathComponent("dist/Patchbridge Offline.app")))
                return try HelperClient(bundle: app, capturedFixture: fixtureURL)
            }
            return try HelperClient(python: "/opt/homebrew/bin/python3", source: root.appendingPathComponent("src").path, capturedFixture: fixtureURL)
        }
        var helper = try launch(); defer { helper.stop() }
        var bridge = BridgeSession(helper: helper, requestTimeout: 0.5)
        bridge.approve()
        let t = OfflineTransport()
        t.handler = { message in
            func wire(_ value: [String: Any]) throws -> [String: Any] {
                var receiver = ChunkReceiver(); var complete: Data?
                for packet in try Chunks.split(JSONSerialization.data(withJSONObject: value), limit: 20, transfer: 1) {
                    complete = try receiver.receive(packet)
                }
                return try JSONSerialization.jsonObject(with: XCTUnwrap(complete)) as! [String: Any]
            }
            return try wire(bridge.handle(wire(message)))
        }
        let c = coordinator(t); c.start(); c.authorize()
        XCTAssertEqual(c.phase, .ready)
        XCTAssertEqual(c.editor.snapshot?.blocks.count, 16)
        XCTAssertNotNil(c.editor.readOnlyReason(blockID: "0:1", parameterID: "0"))
        XCTAssertThrowsError(try c.edit(blockID: "0:1", parameterID: "0", value: .number(0.5)))
        XCTAssertThrowsError(try c.save())
        // A forged caller bypassing the generic model cannot write at the bridge.
        for operation in ["set_parameter", "save", "save_as", "select_scene", "select_preset", "set_bypass", "recall_preset_save"] {
            XCTAssertThrowsError(try bridge.handle(["version": 1, "id": UUID().uuidString,
                "operation": operation, "connection_id": bridge.token])) { error in
                guard case BridgeFailure.readOnly = error else { return XCTFail("Wrong error: \(error)") }
            }
        }
        var changed = original
        var state = changed["snapshot"] as! [String: Any]
        state["preset_id"] = "captured:another"; state["name"] = "Physical preset change"; state["scene"] = "A"
        changed["snapshot"] = state; try write(changed)
        clock += 2; c.tick()
        XCTAssertEqual(c.editor.snapshot?.preset_id, "captured:another")
        XCTAssertEqual(c.editor.snapshot?.scene, "A")
        XCTAssertEqual(c.outcome, "Changed on the QC")
        for fault in ["disconnect", "crash", "slow"] {
            var broken = original; broken["offline_fault"] = fault; try write(broken)
            let staleResponse = t.onResponse
            c.refresh()
            XCTAssertEqual(c.phase, .failed, fault); XCTAssertNil(c.editor.snapshot); XCTAssertNil(c.editor.pending)
            helper.stop(); try write(original)
            helper = try launch(); bridge = BridgeSession(helper: helper, requestTimeout: 0.5); bridge.approve()
            c.start(); c.authorize()
            XCTAssertEqual(c.phase, .ready, fault)
            XCTAssertEqual(c.editor.snapshot?.scene, "F")
            staleResponse?(["version": 1, "id": "stale", "status": "confirmed"])
            XCTAssertEqual(c.phase, .ready)
        }
        XCTAssertTrue(t.messages.allSatisfy { !["save", "set_parameter"].contains($0["operation"] as? String ?? "") })
        c.disconnect()
    }
    func testCapturedReadOnlyProcessRecovery() throws { try exerciseCapturedRecovery(bundled: false) }
    func testBundledCapturedReadOnlyRecovery() throws {
        guard ProcessInfo.processInfo.environment["PATCHBRIDGE_TEST_BUNDLE"] == "1" else {
            throw XCTSkip("Run with PATCHBRIDGE_TEST_BUNDLE=1 after packaging to exercise the bundled runtime")
        }
        try exerciseCapturedRecovery(bundled: true)
    }
}
