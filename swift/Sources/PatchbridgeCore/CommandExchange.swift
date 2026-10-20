import Foundation

public enum ExchangeFailure: Error { case busy, malformed, unexpectedAcknowledgment, unexpectedResponse }

/// A response can arrive before the final ATT write acknowledgment. Do not let
/// the next command start until both have arrived; never retry an uncertain write.
public struct CommandExchange {
    public private(set) var isBusy = false
    private var requestID: String?
    private var chunks: [Data] = []
    private var index = 0
    private var awaitingAcknowledgment = false
    private var response: [String: Any]?
    public init() {}
    public mutating func begin(_ message: [String: Any], limit: Int, transfer: UInt32) throws -> Data {
        guard !isBusy else { throw ExchangeFailure.busy }
        guard let id = message["id"] as? String, !id.isEmpty, id.count <= 128 else { throw ExchangeFailure.malformed }
        let data = try JSONSerialization.data(withJSONObject: message)
        let packets = try Chunks.split(data, limit: limit, transfer: transfer)
        requestID = id; chunks = packets; index = 1
        response = nil; isBusy = true; awaitingAcknowledgment = true
        return packets[0]
    }
    public mutating func acknowledge() throws -> Data? {
        guard isBusy, awaitingAcknowledgment else { throw ExchangeFailure.unexpectedAcknowledgment }
        awaitingAcknowledgment = false
        if index < chunks.count {
            let packet = chunks[index]; index += 1; awaitingAcknowledgment = true
            return packet
        }
        return nil
    }
    public mutating func accept(_ message: [String: Any]) throws {
        guard isBusy, response == nil, message["version"] as? Int == 1,
              message["id"] as? String == requestID else { throw ExchangeFailure.unexpectedResponse }
        response = message
    }
    public mutating func completed() -> [String: Any]? {
        guard !awaitingAcknowledgment, index == chunks.count, let response else { return nil }
        reset(); return response
    }
    public mutating func reset() {
        isBusy = false; requestID = nil; chunks.removeAll(); index = 0
        awaitingAcknowledgment = false; response = nil
    }
}
