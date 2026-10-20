import Foundation

public enum ChunkFailure: Error { case malformed, overflow, outOfOrder }

/// Header: version u8, transfer u32 BE, sequence u16 BE, final u8.
public enum Chunks {
    public static func split(_ data: Data, limit: Int, transfer: UInt32) throws -> [Data] {
        guard limit > 8, data.count <= 1_048_576 else { throw ChunkFailure.overflow }
        let size = limit - 8
        let count = max(1, (data.count + size - 1) / size)
        guard count <= 65536 else { throw ChunkFailure.overflow }
        return (0..<count).map { n in
            var chunk = Data([1, UInt8(truncatingIfNeeded: transfer >> 24), UInt8(truncatingIfNeeded: transfer >> 16), UInt8(truncatingIfNeeded: transfer >> 8), UInt8(truncatingIfNeeded: transfer), UInt8(truncatingIfNeeded: n >> 8), UInt8(truncatingIfNeeded: n), n == count-1 ? 1 : 0])
            chunk.append(data.dropFirst(n * size).prefix(size)); return chunk
        }
    }
}

public struct ChunkReceiver {
    private var transfer: UInt32?
    private var next = 0
    private var bytes = Data()
    private var expires = Date.distantPast
    /// Largest message accepted, in bytes. The Mac lowers it for devices it hasn't admitted.
    public var limit: Int
    public init(limit: Int = 1_048_576) { self.limit = limit }
    public mutating func reset() { transfer = nil; next = 0; bytes.removeAll() }
    public mutating func receive(_ data: Data, now: Date = Date()) throws -> Data? {
        if now >= expires { reset() }
        let b = [UInt8](data)
        guard b.count >= 8, b[0] == 1, b[7] <= 1 else { reset(); throw ChunkFailure.malformed }
        let id = b[1...4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let seq = Int(b[5]) * 256 + Int(b[6])
        if transfer == nil { guard seq == 0 else { throw ChunkFailure.outOfOrder }; transfer = id; expires = now.addingTimeInterval(5) }
        guard transfer == id, seq == next else { reset(); throw ChunkFailure.outOfOrder }
        guard bytes.count + b.count - 8 <= limit else { reset(); throw ChunkFailure.overflow }
        bytes.append(contentsOf: b.dropFirst(8)); next += 1
        expires = now.addingTimeInterval(5) // Inactivity deadline, not a total cap on large BLE snapshots.
        if b[7] == 1 { let result = bytes; reset(); return result }
        return nil
    }
}
