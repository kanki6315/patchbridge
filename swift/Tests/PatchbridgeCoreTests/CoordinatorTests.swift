import XCTest
import CoreBluetooth
@testable import PatchbridgeCore

private final class OfflineTransport: DiscoverableEditorTransport {
    var disconnectionReason: String?
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
    var disconnectCount = 0
    func reconnect() { if autoReady { onReady?() } }
    func disconnect() { disconnectCount += 1 }
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
    private func connect(_ c: EditorCoordinator, _ t: OfflineTransport, fixture f: [String: Any], catalog: Bool = true,
                         operations: [String] = ["snapshot", "catalog", "set_parameter", "save"]) {
        c.start()
        t.onResponse?(["version": 1, "id": t.messages.last!["id"]!, "connection_id": "c", "authorization_required": true])
        XCTAssertEqual(c.phase, .awaitingApproval)
        c.authorize(); reply(t, result: ["state": f["snapshot"]!])
        reply(t, result: ["protocol_version": 1, "operations": operations])
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
    func testTransportFailureSurvivesTeardownAndClearsOnReconnect() {
        let t = OfflineTransport(); t.autoReady = false
        let c = coordinator(t); c.start()
        t.onStatus?("Connecting to Mac…")
        t.disconnectionReason = "Could not enable Bluetooth responses: Insufficient authentication."
        let staleDisconnect = t.onDisconnected
        t.onDisconnected?()
        XCTAssertEqual(c.phase, .failed)
        XCTAssertEqual(c.error, t.disconnectionReason)
        XCTAssertFalse(c.busy)
        XCTAssertTrue(t.messages.isEmpty)
        t.disconnectionReason = nil; c.start()
        staleDisconnect?()
        XCTAssertEqual(c.phase, .connecting)
        XCTAssertNil(c.error)
    }
    func testBluetoothFailuresUseRecoveryCopyWithoutSystemDetails() {
        let fallback = "Your Mac couldn’t respond. Restart Patchbridge on your Mac, then reconnect."
        for code in [CBError.Code.connectionFailed, .connectionTimeout, .peripheralDisconnected,
                     .peerRemovedPairingInformation, .encryptionTimedOut] {
            let error = NSError(domain: CBErrorDomain, code: code.rawValue,
                                userInfo: [NSLocalizedDescriptionKey: "INTERNAL SYSTEM DETAIL"])
            let message = BLECentral.failureMessage(fallback, error: error)
            XCTAssertFalse(message.contains("CBErrorDomain"))
            XCTAssertFalse(message.contains("INTERNAL SYSTEM DETAIL"))
            XCTAssertTrue(message.contains("reconnect"))
            if code == .encryptionTimedOut {
                XCTAssertTrue(message.contains("pairing needs to be reset"))
                XCTAssertTrue(message.contains("phone and Mac"))
                XCTAssertTrue(message.contains("forget the pairing"))
            }
            if code == .peerRemovedPairingInformation { XCTAssertTrue(message.contains("forget the old pairing")) }
        }
        for error in [nil, NSError(domain: CBErrorDomain, code: 999),
                      NSError(domain: "PrivateDomain", code: 15)] {
            XCTAssertEqual(BLECentral.failureMessage(fallback, error: error), fallback)
        }
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
    func testAppSwitchPreservesSessionAndRefreshesOnReturn() throws {
        let t = OfflineTransport(); let c = coordinator(t); let f = try fixture()
        connect(c, t, fixture: f)
        let count = t.messages.count
        c.setBackgrounded(true)
        clock = 300; c.tick()
        XCTAssertEqual(c.phase, .ready)
        XCTAssertNotNil(c.editor.snapshot)
        XCTAssertEqual(t.disconnectCount, 0)
        XCTAssertEqual(t.messages.count, count)
        c.setBackgrounded(false)
        XCTAssertEqual(t.messages.count, count + 1)
        XCTAssertEqual(t.messages.last?["operation"] as? String, "snapshot")
        XCTAssertEqual(t.messages.last?["connection_id"] as? String, "c")
        XCTAssertEqual(t.messages.last?["session_id"] as? String, "s")
        XCTAssertThrowsError(try c.save())
        c.setBackgrounded(false); c.tick()
        XCTAssertEqual(t.messages.count, count + 1)
        reply(t, result: ["state": f["snapshot"]!])
        XCTAssertEqual(c.phase, .ready)
        XCTAssertFalse(c.busy)
    }
    func testBackgroundRequestCanFinishWithoutStartingMorePolls() throws {
        let t = OfflineTransport(); let c = coordinator(t); let f = try fixture()
        connect(c, t, fixture: f)
        try c.save()
        c.setBackgrounded(true)
        var state = f["snapshot"] as! [String: Any]; state["dirty"] = false
        reply(t, result: ["state": state], revision: 1)
        let count = t.messages.count
        clock = 300; c.tick()
        XCTAssertEqual(c.phase, .ready)
        XCTAssertEqual(c.outcome, "Saved on the QC")
        XCTAssertEqual(t.messages.count, count)
        c.setBackgrounded(false)
        XCTAssertEqual(t.messages.last?["operation"] as? String, "snapshot")
    }
    func testAppSwitchDoesNotReplayTimedOutSaveOrReconnectAfterDisconnect() throws {
        let t = OfflineTransport(); let c = coordinator(t); let f = try fixture()
        connect(c, t, fixture: f)
        try c.save()
        c.setBackgrounded(true)
        clock = 300
        c.setBackgrounded(false)
        XCTAssertEqual(c.phase, .failed)
        XCTAssertTrue(c.error?.contains("outcome is unknown") == true)
        XCTAssertEqual(t.messages.filter { $0["operation"] as? String == "save" }.count, 1)
        let count = t.messages.count
        c.setBackgrounded(true); c.disconnect(); c.setBackgrounded(false)
        XCTAssertEqual(c.phase, .disconnected)
        XCTAssertEqual(t.messages.count, count)
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
        var bridge = DeviceSession(helper: helper); bridge.approve()
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
        bridge = DeviceSession(helper: helper); bridge.approve()
        c.start(); c.authorize()
        XCTAssertEqual(c.phase, .ready)
        XCTAssertEqual(c.editor.value(blockID: "amp-1", parameterID: "gain"), .number(5))
        XCTAssertEqual(t.messages.filter { $0["operation"] as? String == "set_parameter" }.count, 1)
    }
    func testRealSimulatedProcessBypassesAndReenablesABlock() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let helper = try HelperClient(python: "/opt/homebrew/bin/python3", source: root.appendingPathComponent("src").path)
        defer { helper.stop() }
        let bridge = DeviceSession(helper: helper); bridge.approve()
        let t = OfflineTransport(); t.handler = { try bridge.handle($0) }
        let c = coordinator(t); c.start(); c.authorize()
        XCTAssertEqual(c.phase, .ready)
        XCTAssertEqual(c.editor.bypassed(blockID: "amp-1"), false)
        t.hold = true
        try c.setBypass(blockID: "amp-1", bypassed: true)
        XCTAssertEqual(c.editor.bypassed(blockID: "amp-1"), false)
        XCTAssertEqual(c.editor.pending?.operation, "set_bypass")
        t.hold = false; t.deliver()
        XCTAssertEqual(c.editor.bypassed(blockID: "amp-1"), true)
        XCTAssertEqual(c.outcome, "Bypassed")
        XCTAssertEqual(c.editor.snapshot?.dirty, true)
        try c.setBypass(blockID: "amp-1", bypassed: false)
        XCTAssertEqual(c.editor.bypassed(blockID: "amp-1"), false)
        XCTAssertEqual(c.outcome, "Enabled")
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
                let app = try XCTUnwrap(Bundle(url: root.appendingPathComponent("dist/Patchbridge.app")))
                return try HelperClient(bundle: app, capturedFixture: fixtureURL)
            }
            return try HelperClient(python: "/opt/homebrew/bin/python3", source: root.appendingPathComponent("src").path, capturedFixture: fixtureURL)
        }
        var helper = try launch(); defer { helper.stop() }
        var bridge = DeviceSession(helper: helper, requestTimeout: 0.5)
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
            helper = try launch(); bridge = DeviceSession(helper: helper, requestTimeout: 0.5); bridge.approve()
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

extension CoordinatorTests {
    func testDeviceRecoveryKeepsPhoneApprovalButNeverReplaysAnEdit() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let helper = try HelperClient(python: "/opt/homebrew/bin/python3", source: root.appendingPathComponent("src").path)
        defer { helper.stop() }
        let bridge = DeviceSession(helper: helper, allowsRecovery: true, macName: "Studio Mac", now: { self.clock })
        let t = OfflineTransport(); t.handler = { try bridge.handle($0) }
        let c = EditorCoordinator(automaticPolling: false, phoneName: "Jamie’s iPhone", now: { self.clock }, makeTransport: { t })
        c.start()
        XCTAssertEqual(c.macName, bridge.macName); XCTAssertEqual(bridge.phoneName, "Jamie’s iPhone")
        XCTAssertEqual(c.approvalCode, bridge.approvalCode)
        bridge.approve(); c.authorize(); XCTAssertEqual(c.phase, .ready)
        let token = bridge.token
        try bridge.simulateDeviceRemoval()
        try c.edit(blockID: "amp-1", parameterID: "gain", value: .number(8))
        XCTAssertEqual(c.phase, .recovering); XCTAssertNil(c.editor.snapshot); XCTAssertNil(c.editor.pending)
        XCTAssertTrue(c.error?.contains("unknown") == true)
        XCTAssertThrowsError(try c.save())
        clock = 1; c.tick(); XCTAssertEqual(c.phase, .recovering)
        clock = 2; c.tick(); XCTAssertEqual(c.phase, .ready)
        XCTAssertEqual(bridge.token, token); XCTAssertEqual(c.editor.value(blockID: "amp-1", parameterID: "gain"), .number(5))
        XCTAssertEqual(t.messages.filter { $0["operation"] as? String == "set_parameter" }.count, 1)
        XCTAssertTrue(c.error?.contains("unknown") == true) // Reload is not proof of the write's outcome.
        let original = try XCTUnwrap(t.messages.first { $0["operation"] as? String == "set_parameter" })
        XCTAssertThrowsError(try bridge.handle(original)) // Duplicate request cannot be replayed after recovery.
        bridge.revoke()
        XCTAssertThrowsError(try bridge.handle(["version": 1, "id": "late", "operation": "recover", "connection_id": token]))
    }

