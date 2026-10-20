import XCTest
@testable import PatchbridgeCore

final class ExchangeTests: XCTestCase {
    let request: [String: Any] = ["id": "one", "version": 1, "operation": "snapshot"]
    let response: [String: Any] = ["id": "one", "version": 1, "status": "confirmed"]
    func testNotificationBeforeLastAcknowledgmentCannotStartNextCommand() throws {
        var exchange = CommandExchange()
        _ = try exchange.begin(request, limit: 512, transfer: 1)
        try exchange.accept(response)
        XCTAssertNil(exchange.completed())
        XCTAssertThrowsError(try exchange.begin(request, limit: 512, transfer: 2))
        XCTAssertNil(try exchange.acknowledge())
        XCTAssertEqual(exchange.completed()?["id"] as? String, "one")
        XCTAssertFalse(exchange.isBusy)
    }
    func testAcknowledgmentsBeforeNotification() throws {
        var exchange = CommandExchange()
        let first = try exchange.begin(request, limit: 20, transfer: 1)
        var receiver = ChunkReceiver()
        var decoded = try receiver.receive(first)
        while let chunk = try exchange.acknowledge() { decoded = try receiver.receive(chunk) }
        XCTAssertNotNil(decoded)
        XCTAssertNil(exchange.completed())
        try exchange.accept(response)
        XCTAssertNotNil(exchange.completed())
    }
    func testWrongAndDuplicateResponseCannotCompleteCommand() throws {
        var exchange = CommandExchange()
        _ = try exchange.begin(request, limit: 512, transfer: 1)
        XCTAssertThrowsError(try exchange.accept(["version": 1, "id": "old"]))
        XCTAssertThrowsError(try exchange.accept(["version": 2, "id": "one"]))
        try exchange.accept(response)
        XCTAssertThrowsError(try exchange.accept(response))
        exchange.reset()
        XCTAssertThrowsError(try exchange.acknowledge())
        XCTAssertThrowsError(try exchange.accept(response))
    }
}
