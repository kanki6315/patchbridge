import XCTest
import CoreBluetooth
@testable import PatchbridgeCore

private final class OfflineTransport: DiscoverableEditorTransport {
    var disconnectionReason: String?
    var disconnectionIsTransient = false
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
        // A save during the poll waits for it; the poll found the preset changed, so it never goes.
        XCTAssertNoThrow(try c.save()); XCTAssertTrue(c.busy); XCTAssertEqual(t.messages.count, count + 1)
        var state = f["snapshot"] as! [String: Any]; state["scene"] = "A"
        reply(t, result: ["state": state], revision: 1)
        XCTAssertEqual(c.editor.snapshot?.scene, "A")
        XCTAssertEqual(c.outcome, "Changed on the QC")
        XCTAssertEqual(c.error, "Not applied. The QC changed first; try again.")
        XCTAssertFalse(c.busy); XCTAssertNil(c.editor.pending)
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
        // The poll doesn't grey out Save: the save waits for it, then goes against unchanged state.
        XCTAssertFalse(c.busy)
        XCTAssertNoThrow(try c.save())
        c.setBackgrounded(false); c.tick()
        XCTAssertEqual(t.messages.count, count + 1)
        reply(t, result: ["state": f["snapshot"]!])
        XCTAssertEqual(t.messages.last?["operation"] as? String, "save")
        XCTAssertEqual(c.phase, .ready); XCTAssertTrue(c.busy)
        var saved = f["snapshot"] as! [String: Any]; saved["dirty"] = false
        reply(t, result: ["state": saved], revision: 1)
        XCTAssertEqual(c.outcome, "Saved on the QC"); XCTAssertFalse(c.busy)
    }
    func testUnchangedPollCarriesNoState() throws {
        let t = OfflineTransport(); let c = coordinator(t); let f = try fixture()
        connect(c, t, fixture: f)
        let before = c.editor.snapshot
        c.refresh()
        XCTAssertEqual((t.messages.last?["payload"] as? [String: Any])?["known_revision"] as? Int, 0)
        reply(t, result: ["unchanged": true])
        XCTAssertEqual(c.phase, .ready); XCTAssertEqual(c.editor.snapshot, before); XCTAssertNil(c.outcome)
        // "Unchanged" at a revision this phone never saw can't be trusted.
        c.refresh(); reply(t, result: ["unchanged": true], revision: 3)
        XCTAssertEqual(c.phase, .failed)
    }
    func testHelloOffersDeflate() {
        let t = OfflineTransport(); let c = coordinator(t); c.start()
        XCTAssertEqual(t.messages.last?["compression"] as? [String], ["deflate"])
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
    /// A trusted, ready session over the simulator bridge, as after approving with trust.
    private func trustedSession() throws -> (EditorCoordinator, OfflineTransport, DeviceSession, HelperClient) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let helper = try HelperClient(python: "/opt/homebrew/bin/python3", source: root.appendingPathComponent("src").path)
        let bridge = DeviceSession(helper: helper)
        let t = OfflineTransport(); t.autoReady = false; t.handler = { try bridge.handle($0) }
        let c = coordinator(t)
        c.start(); t.onDiscovered?("mac", "Studio Mac"); c.chooseMac("mac")
        bridge.approve(trusting: true); c.authorize()
        XCTAssertEqual(c.phase, .ready); XCTAssertTrue(c.trusted)
        return (c, t, bridge, helper)
    }
    func testTrustedSessionResumesAfterTransientDrop() throws {
        let (c, t, bridge, helper) = try trustedSession(); defer { helper.stop() }
        bridge.revoke()
        t.disconnectionReason = "Your Mac disconnected. Keep it nearby with Patchbridge open, then reconnect."
        t.disconnectionIsTransient = true; t.onDisconnected?()
        XCTAssertEqual(c.phase, .connecting); XCTAssertTrue(c.resuming)
        XCTAssertEqual(c.macName, bridge.macName); XCTAssertNil(c.error)

        // Found again: the trust token skips the code and fresh state loads.
        t.disconnectionIsTransient = false
        t.onDiscovered?("mac", "Studio Mac")
        XCTAssertEqual(c.phase, .ready); XCTAssertFalse(c.resuming); XCTAssertNil(c.approvalCode)
    }
    func testResumeKeepsTheTunerAndAsksForItAgain() throws {
        let (c, t, bridge, helper) = try trustedSession(); defer { helper.stop() }
        guard c.tunerAvailable else { throw XCTSkip("The simulated bridge offers no tuner") }
        c.setTuner(.live)
        XCTAssertTrue(t.messages.contains { $0["operation"] as? String == "tuner" })
        bridge.revoke(); t.disconnectionIsTransient = true; t.onDisconnected?()
        XCTAssertTrue(c.resuming); XCTAssertEqual(c.tunerMode, .live, "The screen keeps the tuner open while reconnecting")
        let sent = t.messages.count
        t.disconnectionIsTransient = false; t.onDiscovered?("mac", "Studio Mac")
        XCTAssertEqual(c.phase, .ready); XCTAssertEqual(c.tunerMode, .live)
        let tuner = t.messages.dropFirst(sent).first { $0["operation"] as? String == "tuner" }
        XCTAssertEqual((tuner?["payload"] as? [String: Any])?["mode"] as? String, "live")

        // Giving up turns it off, as any failed session does.
        bridge.revoke(); t.disconnectionIsTransient = true; t.onDisconnected?()
        clock += EditorCoordinator.resumeWindow; c.tick()
        XCTAssertEqual(c.phase, .failed); XCTAssertEqual(c.tunerMode, .off)
    }
    func testResumeNeverReplaysAnEditInFlight() throws {
        let (c, t, bridge, helper) = try trustedSession(); defer { helper.stop() }
        // The save reaches the Mac, but its answer never comes back before the link drops.
        t.hold = true; try c.save(); XCTAssertTrue(c.busy)
        let sent = t.messages.count
        bridge.revoke(); t.hold = false; t.held = nil
        t.disconnectionIsTransient = true; t.onDisconnected?()
        XCTAssertTrue(c.resuming)
        XCTAssertEqual(c.error, "Last edit or save outcome unknown. It will not be retried.")
        t.disconnectionIsTransient = false; t.onDiscovered?("mac", "Studio Mac")
        XCTAssertEqual(c.phase, .ready)
        let operations = t.messages.dropFirst(sent).compactMap { $0["operation"] as? String }
        XCTAssertFalse(operations.contains { EditorCoordinator.mutations.contains($0) })
    }
    func testResumeBacksOffThenGivesUpWithOriginalReason() throws {
        let (c, t, bridge, helper) = try trustedSession(); defer { helper.stop() }
        bridge.revoke()
        let reason = "Your Mac disconnected. Keep it nearby with Patchbridge open, then reconnect."
        t.disconnectionReason = reason; t.disconnectionIsTransient = true; t.onDisconnected?()
        // The first search starts at once; a second drop waits before searching again.
        t.onDisconnected?()
        XCTAssertTrue(c.resuming); XCTAssertEqual(c.phase, .connecting)
        let before = t.messages.count
        clock += 0.5; c.tick(); t.onDiscovered?("mac", "Studio Mac")
        XCTAssertEqual(t.messages.count, before, "No search while backing off")
        clock += 1; c.tick()
        XCTAssertTrue(c.resuming)
        clock += EditorCoordinator.resumeWindow; c.tick()
        XCTAssertEqual(c.phase, .failed); XCTAssertFalse(c.resuming); XCTAssertEqual(c.error, reason)
    }
    func testDropsThatNeedTheUserStillFail() throws {
        // Pairing or Bluetooth problems need Settings, not another search.
        let (c, t, _, helper) = try trustedSession(); defer { helper.stop() }
        t.disconnectionReason = "Bluetooth pairing needs to be set up again."
        t.disconnectionIsTransient = false; t.onDisconnected?()
        XCTAssertEqual(c.phase, .failed); XCTAssertFalse(c.resuming)

        // A session without trust would land on an approval code, so it asks for Reconnect instead.
        let u = OfflineTransport(); let d = coordinator(u)
        connect(d, u, fixture: try fixture())
        u.disconnectionIsTransient = true; u.onDisconnected?()
        XCTAssertEqual(d.phase, .failed); XCTAssertFalse(d.resuming)
    }
    func testDisconnectCancelsResume() throws {
        let (c, t, bridge, helper) = try trustedSession(); defer { helper.stop() }
        bridge.revoke(); t.disconnectionIsTransient = true; t.onDisconnected?()
        XCTAssertTrue(c.resuming)
        c.disconnect()
        XCTAssertEqual(c.phase, .disconnected); XCTAssertFalse(c.resuming)
        t.onDiscovered?("mac", "Studio Mac"); XCTAssertEqual(c.phase, .disconnected)
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

    // MARK: Presets

    private var presetOperations: [String] { ["snapshot", "catalog", "set_parameter", "select_scene", "save", "list_presets", "select_preset"] }
    private func presetState(_ f: [String: Any], id: String = "captured:My Presets:16", name: String = "Tremonti w Mic", dirty: Bool) -> [String: Any] {
        var state = f["snapshot"] as! [String: Any]; state["preset_id"] = id; state["name"] = name; state["dirty"] = dirty; return state
    }
    private var listing: [String: Any] { ["presets": ["source": "My Presets", "slots": 256, "entries": [
        ["preset_id": "slot-15", "number": 15, "name": "Blues Lead"],
        ["preset_id": "captured:My Presets:16", "number": 16, "name": "Tremonti w Mic"],
        ["preset_id": "slot-18", "number": 18, "name": "Funk Wah"]]]] }
    private func presetBrowsing(dirty: Bool) throws -> (EditorCoordinator, OfflineTransport, [String: Any]) {
        var f = try fixture(); f["snapshot"] = presetState(f, dirty: dirty)
        let t = OfflineTransport(), c = coordinator(t)
        connect(c, t, fixture: f, operations: presetOperations)
        c.listPresets()
        XCTAssertEqual(t.messages.last?["operation"] as? String, "list_presets")
        XCTAssertTrue(c.listingPresets)
        reply(t, result: listing)
        XCTAssertFalse(c.listingPresets)
        return (c, t, f)
    }

    func testPresetListKeepsSlotsAndCollapsesTheEmptyEnd() throws {
        let (c, _, _) = try presetBrowsing(dirty: false)
        let list = try XCTUnwrap(c.presetList)
        XCTAssertEqual(list.entries.count, 3)
        XCTAssertEqual(list.rows.count, 14 + 3 + 1 + 1)
        XCTAssertEqual(list.rows.first, .empty(1))
        XCTAssertEqual(list.rows[16], .empty(17))
        XCTAssertEqual(list.rows.last, .emptyRun(19...256))
        XCTAssertEqual(c.phase, .ready)
    }

    func testCleanPresetSwitchConfirmsOnlyAfterTheQCLoadsIt() throws {
        let (c, t, f) = try presetBrowsing(dirty: false)
        try c.selectPreset("slot-15")
        let sent = try XCTUnwrap(t.messages.last)
        XCTAssertEqual(sent["operation"] as? String, "select_preset")
        XCTAssertEqual(sent["payload"] as? [String: AnyHashable], ["preset_id": "slot-15", "discard": false])
        XCTAssertEqual(c.presetSwitch, .pending("slot-15"))
        XCTAssertEqual(c.editor.snapshot?.name, "Tremonti w Mic", "the loaded preset stays until the QC confirms")
        reply(t, result: ["state": presetState(f, id: "slot-15", name: "Blues Lead", dirty: false)], revision: 1)
        XCTAssertEqual(c.phase, .ready)
        XCTAssertEqual(c.editor.snapshot?.name, "Blues Lead")
        XCTAssertNil(c.presetSwitch)
        XCTAssertEqual(c.outcome, "Loaded Blues Lead")
        XCTAssertNil(c.editor.lastError)
    }

    func testPresetWithNewModelsReloadsBeforeShowing() throws {
        let (c, t, f) = try presetBrowsing(dirty: false)
        try c.selectPreset("slot-18")
        var state = presetState(f, id: "slot-18", name: "Funk Wah", dirty: false)
        var blocks = state["blocks"] as! [[String: Any]]; blocks[0]["model_id"] = "new-model"; state["blocks"] = blocks
        reply(t, result: ["state": state], revision: 1)
        XCTAssertEqual(c.phase, .loading)
        XCTAssertEqual(c.presetSwitch, .loading("slot-18"))
        XCTAssertEqual(c.loadingPreset?.name, "Funk Wah")
        XCTAssertEqual(t.messages.last?["operation"] as? String, "catalog")
        var catalog = f["catalog"] as! [String: Any]; var models = catalog["models"] as! [String: Any]
        models["new-model"] = models[(blocks[1]["model_id"] as! String)]; catalog["models"] = models
        reply(t, result: catalog, revision: 1)
        XCTAssertEqual(c.phase, .ready)
        XCTAssertNil(c.presetSwitch)
        XCTAssertEqual(c.outcome, "Loaded Funk Wah")
        XCTAssertNotNil(c.presetList, "the list outlives the switch")
    }

    func testDirtyPresetIsRefusedWithoutAChoiceAndSaveFirstSavesThenLoads() throws {
        let (c, t, f) = try presetBrowsing(dirty: true)
        try c.selectPreset("slot-15")
        refuse(t, "unsaved_changes")
        XCTAssertEqual(c.presetSwitch, .notApplied("slot-15", "Not switched. The preset has unsaved edits."))
        XCTAssertEqual(t.messages.last?["operation"] as? String, "snapshot")
        reply(t, result: ["state": presetState(f, dirty: true)], revision: 1)
        XCTAssertEqual(c.phase, .ready)

        try c.selectPreset("slot-15", mode: .saveFirst)
        XCTAssertEqual(t.messages.last?["operation"] as? String, "save")
        XCTAssertEqual(c.presetSwitch, .saving("slot-15"))
        reply(t, result: ["state": presetState(f, dirty: false)], revision: 2)
        XCTAssertEqual(t.messages.last?["operation"] as? String, "select_preset")
        XCTAssertEqual((t.messages.last?["payload"] as? [String: Any])?["discard"] as? Bool, false)
        XCTAssertEqual(t.messages.last?["revision"] as? Int, 2)
        XCTAssertEqual(c.presetSwitch, .pending("slot-15"))
        reply(t, result: ["state": presetState(f, id: "slot-15", name: "Blues Lead", dirty: false)], revision: 3)
        XCTAssertEqual(c.editor.snapshot?.name, "Blues Lead")
        XCTAssertEqual(t.messages.filter { $0["operation"] as? String == "save" }.count, 1)
    }

    func testDiscardSaysSoAndAFailedSaveSwitchesNothing() throws {
        let (c, t, _) = try presetBrowsing(dirty: true)
        try c.selectPreset("slot-15", mode: .saveFirst)
        refuse(t, "device_busy")
        XCTAssertEqual(c.presetSwitch, .notApplied("slot-15", "The QC was changing scene or preset. Try again."))
        XCTAssertFalse(t.messages.contains { $0["operation"] as? String == "select_preset" })
        try c.selectPreset("slot-15", mode: .discard)
        XCTAssertEqual((t.messages.last?["payload"] as? [String: Any])?["discard"] as? Bool, true)
    }

    func testLostPresetSwitchIsUnknownUntilReadbackShowsIt() throws {
        let (c, t, f) = try presetBrowsing(dirty: false)
        try c.selectPreset("slot-15")
        refuse(t, "not_confirmed")
        XCTAssertEqual(c.presetSwitch, .unknown("slot-15"))
        XCTAssertEqual(t.messages.last?["operation"] as? String, "snapshot")
        reply(t, result: ["state": presetState(f, id: "slot-15", name: "Blues Lead", dirty: false)], revision: 2)
        XCTAssertNil(c.presetSwitch)
        XCTAssertEqual(c.outcome, "Loaded Blues Lead")
        XCTAssertEqual(t.messages.filter { $0["operation"] as? String == "select_preset" }.count, 1, "never replayed")
    }

    func testSwitchTappedDuringTheListWaitsForIt() throws {
        let (c, t, f) = try presetBrowsing(dirty: false)
        c.listPresets()
        XCTAssertThrowsError(try c.selectPreset("slot-99"))
        try c.selectPreset("slot-18")
        XCTAssertEqual(c.presetSwitch, .pending("slot-18"))
        XCTAssertEqual(t.messages.last?["operation"] as? String, "list_presets")
        reply(t, result: listing)
        XCTAssertEqual(t.messages.last?["operation"] as? String, "select_preset")
        reply(t, result: ["state": presetState(f, id: "slot-18", name: "Funk Wah", dirty: false)], revision: 1)
        XCTAssertEqual(c.editor.snapshot?.name, "Funk Wah")
    }

    func testListFailureKeepsTheConnectionAndBusyRetries() throws {
        var f = try fixture(); f["snapshot"] = presetState(f, dirty: false)
        let t = OfflineTransport(), c = coordinator(t)
        connect(c, t, fixture: f, operations: presetOperations)
        c.listPresets(); refuse(t, "device_busy")
        XCTAssertEqual(c.phase, .ready)
        XCTAssertTrue(c.listingPresets)
        clock += 1.5; c.tick()
        XCTAssertEqual(t.messages.last?["operation"] as? String, "list_presets")
        refuse(t, "not_confirmed")
        XCTAssertEqual(c.phase, .ready)
        XCTAssertEqual(c.presetListError, "not_confirmed")
        XCTAssertFalse(c.listingPresets)
    }

    func testUnsavedEditsListWhoMadeThemAgainstTheSavedPreset() throws {
        let (c, t, f) = try presetBrowsing(dirty: false)
        XCTAssertNotNil(c.editor.saved)
        XCTAssertEqual(c.editor.unsavedEdits, [])
        let block = try XCTUnwrap(c.editor.snapshot?.blocks.first { b in c.editor.visibleParameters(blockID: b.id).contains { c.editor.readOnlyReason(blockID: b.id, parameterID: $0) == nil } })
        let parameter = try XCTUnwrap(c.editor.visibleParameters(blockID: block.id).first { c.editor.readOnlyReason(blockID: block.id, parameterID: $0) == nil })
        let before = try XCTUnwrap(c.editor.value(blockID: block.id, parameterID: parameter))
        guard case .number(let old) = before else { return XCTFail("numeric parameter expected") }
        let value = old > 0.5 ? old - 0.1 : old + 0.1
        try c.edit(blockID: block.id, parameterID: parameter, value: .number(value))
        var state = presetState(f, dirty: true)
        var blocks = state["blocks"] as! [[String: Any]]
        let index = blocks.firstIndex { $0["id"] as? String == block.id }!
        var scenes = blocks[index]["scenes"] as! [String: [String: Any]]
        var parameters = scenes["F"]!["parameters"] as! [String: Any]; parameters[parameter] = value
        scenes["F"]!["parameters"] = parameters; blocks[index]["scenes"] = scenes; state["blocks"] = blocks
        reply(t, result: ["state": state], revision: 1)
        XCTAssertEqual(c.editor.unsavedEdits, [UnsavedEdit(blockID: block.id, parameterID: parameter, scene: "F", current: .number(value), saved: before, onQC: false)])
        // A bypass flipped on the QC is listed as the QC's.
        scenes["F"]!["bypass"] = !((scenes["F"]!["bypass"] as? Bool) ?? false); blocks[index]["scenes"] = scenes; state["blocks"] = blocks
        clock += 3; c.tick(); reply(t, result: ["state": state], revision: 2)
        XCTAssertEqual(c.editor.unsavedEdits.count, 2)
        XCTAssertEqual(c.editor.unsavedEdits.last?.onQC, true)
        XCTAssertNil(c.editor.unsavedEdits.last?.parameterID)
    }

    func testPresetThatArrivesDirtyHasNoKnownSavedValues() throws {
        let (c, _, _) = try presetBrowsing(dirty: true)
        XCTAssertNil(c.editor.saved)
        XCTAssertEqual(c.editor.unsavedEdits, [])
    }

    func testPresetSwitchThroughTheSimulatedBridge() throws {
        let helper = try simulatorHelper(); defer { helper.stop() }
        let shared = SharedUSBSession(helper: helper)
        let (c, _) = try joined(shared, name: "iPhone")
        XCTAssertTrue(c.presetSwitchAvailable)
        c.listPresets()
        XCTAssertEqual(c.presetList?.entries.map(\.number), [1, 2, 3, 4])
        XCTAssertEqual(c.editor.snapshot?.location, PresetSnapshot.Location(source: "My Presets", number: 1))
        try c.edit(blockID: "amp-1", parameterID: "gain", value: .number(7.5))
        try c.selectPreset("2")
        XCTAssertEqual(c.presetSwitch, .notApplied("2", "Not switched. The preset has unsaved edits."))
        XCTAssertEqual(c.editor.snapshot?.name, "Simulation 1")
        try c.selectPreset("2", mode: .discard)
        XCTAssertEqual(c.editor.snapshot?.name, "Simulation 2")
        XCTAssertEqual(c.editor.snapshot?.dirty, false)
        XCTAssertEqual(c.phase, .ready)
        try c.edit(blockID: "amp-1", parameterID: "gain", value: .number(3))
        try c.selectPreset("1", mode: .saveFirst)
        XCTAssertEqual(c.editor.snapshot?.name, "Simulation 1")
        try c.selectPreset("2")
        XCTAssertEqual(c.editor.value(blockID: "amp-1", parameterID: "gain"), .number(3), "saved before switching")
    }

    func testQueuedDiscardIsRefusedWhenThePollShowsAnotherPresetOrNewEdits() throws {
        for change in ["another preset", "new edit"] {
            let (c, t, f) = try presetBrowsing(dirty: true)
            clock += 3; c.tick()
            XCTAssertEqual(t.messages.last?["operation"] as? String, "snapshot")
            try c.selectPreset("slot-15", mode: change == "new edit" ? .saveFirst : .discard)
            var state = presetState(f, dirty: true)
            if change == "another preset" { state = presetState(f, id: "slot-18", name: "Funk Wah", dirty: true) }
            else { state["scene"] = "A" }
            reply(t, result: ["state": state], revision: 1)
            c.tick()
            XCTAssertEqual(c.presetSwitch, .notApplied("slot-15", EditorCoordinator.changedBeforeSwitch), change)
            XCTAssertFalse(t.messages.contains { ["select_preset", "save"].contains($0["operation"] as? String) }, change)
        }
    }

    func testQueuedDiscardGoesWhenThePollShowsTheSamePreset() throws {
        let (c, t, f) = try presetBrowsing(dirty: true)
        clock += 3; c.tick()
        try c.selectPreset("slot-15", mode: .discard)
        reply(t, result: ["state": presetState(f, dirty: true)], revision: 0)
        c.tick()
        XCTAssertEqual(t.messages.last?["operation"] as? String, "select_preset")
        XCTAssertEqual((t.messages.last?["payload"] as? [String: Any])?["discard"] as? Bool, true)
    }

    func testApprovalFromAnOlderScreenIsRefused() throws {
        let (c, t, f) = try presetBrowsing(dirty: true)
        var older = presetState(f, dirty: true); older["scene"] = "A"
        try c.selectPreset("slot-15", mode: .discard, approved: try JSONDecoder().decode(PresetSnapshot.self, from: JSONSerialization.data(withJSONObject: older)))
        XCTAssertEqual(c.presetSwitch, .notApplied("slot-15", EditorCoordinator.changedBeforeSwitch))
        XCTAssertNotEqual(t.messages.last?["operation"] as? String, "select_preset")
    }

    func testRecoveryDropsTheListSoItIsReadAgain() throws {
        let (c, t, f) = try presetBrowsing(dirty: false)
        XCTAssertNotNil(c.presetList)
        clock += 3; c.tick()
        t.onResponse?(["version": 1, "id": t.messages.last!["id"]!, "connection_id": "c", "status": "error", "retry_after": 0,
                       "error": ["code": "device_unavailable", "message": "QC unavailable."]])
        XCTAssertEqual(c.phase, .recovering)
        clock += 1; c.tick()
        XCTAssertEqual(t.messages.last?["operation"] as? String, "recover")
        reply(t, result: ["state": presetState(f, dirty: false)], session: "s2")
        reply(t, result: ["protocol_version": 1, "operations": presetOperations], session: "s2")
        XCTAssertEqual(c.phase, .ready)
        XCTAssertNil(c.presetList, "the new helper session never listed these slots")
        XCTAssertThrowsError(try c.selectPreset("slot-15"))
        c.listPresets()
        XCTAssertEqual(t.messages.last?["operation"] as? String, "list_presets")
    }

    func testSlotTheBridgeDoesNotKnowRereadsTheList() throws {
        let (c, t, f) = try presetBrowsing(dirty: false)
        try c.selectPreset("slot-15")
        refuse(t, "invalid_value")
        XCTAssertEqual(c.presetSwitch, .notApplied("slot-15", "Not switched. The list was out of date; it’s being read again."))
        XCTAssertNil(c.presetList)
        reply(t, result: ["state": presetState(f, dirty: false)], revision: 1)
        c.tick()
        XCTAssertEqual(t.messages.last?["operation"] as? String, "list_presets")
    }

}