    func testCapturedDeviceRecoveryRetriesWithBackoffAndReloadsChangedState() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        var document = try fixture()
        func write() throws { try JSONSerialization.data(withJSONObject: document).write(to: file, options: .atomic) }
        try write()
        let helper = try HelperClient(python: "/opt/homebrew/bin/python3", source: root.appendingPathComponent("src").path, capturedFixture: file)
        defer { helper.stop() }
        let bridge = DeviceSession(helper: helper, allowsRecovery: true, now: { self.clock })
        let t = OfflineTransport(); t.handler = { try bridge.handle($0) }
        let c = coordinator(t); c.start(); bridge.approve(); c.authorize()
        document["offline_fault"] = "disconnect"; try write()
        c.refresh(); XCTAssertEqual(c.phase, .recovering)
        clock = 1; c.tick(); XCTAssertEqual(c.phase, .recovering)
        let count = t.messages.count
        clock = 2; c.tick(); XCTAssertEqual(t.messages.count, count)
        document.removeValue(forKey: "offline_fault")
        var state = document["snapshot"] as! [String: Any]; state["scene"] = "A"; document["snapshot"] = state; try write()
        clock = 3; c.tick(); XCTAssertEqual(c.phase, .ready)
        XCTAssertEqual(c.editor.snapshot?.scene, "A")
        XCTAssertThrowsError(try c.save()) // Read-only capabilities survive recovery.
        helper.stop(); c.refresh(); XCTAssertEqual(c.phase, .failed) // A dead helper is not USB recovery.
    }

    func testDisplayIdentityFallbackAndSanitization() {
        XCTAssertEqual(DeviceIdentity.name(" \n", fallback: "iPhone"), "iPhone")
        XCTAssertEqual(DeviceIdentity.name("Jamie\u{202E}\n", fallback: "iPhone"), "Jamie")
        XCTAssertEqual(DeviceIdentity.name(String(repeating: "x", count: 500), fallback: "Mac").count, 64)
        XCTAssertEqual(DeviceIdentity.approvalCode("abcdef12-3456"), "ABC·DEF")
    }
    func testTrustedReconnectSkipsApprovalUntilRevoked() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let helper = try HelperClient(python: "/opt/homebrew/bin/python3", source: root.appendingPathComponent("src").path)
        defer { helper.stop() }
        let bridge = DeviceSession(helper: helper)
        let t = OfflineTransport(); t.autoReady = false; t.handler = { try bridge.handle($0) }
        let c = coordinator(t)
        c.start(); t.onDiscovered?("mac", "Studio Mac"); c.chooseMac("mac")
        XCTAssertEqual(c.phase, .awaitingApproval); XCTAssertNil(t.messages.last?["trust_token"])
        bridge.approve(trusting: true); c.authorize()
        XCTAssertEqual(c.phase, .ready); XCTAssertTrue(c.trusted); XCTAssertNotNil(c.trustTokens["mac"])
        XCTAssertNotNil(bridge.trustedPhoneName)

        // The phone left; Reconnect finds the same Mac and skips the code.
        bridge.revoke(); c.start(reconnecting: true)
        XCTAssertEqual(c.macName, bridge.macName)
        t.onDiscovered?("mac", "Studio Mac")
        XCTAssertEqual(c.phase, .ready); XCTAssertTrue(c.trusted); XCTAssertNil(c.approvalCode)

        // A fresh start forgets the last Mac but keeps its token for when it is chosen again.
        bridge.revoke(); c.start(); t.onDiscovered?("mac", "Studio Mac")
        XCTAssertEqual(c.phase, .connecting)
        c.chooseMac("mac"); XCTAssertEqual(c.phase, .ready)

        // Revoking trust keeps the Mac's current connection rules but the next hello needs approval.
        bridge.revokeTrust(); bridge.revoke(); c.start(reconnecting: true); t.onDiscovered?("mac", "Studio Mac")
        XCTAssertEqual(c.phase, .awaitingApproval); XCTAssertFalse(c.trusted); XCTAssertNil(c.trustTokens["mac"])
        bridge.approve(); c.authorize()
        XCTAssertEqual(c.phase, .ready); XCTAssertFalse(c.trusted); XCTAssertNil(c.trustTokens["mac"])
    }
    func testForgedTrustTokenStillRequiresApproval() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let helper = try HelperClient(python: "/opt/homebrew/bin/python3", source: root.appendingPathComponent("src").path)
        defer { helper.stop() }
        let bridge = DeviceSession(helper: helper)
        bridge.approve(trusting: true); bridge.revoke()
        let hello = try bridge.handle(["version": 1, "id": "h", "operation": "hello", "trust_token": "guess"])
        XCTAssertEqual(hello["authorization_required"] as? Bool, true)
        XCTAssertThrowsError(try bridge.handle(["version": 1, "id": "c", "operation": "connect", "connection_id": bridge.token]))
    }
}

