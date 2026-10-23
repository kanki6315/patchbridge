import Foundation
import Compression

public enum ChunkFailure: Error { case malformed, overflow, outOfOrder }

/// Header: version u8, transfer u32 BE, sequence u16 BE, final u8. Version 1 carries the
/// message as is; version 2 carries it deflated (raw DEFLATE), sent only to a phone that
/// said in its hello that it reads it.
public enum Chunks {
    public static func split(_ data: Data, limit: Int, transfer: UInt32, deflate: Bool = false) throws -> [Data] {
        guard limit > 8, data.count <= 1_048_576 else { throw ChunkFailure.overflow }
        let packed = deflate ? Self.deflate(data) : nil
        let body = packed ?? data, version: UInt8 = packed == nil ? 1 : 2
        let size = limit - 8
        let count = max(1, (body.count + size - 1) / size)
        guard count <= 65536 else { throw ChunkFailure.overflow }
        return (0..<count).map { n in
            var chunk = Data([version, UInt8(truncatingIfNeeded: transfer >> 24), UInt8(truncatingIfNeeded: transfer >> 16), UInt8(truncatingIfNeeded: transfer >> 8), UInt8(truncatingIfNeeded: transfer), UInt8(truncatingIfNeeded: n >> 8), UInt8(truncatingIfNeeded: n), n == count-1 ? 1 : 0])
            chunk.append(body.dropFirst(n * size).prefix(size)); return chunk
        }
    }
    /// Worth it only when the message spans several chunks and actually shrinks.
    static func deflate(_ data: Data) -> Data? {
        guard data.count >= 512 else { return nil }
        var out = Data(count: data.count)
        let written = out.withUnsafeMutableBytes { dst in data.withUnsafeBytes { src in
            compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, data.count,
                                      src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
        } }
        guard written > 0, written < data.count else { return nil }
        return out.prefix(written)
    }
    /// Nil when the data is not valid DEFLATE or inflates past `limit` bytes.
    static func inflate(_ data: Data, limit: Int) -> Data? {
        guard !data.isEmpty else { return nil }
        var out = Data(count: limit + 1)
        let written = out.withUnsafeMutableBytes { dst in data.withUnsafeBytes { src in
            compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, limit + 1,
                                      src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
        } }
        guard written > 0, written <= limit else { return nil }
        return out.prefix(written)
    }
}

public struct ChunkReceiver {
    private var transfer: UInt32?
    private var version: UInt8 = 1
    private var next = 0
    private var bytes = Data()
    private var expires = Date.distantPast
    /// Largest message accepted, in bytes, after inflating. The Mac lowers it for devices it hasn't admitted.
    public var limit: Int
    public init(limit: Int = 1_048_576) { self.limit = limit }
    public mutating func reset() { transfer = nil; next = 0; bytes.removeAll() }
    public mutating func receive(_ data: Data, now: Date = Date()) throws -> Data? {
        if now >= expires { reset() }
        let b = [UInt8](data)
        guard b.count >= 8, b[0] == 1 || b[0] == 2, b[7] <= 1 else { reset(); throw ChunkFailure.malformed }
        let id = b[1...4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let seq = Int(b[5]) * 256 + Int(b[6])
        if transfer == nil { guard seq == 0 else { throw ChunkFailure.outOfOrder }; transfer = id; version = b[0]; expires = now.addingTimeInterval(5) }
        guard transfer == id, seq == next, b[0] == version else { reset(); throw ChunkFailure.outOfOrder }
        guard bytes.count + b.count - 8 <= limit else { reset(); throw ChunkFailure.overflow }
        bytes.append(contentsOf: b.dropFirst(8)); next += 1
        expires = now.addingTimeInterval(5) // Inactivity deadline, not a total cap on large BLE snapshots.
        guard b[7] == 1 else { return nil }
        let result = bytes, deflated = version == 2; reset()
        guard deflated else { return result }
        guard let inflated = Chunks.inflate(result, limit: limit) else { throw ChunkFailure.malformed }
        return inflated
    }
}
