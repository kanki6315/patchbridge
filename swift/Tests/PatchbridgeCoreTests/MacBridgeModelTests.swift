import XCTest
@testable import PatchbridgeCore

final class MacBridgeModelTests: XCTestCase {
    func waitFor(_ model: MacBridgeModel, _ phase: MacBridgeModel.Phase, action: () -> Void) {
        let done = expectation(description: "Shell reaches \(phase)")
        model.onChange = { if model.phase == phase && !model.busy { done.fulfill(); model.onChange = nil } }
        action(); wait(for: [done], timeout: 10)
        XCTAssertEqual(model.phase, phase)
    }
    func testRealSimulatorApprovalDenyDisconnectFailureAndRestart() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let backend = BundledOfflineBackend(makeHelper: {
            try HelperClient(python: "/opt/homebrew/bin/python3", source: root.appendingPathComponent("src").path)
        })
        let model = MacBridgeModel(backend: backend); defer { model.shutdown() }
        model.approve(); XCTAssertEqual(model.phase, .stopped)
        waitFor(model, .running) { model.start() }
        waitFor(model, .awaitingApproval) { model.requestPhone() }
        waitFor(model, .running) { model.disconnectPhone() }
        waitFor(model, .awaitingApproval) { model.requestPhone() }
        waitFor(model, .connected) { model.approve() }
        waitFor(model, .connected) { model.refresh() }
        waitFor(model, .running) { model.disconnectPhone() }
        waitFor(model, .awaitingApproval) { model.requestPhone() }
        waitFor(model, .connected) { model.approve() }
        waitFor(model, .failed) { model.simulateFailure() }
        waitFor(model, .running) { model.start() }
        XCTAssertEqual(model.phase, .running) // No prior approval survives restart.
        waitFor(model, .stopped) { model.stop() }
    }
    func testStopDuringLaunchCannotRestoreRunningState() {
        final class SlowBackend: OfflineBridgeBackend {
            var stops = 0
            func start() throws { Thread.sleep(forTimeInterval: 0.1) }
            func requestPhone() throws {}
            func refresh() throws {}
            func stop() { stops += 1 }
            func interruptHelper() {}
        }
        let backend = SlowBackend(); let model = MacBridgeModel(backend: backend)
        waitFor(model, .stopped) { model.start(); model.stop() }
        model.shutdown(); XCTAssertGreaterThan(backend.stops, 0)
    }
    func testStartupFailureIsRecoverableAndCannotApprove() {
        let model = MacBridgeModel(backend: BundledOfflineBackend(makeHelper: { throw BridgeFailure.disconnected }))
        defer { model.shutdown() }
        waitFor(model, .failed) { model.start() }
        model.requestPhone(); model.approve(); XCTAssertEqual(model.phase, .failed)
        waitFor(model, .stopped) { model.stop() }
    }
}

extension MacBridgeModelTests {
    func testPackagedHelperWorksThroughShellApproval() throws {
        guard ProcessInfo.processInfo.environment["PATCHBRIDGE_TEST_BUNDLE"] == "1" else { throw XCTSkip("Build the package and set PATCHBRIDGE_TEST_BUNDLE=1") }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bundle = try XCTUnwrap(Bundle(url: root.appendingPathComponent("dist/Patchbridge.app")))
        let model = MacBridgeModel(backend: BundledOfflineBackend(makeHelper: { try HelperClient(bundle: bundle) }))
        defer { model.shutdown() }
        waitFor(model, .running) { model.start() }
        waitFor(model, .awaitingApproval) { model.requestPhone() }
        waitFor(model, .connected) { model.approve() }
        waitFor(model, .stopped) { model.stop() }
        waitFor(model, .running) { model.start() }
        XCTAssertNotEqual(model.phase, .connected)
    }
}

extension MacBridgeModelTests {
    func testShellAutomaticallyRecoversDeviceButKeepsApprovalCode() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let model = MacBridgeModel(backend: BundledOfflineBackend(makeHelper: {
            try HelperClient(python: "/opt/homebrew/bin/python3", source: root.appendingPathComponent("src").path)
        }))
        defer { model.shutdown() }
        waitFor(model, .running) { model.start() }
        waitFor(model, .awaitingApproval) { model.requestPhone() }
        let code = model.presentation.approvalCode
        XCTAssertFalse(code.isEmpty)
        waitFor(model, .connected) { model.approve() }
        XCTAssertNotNil(model.presentation.preset)
        waitFor(model, .recovering) { model.simulateUSBRemoval() }
        waitFor(model, .connected) {}
        XCTAssertEqual(model.presentation.approvalCode, code)
        waitFor(model, .stopped) { model.stop() }
        XCTAssertNil(model.presentation.preset)
        XCTAssertTrue(model.presentation.approvalCode.isEmpty)
    }
}

