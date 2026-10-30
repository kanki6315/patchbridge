import XCTest
@testable import PatchbridgeCore

final class BluetoothLinkRetryTests: XCTestCase {
    func testSlowCancellationMustFinishBeforeReconnect() throws {
        var retry = BluetoothLinkRetry()
        let ticket = try XCTUnwrap(retry.begin(disconnected: false))
        // Even if the old backoff would have elapsed, the link is still cancelling.
        XCTAssertFalse(retry.connect(ticket: ticket))
        XCTAssertNil(retry.begin(disconnected: false))
        XCTAssertEqual(retry.attempts, 1)
        XCTAssertEqual(retry.disconnected(), ticket)
        XCTAssertNil(retry.disconnected(), "Duplicate callbacks must not schedule another connection")
        XCTAssertTrue(retry.connect(ticket: ticket))
        XCTAssertFalse(retry.connect(ticket: ticket))
    }

    func testAlreadyDisconnectedFailureDoesNotWaitForAnotherCallback() throws {
        var retry = BluetoothLinkRetry()
        let ticket = try XCTUnwrap(retry.begin(disconnected: true))
        XCTAssertFalse(retry.waitingForDisconnect)
        XCTAssertTrue(retry.connect(ticket: ticket))
    }

    func testStopInvalidatesDelayedRetryEvenWhenSameMacIsSelectedAgain() throws {
        var retry = BluetoothLinkRetry()
        let stale = try XCTUnwrap(retry.begin(disconnected: true))
        retry.reset()
        let current = try XCTUnwrap(retry.begin(disconnected: true))
        XCTAssertFalse(retry.connect(ticket: stale))
        XCTAssertTrue(retry.connect(ticket: current))
    }

    func testRetriesAreBoundedAndSuccessfulSessionResetsBudget() throws {
        var retry = BluetoothLinkRetry()
        for attempt in 1...BluetoothLinkRetry.limit {
            let ticket = try XCTUnwrap(retry.begin(disconnected: true))
            XCTAssertEqual(retry.attempts, attempt)
            XCTAssertTrue(retry.connect(ticket: ticket))
        }
        XCTAssertNil(retry.begin(disconnected: true))
        retry.reset()
        XCTAssertNotNil(retry.begin(disconnected: false))
        XCTAssertEqual(retry.attempts, 1)
    }

    func testStopWhileCancellingIgnoresLateDisconnect() throws {
        var retry = BluetoothLinkRetry()
        let ticket = try XCTUnwrap(retry.begin(disconnected: false))
        retry.reset()
        XCTAssertNil(retry.disconnected())
        XCTAssertFalse(retry.connect(ticket: ticket))
        XCTAssertFalse(retry.pending)
    }
}
