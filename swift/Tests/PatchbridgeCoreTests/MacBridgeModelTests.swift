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
            func approve() throws {}
            func revoke() {}
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
        let bundle = try XCTUnwrap(Bundle(url: root.appendingPathComponent("dist/Patchbridge Offline.app")))
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
