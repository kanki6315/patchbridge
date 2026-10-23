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
        try backend.editSimulation(value: 7.5, stale: false) // The iPhone hasn't reloaded yet.
        try backend.editSimulation(value: 7.5, stale: false) // It has now.
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
    }
}