extension CoordinatorTests {
    private func simulatorHelper() throws -> HelperClient {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try HelperClient(python: "/opt/homebrew/bin/python3", source: root.appendingPathComponent("src").path)
    }
    /// A coordinator connected through a real device session on a shared bridge.
    private func joined(_ shared: SharedUSBSession, name: String, intercept: (([String: Any]) -> [String: Any]?)? = nil) throws -> (EditorCoordinator, OfflineTransport) {
        let device = try XCTUnwrap(shared.admit())
        let t = OfflineTransport(); t.handler = { message in try intercept?(message) ?? device.handle(message) }
        let c = EditorCoordinator(automaticPolling: false, phoneName: name, now: { self.clock }, makeTransport: { t })
        c.start(); device.approve(); c.authorize()
        XCTAssertEqual(c.phase, .ready)
        return (c, t)
    }

    func testBridgeFullAndMacDisconnectExplainThemselves() throws {
        let t = OfflineTransport(); let c = coordinator(t); c.start()
        t.onResponse?(["version": 1, "id": t.messages.last!["id"]!, "status": "error",
                       "error": ["code": "bridge_full", "message": "This Mac is already connected to 4 devices."]])
        XCTAssertEqual(c.phase, .failed); XCTAssertEqual(c.failure, .bridgeFull)
        XCTAssertEqual(c.error, "This Mac is already connected to 4 devices. Disconnect one on the Mac, then try again.")

        connect(c, t, fixture: try fixture())
        XCTAssertNil(c.failure)
        c.refresh()
        t.onResponse?(["version": 1, "id": t.messages.last!["id"]!, "connection_id": "c", "status": "error",
                       "error": ["code": "revoked", "message": "This device was disconnected on the Mac."]])
        XCTAssertEqual(c.phase, .failed); XCTAssertEqual(c.failure, .revoked)
        XCTAssertNil(c.editor.snapshot)
    }

