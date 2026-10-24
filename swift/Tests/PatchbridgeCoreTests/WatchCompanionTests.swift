import XCTest
@testable import PatchbridgeCore

final class WatchCompanionTests: XCTestCase {
    func testCommandExpiresAndCannotBeReplayed() {
        var gate = WatchCommandGate()
        let now = Date(timeIntervalSince1970: 100)
        let token = gate.issue(context: Data("preset-A".utf8), now: now)
        let command = WatchRequest(action: "scene", token: token, target: "F")
        XCTAssertTrue(gate.accepts(command, now: now.addingTimeInterval(1)))
        XCTAssertFalse(gate.accepts(command, now: now.addingTimeInterval(2)))
        let expired = WatchRequest(action: "scene", token: token, target: "G")
        _ = gate.issue(context: Data("preset-A".utf8), now: now.addingTimeInterval(6), renew: false)
        XCTAssertFalse(gate.accepts(expired, now: now.addingTimeInterval(6)))
    }
    func testChangedContextAndProtocolRejectOldCommands() {
        var gate = WatchCommandGate()
        let token = gate.issue(context: Data("preset-A-scene-F".utf8))
        _ = gate.issue(context: Data("preset-B-scene-F".utf8), renew: false)
        XCTAssertFalse(gate.accepts(WatchRequest(action: "parameter", token: token, target: "amp/gain", value: 5)))
        let fresh = gate.issue(context: Data("preset-B-scene-F".utf8))
        XCTAssertFalse(gate.accepts(WatchRequest(version: 2, action: "scene", token: fresh, target: "A")))
        XCTAssertTrue(gate.accepts(WatchRequest(action: "scene", token: fresh, target: "A")))
    }
    func testFreshStatusCannotExtendAnOlderCommandLease() {
        var gate = WatchCommandGate()
        let now = Date(timeIntervalSince1970: 100)
        let context = Data("same-preset".utf8)
        let old = gate.issue(context: context, now: now)
        let identity = gate.contextID
        let fresh = gate.issue(context: context, now: now.addingTimeInterval(6))
        XCTAssertEqual(gate.contextID, identity, "A Crown draft survives ordinary status polls")
        XCTAssertNotEqual(old, fresh)
        XCTAssertFalse(gate.accepts(WatchRequest(action: "scene", token: old, target: "A"), now: now.addingTimeInterval(6)))
        XCTAssertTrue(gate.accepts(WatchRequest(action: "scene", token: fresh, target: "A"), now: now.addingTimeInterval(6)))
    }
    func testReplyRoundTripPreservesUnknownMuteAndPitch() throws {
        var state = WatchState()
        state.presetName = "Dirty Riffage"; state.dirty = true
        let reply = WatchReply(state: state, error: "Open Patchbridge on iPhone.")
        let decoded = try JSONDecoder().decode(WatchReply.self, from: JSONEncoder().encode(reply))
        XCTAssertNil(decoded.state.muted)
        XCTAssertNil(decoded.state.cents)
        XCTAssertTrue(decoded.state.dirty)
        XCTAssertEqual(decoded.error, reply.error)
    }
}
