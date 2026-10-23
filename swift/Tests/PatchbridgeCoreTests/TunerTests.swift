import XCTest
@testable import PatchbridgeCore

private final class ScriptedTransport: EditorTransport {
    var disconnectionReason: String?
    var onReady: (() -> Void)?
    var onDisconnected: (() -> Void)?
    var onStatus: ((String) -> Void)?
    var onResponse: (([String: Any]) -> Void)?
    var messages = [[String: Any]]()
    func reconnect() { onReady?() }
    func disconnect() {}
    func send(_ message: [String: Any]) throws { messages.append(message) }
}

final class TunerTests: XCTestCase {
    private var clock: TimeInterval = 0

    func testPitchNamesTheNearestNoteAndCents() throws {
        let d = try XCTUnwrap(TunerPitch(hz: 73.42))
        XCTAssertEqual(d.note, "D"); XCTAssertEqual(d.octave, 2); XCTAssertEqual(d.cents, 0, accuracy: 0.1)
        XCTAssertTrue(d.inTune)
        let sharp = try XCTUnwrap(TunerPitch(hz: 73.67))
        XCTAssertEqual(sharp.cents, 5.9, accuracy: 0.1); XCTAssertFalse(sharp.inTune)
        let flat = try XCTUnwrap(TunerPitch(hz: 194.42))
        XCTAssertEqual(flat.note, "G"); XCTAssertEqual(flat.octave, 3); XCTAssertEqual(flat.cents, -14, accuracy: 0.1)
        XCTAssertEqual(TunerPitch(hz: 440)?.note, "A"); XCTAssertEqual(TunerPitch(hz: 440)?.octave, 4)
        XCTAssertEqual(TunerPitch(hz: 277.18)?.note, "C♯")
        XCTAssertNil(TunerPitch(hz: 0)); XCTAssertNil(TunerPitch(hz: .nan))
    }

    func testTrackIgnoresOneStrayReadingAndGoesQuiet() throws {
        var track = TunerTrack()
        track.add(hz: 110, at: 0); track.add(hz: 554.7, at: 0.1); track.add(hz: 110.2, at: 0.2)
        XCTAssertEqual(try XCTUnwrap(track.pitch(at: 0.2)).note, "A")
        XCTAssertNotNil(track.pitch(at: 1.5), "No answer yet: the bridge is slow, not the strings quiet")
        track.answered(at: 0.5)
        XCTAssertNotNil(track.pitch(at: 0.5), "A short pause in the QC's stream keeps the note")
        track.answered(at: 1.0)
        XCTAssertNil(track.pitch(at: 1.0), "Silence once the bridge answers without readings")
        var stalled = TunerTrack(); stalled.add(hz: 110, at: 0)
        XCTAssertNil(stalled.pitch(at: 2.6), "Too long without any answer to trust the last pitch")
        track.add(hz: 0, at: 0.9)
        XCTAssertNil(track.pitch(at: 0.9), "Zero means the QC heard no note")
    }