    func testBusyBridgeRejectsEditsAndRetriesReadsLater() throws {
        let helper = try simulatorHelper(); defer { helper.stop() }
        var busy: Set<String> = []
        let shared = SharedUSBSession(helper: helper)
        let intercept: ([String: Any]) -> [String: Any]? = { message in
            guard let operation = message["operation"] as? String, busy.remove(operation) != nil else { return nil }
            return CentralRouter.busyReply(message)
        }
        let (c, t) = try joined(shared, name: "iPhone", intercept: intercept)
        // An edit refused for being busy never reached the QC: not applied, value unchanged.
        busy = ["set_parameter"]
        try c.edit(blockID: "amp-1", parameterID: "gain", value: .number(7.5))
        XCTAssertEqual(c.phase, .ready); XCTAssertNil(c.editor.pending)
        XCTAssertEqual(c.error, "Not applied. The bridge was busy with another device; try again.")
        XCTAssertEqual(c.editor.value(blockID: "amp-1", parameterID: "gain"), .number(5))
        // A busy read waits for retry_after instead of failing.
        busy = ["snapshot"]
        let sent = t.messages.count
        c.refresh(); XCTAssertEqual(c.phase, .ready)
        clock += 0.9; c.tick(); XCTAssertEqual(t.messages.count, sent + 1)
        clock += 0.2; c.tick(); XCTAssertEqual(t.messages.count, sent + 2)
        XCTAssertEqual(t.messages.last?["operation"] as? String, "snapshot")
        // A busy loading step is retried, and loading completes.
        c.disconnect(); busy = ["capabilities"]
        let (again, retried) = try { () throws -> (EditorCoordinator, OfflineTransport) in
            let device = try XCTUnwrap(shared.admit())
            let t2 = OfflineTransport(); t2.handler = { message in try intercept(message) ?? device.handle(message) }
            let c2 = EditorCoordinator(automaticPolling: false, phoneName: "iPad", now: { self.clock }, makeTransport: { t2 })
            c2.start(); device.approve(); c2.authorize()
            return (c2, t2)
        }()
        XCTAssertEqual(again.phase, .loading)
        clock += 1.1; again.tick()
        XCTAssertEqual(again.phase, .ready)
        XCTAssertEqual(retried.messages.filter { $0["operation"] as? String == "capabilities" }.count, 2)
    }

