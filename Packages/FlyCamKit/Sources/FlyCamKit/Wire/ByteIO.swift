// Little-endian byte reading and writing without Foundation's Data alignment pitfalls.

import Foundation

public struct ByteWriter: Sendable {
    public private(set) var bytes: [UInt8] = []

    public init(capacity: Int = 0) {
        bytes.reserveCapacity(capacity)
    }

    public mutating func write(_ raw: [UInt8]) { bytes.append(contentsOf: raw) }
    public mutating func write(_ v: UInt8) { bytes.append(v) }

    public mutating func writeLE<T: FixedWidthInteger>(_ v: T) {
        var x = v.littleEndian
        withUnsafeBytes(of: &x) { bytes.append(contentsOf: $0) }
    }

    public mutating func writeBE<T: FixedWidthInteger>(_ v: T) {
        var x = v.bigEndian
        withUnsafeBytes(of: &x) { bytes.append(contentsOf: $0) }
    }

    public mutating func writeF32(_ v: Float) { writeLE(v.bitPattern) }
    public mutating func writeF64(_ v: Double) { writeLE(v.bitPattern) }
}

public enum ByteReaderError: Error, Equatable {
    case unexpectedEnd(needed: Int, available: Int)
}

public struct ByteReader {
    public let bytes: [UInt8]
    public private(set) var offset: Int

    public init(_ bytes: [UInt8], offset: Int = 0) {
        self.bytes = bytes
        self.offset = offset
    }

    public var remaining: Int { bytes.count - offset }

    public mutating func read(count: Int) throws -> [UInt8] {
        guard remaining >= count else { throw ByteReaderError.unexpectedEnd(needed: count, available: remaining) }
        let out = Array(bytes[offset..<(offset + count)])
        offset += count
        return out
    }

    public mutating func readLE<T: FixedWidthInteger>(_: T.Type) throws -> T {
        let size = MemoryLayout<T>.size
        guard remaining >= size else { throw ByteReaderError.unexpectedEnd(needed: size, available: remaining) }
        var v: T = 0
        for i in 0..<size {
            v |= T(truncatingIfNeeded: bytes[offset + i]) << (8 * i)
        }
        offset += size
        return v
    }

    public mutating func readBE<T: FixedWidthInteger>(_: T.Type) throws -> T {
        let size = MemoryLayout<T>.size
        guard remaining >= size else { throw ByteReaderError.unexpectedEnd(needed: size, available: remaining) }
        var v: T = 0
        for i in 0..<size {
            v = (v << 8) | T(truncatingIfNeeded: bytes[offset + i])
        }
        offset += size
        return v
    }

    public mutating func readF32() throws -> Float { Float(bitPattern: try readLE(UInt32.self)) }
    public mutating func readF64() throws -> Double { Double(bitPattern: try readLE(UInt64.self)) }
}

extension Array where Element == UInt8 {
    public var hexString: String {
        let digits: [Character] = "0123456789abcdef".map { $0 }
        var s = ""
        s.reserveCapacity(count * 2)
        for b in self {
            s.append(digits[Int(b >> 4)])
            s.append(digits[Int(b & 0x0f)])
        }
        return s
    }

    public init?(hexString: String) {
        let chars = Array(hexString.utf8)
        guard chars.count % 2 == 0 else { return nil }
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: return c - 48
            case 97...102: return c - 87
            case 65...70: return c - 55
            default: return nil
            }
        }
        var out = [UInt8]()
        out.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        self = out
    }
}
