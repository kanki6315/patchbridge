import Foundation

/// Tracks cancellation separately from backoff: CoreBluetooth cancellation is asynchronous.
/// Tickets prevent delayed work from reconnecting a stopped or superseded session.
struct BluetoothLinkRetry {
    static let limit = 3
    private(set) var attempts = 0
    private(set) var ticket = 0
    private(set) var pending = false
    private(set) var waitingForDisconnect = false

    mutating func begin(disconnected: Bool) -> Int? {
        guard !pending, attempts < Self.limit else { return nil }
        attempts += 1; ticket += 1; pending = true
        waitingForDisconnect = !disconnected
        return ticket
    }

    mutating func disconnected() -> Int? {
        guard pending, waitingForDisconnect else { return nil }
        waitingForDisconnect = false
        return ticket
    }

    mutating func connect(ticket: Int) -> Bool {
        guard pending, !waitingForDisconnect, self.ticket == ticket else { return false }
        pending = false
        return true
    }

    mutating func reset() {
        ticket += 1; attempts = 0; pending = false; waitingForDisconnect = false
    }
}