    func testEditTheBridgeNeverSentSaysNotApplied() throws {
        let helper = try simulatorHelper(); defer { helper.stop() }
        let shared = SharedUSBSession(helper: helper)
        var token = ""
        let (c, _) = try joined(shared, name: "iPhone") { message in
            token = message["connection_id"] as? String ?? token
            guard message["operation"] as? String == "set_parameter" else { return nil }
            return ["version": 1, "id": message["id"]!, "connection_id": token, "status": "error", "retry_after": 0, "applied": false,
                    "error": ["code": "device_unavailable", "message": "QC unavailable."]]
        }
        try c.edit(blockID: "amp-1", parameterID: "gain", value: .number(7.5))
        XCTAssertEqual(c.phase, .recovering)
        XCTAssertEqual(c.error, "Edit not applied. Editing resumes after the QC reconnects.")
    }

    func testChangesFromAnotherDeviceAreAttributedToIt() throws {
        let helper = try simulatorHelper(); defer { helper.stop() }
        let shared = SharedUSBSession(helper: helper)
        let (phone, _) = try joined(shared, name: "iPhone")
        let (pad, _) = try joined(shared, name: "Studio iPad")
        try pad.edit(blockID: "amp-1", parameterID: "gain", value: .number(7.5))
        XCTAssertEqual(pad.outcome, "Confirmed")
        phone.refresh()
        XCTAssertEqual(phone.outcome, "Changed on Studio iPad")
        XCTAssertEqual(phone.editor.value(blockID: "amp-1", parameterID: "gain"), .number(7.5))
        // The iPhone edits from state the iPad has since changed.
        try pad.edit(blockID: "amp-1", parameterID: "gain", value: .number(6))
        try phone.edit(blockID: "amp-1", parameterID: "gain", value: .number(3))
        XCTAssertEqual(phone.error, "Not applied. Studio iPad changed it first.")
        XCTAssertEqual(phone.phase, .ready)
        XCTAssertEqual(phone.outcome, "Changed on Studio iPad")
        XCTAssertEqual(phone.editor.value(blockID: "amp-1", parameterID: "gain"), .number(6))
        // The device's own edits are never attributed to someone else.
        try phone.edit(blockID: "amp-1", parameterID: "gain", value: .number(4))
        pad.refresh()
        XCTAssertEqual(pad.outcome, "Changed on iPhone")
        phone.refresh()
        XCTAssertNotEqual(phone.outcome, "Changed on iPhone")
    }

