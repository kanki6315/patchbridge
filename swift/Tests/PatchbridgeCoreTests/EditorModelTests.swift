import XCTest
@testable import PatchbridgeCore

final class FakeTransport: EditorTransport {
    var onReady: (() -> Void)?
    var onDisconnected: (() -> Void)?
    var onStatus: ((String) -> Void)?
    var onResponse: (([String: Any]) -> Void)?
    var requests = [[String: Any]]()
    var disconnected = false
    func reconnect() {}
    func disconnect() { disconnected = true; onDisconnected?() }
    func send(_ message: [String: Any]) throws { requests.append(message) }
    func reply(_ fields: [String: Any]) {
        var reply = fields
        reply["version"] = reply["version"] ?? 1
        reply["id"] = reply["id"] ?? requests.last?["id"]
        reply["connection_id"] = reply["connection_id"] ?? "connection"
        onResponse?(reply)
    }
}

final class EditorModelTests: XCTestCase {
    var transport: FakeTransport!
    var model: EditorModel!
    override func setUp() {
        transport = FakeTransport()
        let transport = transport!
        model = EditorModel(makeTransport: { transport })
        model.scan(); transport.onReady?()
        transport.reply(["authorization_required": true])
    }
    func state(gain: Double = 5, dirty: Bool = false, scene: String = "A") -> [String: Any] {
        ["name": "Simulation 1", "preset_id": "1", "scene": scene, "dirty": dirty,
         "blocks": [["id": "amp-1", "scenes": [scene: ["parameters": ["gain": gain]]]]]]
    }
    func confirm(_ state: [String: Any], revision: Int = 0, session: String = "session") {
        transport.reply(["status": "confirmed", "session_id": session, "revision": revision, "result": ["state": state]])
    }
    func connect() { model.authorize(); confirm(state()) }
    func testApprovalDoesNotPretendToConnect() {
        XCTAssertTrue(model.needsApproval); XCTAssertFalse(model.ready)
        model.authorize(); transport.reply(["status": "error", "error": "unauthorized"])
        XCTAssertTrue(model.needsApproval); XCTAssertFalse(model.ready); XCTAssertFalse(model.busy)
    }
    func testEditSaveAndRefreshUseConfirmedContext() {
        connect()
        model.gain = 7; model.commitGain()
        XCTAssertTrue(model.busy); XCTAssertEqual(model.confirmedGain, 5)
        XCTAssertEqual(transport.requests.last?["revision"] as? Int, 0)
        confirm(state(gain: 7, dirty: true), revision: 1)
        XCTAssertEqual(model.confirmedGain, 7); XCTAssertTrue(model.dirty)
        model.save()
        XCTAssertEqual(transport.requests.last?["revision"] as? Int, 1)
        confirm(state(gain: 7), revision: 2)
        XCTAssertFalse(model.dirty); XCTAssertEqual(model.lastResult, "Saved in the Mac simulation")
    }
    func testRejectedEditRestoresLastConfirmedValue() {
        connect(); model.gain = 9; model.commitGain()
        transport.reply(["status": "error", "session_id": "session", "error": ["message": "stale context"]])
        XCTAssertEqual(model.gain, 5); XCTAssertNotNil(model.error); XCTAssertFalse(model.busy)
    }
    func testDisconnectDropsPendingEditAndIgnoresLateReply() {
        connect(); model.gain = 9; model.commitGain()
        let oldID = transport.requests.last!["id"]!
        model.disconnect()
        transport.reply(["id": oldID, "status": "confirmed", "session_id": "session", "revision": 1, "result": ["state": state(gain: 9)]])
        XCTAssertFalse(model.ready); XCTAssertEqual(model.gain, 5)
        let count = transport.requests.count
        model.save(); model.commitGain()
        XCTAssertEqual(transport.requests.count, count)
    }
    func testMissingSnapshotAndWrongSessionDisconnect() {
        connect(); model.refresh()
        transport.reply(["status": "confirmed", "session_id": "other", "revision": 1, "result": ["state": state()]])
        XCTAssertTrue(transport.disconnected); XCTAssertFalse(model.ready)
    }
    func testInvalidValueDoesNotBecomeConfirmedState() {
        connect(); model.refresh(); confirm(state(gain: 99))
        XCTAssertTrue(transport.disconnected); XCTAssertEqual(model.confirmedGain, 5)
    }
    func testResponseFromAnotherConnectionDoesNotReplaceContext() {
        connect(); model.refresh()
        transport.reply(["connection_id": "old", "status": "confirmed", "session_id": "session", "revision": 1, "result": ["state": state(gain: 8)]])
        XCTAssertFalse(model.ready); XCTAssertEqual(model.confirmedGain, 5)
    }
    func testFailedSaveDoesNotClearUnsavedState() {
        connect(); model.gain = 7; model.commitGain(); confirm(state(gain: 7, dirty: true), revision: 1)
        model.save()
        transport.reply(["status": "error", "session_id": NSNull(), "error": ["message": "save unconfirmed"]])
        XCTAssertTrue(model.dirty); XCTAssertFalse(model.ready); XCTAssertFalse(model.busy)
    }
}

extension EditorModelTests {
    func testUnsolicitedReplyCannotConnectEditor() {
        model.disconnect()
        transport.onResponse?(["version": 1, "status": "confirmed", "session_id": "unsolicited", "revision": 0, "connection_id": "connection", "result": ["state": state()]])
        XCTAssertFalse(model.ready)
    }
}

extension EditorModelTests {
    func testSaveCannotClaimSuccessWhileDirty() {
        connect(); model.gain = 7; model.commitGain(); confirm(state(gain: 7, dirty: true), revision: 1)
        model.save(); confirm(state(gain: 7, dirty: true), revision: 2)
        XCTAssertFalse(model.ready); XCTAssertTrue(model.dirty)
        XCTAssertNotEqual(model.lastResult, "Saved in the Mac simulation")
    }
    func testEditNeedsRevisionAdvance() {
        connect(); model.gain = 7; model.commitGain(); confirm(state(gain: 7), revision: 0)
        XCTAssertFalse(model.ready); XCTAssertEqual(model.confirmedGain, 5)
    }
}