extension MacBridgeModelTests {
    func testRecentEditsUseActualResultsAndRemainBoundedAndClearable() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let backend = BundledOfflineBackend(makeHelper: { try HelperClient(python: "/opt/homebrew/bin/python3", source: root.appendingPathComponent("src").path) })
        try backend.start(); defer { backend.stop() }
        try backend.requestPhone(); try backend.approvePending()
        XCTAssertTrue(backend.presentation.recentEdits.isEmpty)
        try backend.editSimulation(value: 7.5, stale: false)
        XCTAssertEqual(backend.presentation.recentEdits.first?.outcome, .confirmed)
        XCTAssertEqual(backend.presentation.recentEdits.first?.value, "7.5")
        XCTAssertEqual(backend.presentation.recentEdits.first?.title, "Gain · Simulated amp")
        try backend.editSimulation(value: 6, stale: true)
        XCTAssertEqual(backend.presentation.recentEdits.first?.outcome, .rejected)
        XCTAssertNil(backend.presentation.recentEdits.first?.value)
        for _ in 0..<15 { try backend.editSimulation(value: 7, stale: false) }
        XCTAssertEqual(backend.presentation.recentEdits.count, 12)
        backend.interruptHelper()
        XCTAssertThrowsError(try backend.editSimulation(value: 8, stale: false))
        XCTAssertEqual(backend.presentation.recentEdits.first?.outcome, .unknown)
        backend.stop()
        XCTAssertEqual(backend.presentation.recentEdits.first?.outcome, .unknown)
        let report = String(data: try Diagnostics.shared.reportData(), encoding: .utf8)!
        XCTAssertFalse(report.contains("Simulated amp")); XCTAssertFalse(report.contains("Simulation 1"))
        backend.clearRecentEdits(); XCTAssertTrue(backend.presentation.recentEdits.isEmpty)
    }
    func testHistoryNeverCallsUnknownOutcomesRejectedOrConfirmsMissingReadback() {
        let request: [String: Any] = ["operation": "set_parameter", "payload": ["block_id": "amp", "parameter_id": "gain", "value": 5]]
        for code in ["adapter_failure", "disconnected", "timeout"] {
            let entry = RecentBridgeEdit(request: request, response: ["status": "error", "error": ["code": code]], snapshot: nil, catalog: nil)
            XCTAssertEqual(entry.outcome, .unknown)
        }
        let malformed = RecentBridgeEdit(request: request, response: ["status": "confirmed"], snapshot: nil, catalog: nil)
        XCTAssertEqual(malformed.outcome, .unknown)
        let adjusted = RecentBridgeEdit(request: request, response: ["status": "confirmed", "result": ["state": ["scene": "A", "blocks": [["id": "amp", "scenes": ["A": ["parameters": ["gain": 4]]]]]]]], snapshot: nil, catalog: nil)
        XCTAssertEqual(adjusted.outcome, .adjusted)
    }
    func testHistoryTitlesCaptureBlocksByTheCaptureName() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("tests/fixtures/qc-editor.json"))) as! [String: Any]
        var snapshot = fixture["snapshot"] as! [String: Any]
        let catalog = fixture["catalog"] as! [String: Any]
        let request: [String: Any] = ["operation": "set_parameter", "payload": ["block_id": "0:2", "parameter_id": "1", "value": 0.5]]
        XCTAssertEqual(RecentBridgeEdit(request: request, response: nil, snapshot: snapshot, catalog: catalog).title, "Bass · OG TS808")
        var blocks = snapshot["blocks"] as! [[String: Any]]
        let i = blocks.firstIndex { $0["id"] as? String == "0:2" }!
        var scenes = blocks[i]["scenes"] as! [String: [String: Any]]
        var parameters = scenes["F"]!["parameters"] as! [String: Any]
        parameters["5"] = "OG TS808"; scenes["F"]!["parameters"] = parameters
        blocks[i]["scenes"] = scenes; snapshot["blocks"] = blocks
        XCTAssertEqual(RecentBridgeEdit(request: request, response: nil, snapshot: snapshot, catalog: catalog).title, "Bass · Eltron 30")
    }
}

extension MacBridgeModelTests {
    func testSimulationAddsASecondDeviceWhoseEditMakesTheFirstReload() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let backend = BundledOfflineBackend(makeHelper: { try HelperClient(python: "/opt/homebrew/bin/python3", source: root.appendingPathComponent("src").path) })
        try backend.start(); defer { backend.stop() }
        try backend.requestPhone(); try backend.approvePending(trust: true)
        try backend.requestSecondDevice()
        XCTAssertEqual(backend.presentation.phoneName, "Simulated iPad")
        XCTAssertEqual(backend.presentation.devices.map(\.state), [.connected, .awaitingApproval])
        try backend.approvePending()
        XCTAssertEqual(backend.presentation.connected.count, 2)
        XCTAssertEqual(backend.presentation.trusted.count, 1)
        try backend.editFromOtherDevice()
        XCTAssertEqual(backend.presentation.recentEdits.first?.device, "Simulated iPad")
        XCTAssertEqual(backend.presentation.recentEdits.first?.outcome, .confirmed)
        try backend.editSimulation(value: 7.5, stale: false) // The iPhone hasn't reloaded yet.
        XCTAssertEqual(backend.presentation.recentEdits.first?.outcome, .rejected)
        XCTAssertEqual(backend.presentation.recentEdits.first?.detail, "Device state changed")
        try backend.editSimulation(value: 7.5, stale: false) // It has now.
        XCTAssertEqual(backend.presentation.recentEdits.first?.outcome, .confirmed)
        // USB recovery on one device brings the other along.
        try backend.interruptDevice()
        Thread.sleep(forTimeInterval: 2.1)
        try backend.refresh()
        XCTAssertFalse(backend.presentation.recovering)
        XCTAssertEqual(backend.presentation.connected.count, 2)
        let pad = try XCTUnwrap(backend.presentation.devices.last)
        backend.disconnect(device: pad.id, connection: pad.connection)
        XCTAssertEqual(backend.presentation.connected.map(\.state), [.connected])
        XCTAssertNotNil(backend.presentation.preset)
        try backend.editSimulation(value: 6, stale: false)
        XCTAssertEqual(backend.presentation.recentEdits.first?.outcome, .confirmed)
    }
}