    // MARK: Scene switching

    private func sceneState(_ f: [String: Any], _ scene: String) -> [String: Any] {
        var state = f["snapshot"] as! [String: Any]; state["scene"] = scene; return state
    }
    private func refuse(_ t: OfflineTransport, _ code: String, session: String = "s") {
        t.onResponse?(["version": 1, "id": t.messages.last!["id"]!, "connection_id": "c", "session_id": session,
                       "revision": 1, "status": "error", "error": ["code": code, "message": code]])
    }
    private func sceneSwitching() throws -> (EditorCoordinator, OfflineTransport, [String: Any]) {
        let f = try fixture(), t = OfflineTransport(), c = coordinator(t)
        connect(c, t, fixture: f, operations: ["snapshot", "catalog", "set_parameter", "select_scene", "save"])
        return (c, t, f)
    }

    func testSceneSwitchIsHiddenUntilTheBridgeAdvertisesIt() throws {
        let f = try fixture(), t = OfflineTransport(), c = coordinator(t)
        connect(c, t, fixture: f)
        XCTAssertFalse(c.sceneSwitchAvailable)
        XCTAssertThrowsError(try c.selectScene("B"))
        XCTAssertEqual(t.messages.last?["operation"] as? String, "catalog")
    }

    func testSceneSwitchConfirmsOnlyAfterTheQCRepliesAndKeepsDirty() throws {
        let (c, t, f) = try sceneSwitching()
        XCTAssertTrue(c.sceneSwitchAvailable)
        try c.selectScene("B")
        XCTAssertEqual(t.messages.last?["operation"] as? String, "select_scene")
        XCTAssertEqual((t.messages.last?["payload"] as? [String: Any])?["scene"] as? String, "B")
        XCTAssertEqual(t.messages.last?["scene"] as? String, "F")
        XCTAssertEqual(c.sceneSwitch, .pending("B"))
        XCTAssertEqual(c.editor.snapshot?.scene, "F", "the strip keeps the QC's scene until it confirms")
        reply(t, result: ["state": sceneState(f, "B")], revision: 1)
        XCTAssertEqual(c.editor.snapshot?.scene, "B")
        XCTAssertEqual(c.editor.snapshot?.dirty, true)
        XCTAssertEqual(c.sceneSwitch, .confirmed("B"))
        XCTAssertNil(c.error); XCTAssertEqual(c.phase, .ready)
        clock += 2; c.tick()
        XCTAssertNil(c.sceneSwitch)
    }