    private func fixture() throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("tests/fixtures/qc-editor.json"))) as! [String: Any]
    }
    private func reply(_ t: ScriptedTransport, _ result: [String: Any]) {
        t.onResponse?(["version": 1, "id": t.messages.last!["id"]!, "connection_id": "c", "session_id": "s",
                       "revision": 0, "status": "confirmed", "result": result])
    }
    private func ready(operations: [String] = ["snapshot", "catalog", "set_parameter", "save", "tuner", "tuner_read", "set_tuner_mute"]) throws -> (EditorCoordinator, ScriptedTransport) {
        let f = try fixture(), t = ScriptedTransport()
        let c = EditorCoordinator(pollInterval: 2, timeout: 5, automaticPolling: false, now: { self.clock }, makeTransport: { t })
        c.start()
        t.onResponse?(["version": 1, "id": t.messages.last!["id"]!, "connection_id": "c", "authorization_required": true])
        c.authorize(); reply(t, ["state": f["snapshot"]!])
        reply(t, ["protocol_version": 1, "operations": operations])
        reply(t, f["catalog"] as! [String: Any])
        XCTAssertEqual(c.phase, .ready)
        return (c, t)
    }
    private func last(_ t: ScriptedTransport) -> (String?, [String: Any]?) {
        (t.messages.last?["operation"] as? String, t.messages.last?["payload"] as? [String: Any])
    }

    func testTunerStartsReadsAndKeepsItsPlaceInTheStream() throws {
        let (c, t) = try ready()
        XCTAssertTrue(c.tunerAvailable)
        c.setTuner(.live)
        XCTAssertEqual(last(t).0, "tuner"); XCTAssertEqual(last(t).1?["mode"] as? String, "live")
        XCTAssertFalse(c.busy, "Tuner requests never block editing")
        reply(t, ["tuner": ["mode": "live", "muted": false, "input": 1, "seq": 0]])
        XCTAssertEqual(last(t).0, "tuner_read"); XCTAssertEqual(last(t).1?["after"] as? Int, 0)
        reply(t, ["tuner": ["mode": "live", "muted": false, "input": 1, "seq": 2, "readings": [
            ["seq": 1, "hz": 73.6, "ms": 0], ["seq": 2, "hz": 73.67, "ms": 100]]]])
        XCTAssertEqual(c.tunerPitch()?.note, "D")
        clock += 0.1; c.tick()
        XCTAssertEqual(last(t).0, "tuner_read"); XCTAssertEqual(last(t).1?["after"] as? Int, 2)
    }

    func testAnEditDuringATunerReadGoesNextAndIsNotDropped() throws {
        let (c, t) = try ready()
        c.setTuner(.live)
        reply(t, ["tuner": ["mode": "live", "muted": NSNull(), "input": NSNull(), "seq": 0]])
        XCTAssertEqual(last(t).0, "tuner_read")
        let block = try XCTUnwrap(c.editor.snapshot?.blocks.first { !($0.editable_parameters ?? []).isEmpty })
        let parameter = try XCTUnwrap(block.editable_parameters?.first)
        let value = try XCTUnwrap(c.editor.value(blockID: block.id, parameterID: parameter))
        try c.edit(blockID: block.id, parameterID: parameter, value: value)
        XCTAssertEqual(last(t).0, "tuner_read", "The edit waits for the read in flight")
        reply(t, ["tuner": ["mode": "live", "seq": 0, "readings": []]])
        XCTAssertEqual(last(t).0, "set_parameter")
        XCTAssertTrue(c.busy)
    }

    func testMuteOnlyWhileOpenAndRefusalsKeepTheConnection() throws {
        let (c, t) = try ready()
        c.setTuner(.live); reply(t, ["tuner": ["mode": "live", "seq": 0]])
        let sent = t.messages.count
        c.setTunerMuted(true)
        XCTAssertEqual(t.messages.count, sent, "No mute while the tuner isn't shown")
        c.setTuner(.open)
        reply(t, ["tuner": ["mode": "live", "seq": 0, "readings": []]])
        XCTAssertEqual(last(t).1?["mode"] as? String, "open")
        reply(t, ["tuner": ["mode": "open", "muted": false, "seq": 0]])
        c.setTunerMuted(true)
        reply(t, ["tuner": ["mode": "open", "seq": 0, "readings": []]])
        XCTAssertEqual(last(t).0, "set_tuner_mute")
        t.onResponse?(["version": 1, "id": t.messages.last!["id"]!, "connection_id": "c", "session_id": "s", "revision": 0,
                       "status": "error", "error": ["code": "not_confirmed", "message": "The QC did not confirm the mute change."]])
        XCTAssertEqual(c.phase, .ready)
        XCTAssertEqual(c.tunerError, "The QC did not confirm the mute change.")
        XCTAssertEqual(c.tunerMode, .open)
    }

    func testNoTunerWhenTheBridgeDoesNotOfferOne() throws {
        let (c, t) = try ready(operations: ["snapshot", "catalog"])
        XCTAssertFalse(c.tunerAvailable)
        let sent = t.messages.count
        c.setTuner(.live)
        XCTAssertEqual(t.messages.count, sent)
    }
}