    func testNewerTapReplacesTheSwitchStillWaiting() throws {
        let (c, t, f) = try sceneSwitching()
        try c.selectScene("B")
        try c.selectScene("D")
        try c.selectScene("A")
        XCTAssertEqual(c.sceneSwitch, .pending("A"))
        XCTAssertEqual(t.messages.filter { $0["operation"] as? String == "select_scene" }.count, 1)
        reply(t, result: ["state": sceneState(f, "B")], revision: 1)
        XCTAssertEqual(c.editor.snapshot?.scene, "B")
        XCTAssertEqual(c.sceneSwitch, .pending("A"))
        XCTAssertEqual((t.messages.last?["payload"] as? [String: Any])?["scene"] as? String, "A")
        XCTAssertEqual(t.messages.last?["revision"] as? Int, 1)
        reply(t, result: ["state": sceneState(f, "A")], revision: 2)
        XCTAssertEqual(c.sceneSwitch, .confirmed("A"))
    }

    func testBusyQCLeavesTheSceneAndTheSession() throws {
        let (c, t, _) = try sceneSwitching()
        try c.selectScene("D")
        refuse(t, "device_busy")
        XCTAssertEqual(c.sceneSwitch, .notApplied("D"))
        XCTAssertEqual(c.phase, .ready)
        XCTAssertEqual(c.editor.snapshot?.scene, "F")
        XCTAssertNil(c.error, "a refused scene shows on the strip, not as an edit error")
        XCTAssertNil(c.editor.pending)
        // Tapping again retries.
        try c.selectScene("D")
        XCTAssertEqual(c.sceneSwitch, .pending("D"))
    }

    func testStaleSwitchIsNotAppliedAndReloads() throws {
        let (c, t, f) = try sceneSwitching()
        try c.selectScene("D")
        refuse(t, "stale_context")
        XCTAssertEqual(c.sceneSwitch, .notApplied("D"))
        XCTAssertEqual(t.messages.last?["operation"] as? String, "snapshot")
        reply(t, result: ["state": f["snapshot"]!], revision: 2)
        XCTAssertEqual(c.phase, .ready)
        XCTAssertEqual(c.sceneSwitch, .notApplied("D"))
    }

    func testLostSwitchIsUnknownUntilReadbackShowsIt() throws {
        let (c, t, f) = try sceneSwitching()
        try c.selectScene("B")
        refuse(t, "not_confirmed")
        XCTAssertEqual(c.sceneSwitch, .unknown("B"))
        XCTAssertEqual(c.phase, .loading)
        XCTAssertEqual(t.messages.last?["operation"] as? String, "snapshot")
        reply(t, result: ["state": sceneState(f, "B")], revision: 2)
        XCTAssertEqual(c.phase, .ready)
        XCTAssertEqual(c.sceneSwitch, .confirmed("B"))
        XCTAssertEqual(t.messages.filter { $0["operation"] as? String == "select_scene" }.count, 1, "never replayed")
    }

    func testLostSwitchIsNotConfirmedByTheSameLetterOnAnotherPreset() throws {
        let (c, t, f) = try sceneSwitching()
        try c.selectScene("B")
        refuse(t, "not_confirmed")
        XCTAssertEqual(c.sceneSwitch, .unknown("B"))
        var elsewhere = sceneState(f, "B"); elsewhere["preset_id"] = "another-preset"; elsewhere["name"] = "Another preset"
        reply(t, result: ["state": elsewhere], revision: 2)
        XCTAssertEqual(c.phase, .ready)
        XCTAssertNil(c.sceneSwitch, "scene B of another preset says nothing about the switch")
        XCTAssertEqual(c.outcome, "Changed on the QC")
        clock += 3; c.tick()
        reply(t, result: ["state": elsewhere], revision: 2)
        XCTAssertNil(c.sceneSwitch)
    }

    func testUnconfirmedEditKeepsTheConnectionAndIsNotRetried() throws {
        let f = try fixture(), t = OfflineTransport(), c = coordinator(t)
        connect(c, t, fixture: f)
        let snapshot = try XCTUnwrap(c.editor.snapshot)
        let block = try XCTUnwrap(snapshot.blocks.first { b in c.editor.visibleParameters(blockID: b.id).contains { c.editor.readOnlyReason(blockID: b.id, parameterID: $0) == nil } })
        let parameter = try XCTUnwrap(c.editor.visibleParameters(blockID: block.id).first { c.editor.readOnlyReason(blockID: block.id, parameterID: $0) == nil })
        try c.edit(blockID: block.id, parameterID: parameter, value: try XCTUnwrap(c.editor.value(blockID: block.id, parameterID: parameter)))
        refuse(t, "not_confirmed")
        XCTAssertEqual(c.phase, .loading)
        XCTAssertTrue(c.error?.hasPrefix("Outcome unknown") == true)
        reply(t, result: ["state": sceneState(f, "G")], revision: 2)
        XCTAssertEqual(c.phase, .ready)
        XCTAssertEqual(t.messages.filter { $0["operation"] as? String == "set_parameter" }.count, 1)
    }

    func testBusyQCDefersPollingInsteadOfFailing() throws {
        let f = try fixture(), t = OfflineTransport(), c = coordinator(t)
        connect(c, t, fixture: f)
        clock += 3; c.tick()
        XCTAssertEqual(t.messages.last?["operation"] as? String, "snapshot")
        refuse(t, "device_busy")
        XCTAssertEqual(c.phase, .ready)
        XCTAssertNil(c.error)
    }

    func testSceneSwitchThroughTheSimulatedBridge() throws {
        let helper = try simulatorHelper(); defer { helper.stop() }
        let shared = SharedUSBSession(helper: helper)
        let (c, _) = try joined(shared, name: "iPhone")
        try c.edit(blockID: "amp-1", parameterID: "gain", value: .number(7.5))
        XCTAssertEqual(c.editor.snapshot?.dirty, true)
        try c.selectScene("B")
        XCTAssertEqual(c.editor.snapshot?.scene, "B")
        XCTAssertEqual(c.editor.snapshot?.dirty, true)
        XCTAssertEqual(c.sceneSwitch, .confirmed("B"))
        // The simulator has two scenes, so C is refused before anything changes.
        try c.selectScene("C")
        XCTAssertEqual(c.sceneSwitch, .notApplied("C"))
        XCTAssertEqual(c.editor.snapshot?.scene, "B")
        XCTAssertEqual(c.phase, .ready)
    }

}
