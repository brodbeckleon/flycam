// Incremental parsers for the two TCP channels. Feed bytes as they arrive (any chunking),
// collect complete packets or messages. Used by the Mac receiver; transport-agnostic.

import Foundation

public enum Channel: String, Sendable {
    case control = "FCC1"
    case media = "FCM1"

    public var preamble: [UInt8] { Array(rawValue.utf8) }

    public init?(preamble: [UInt8]) {
        guard let s = String(bytes: preamble, encoding: .ascii), let c = Channel(rawValue: s) else { return nil }
        self = c
    }
}

/// Reads the 4-byte preamble and reports which channel a new connection is.
public struct PreambleReader {
    private var buffer: [UInt8] = []

    public init() {}

    /// Returns the channel once 4 bytes have arrived, plus any bytes after the preamble.
    public mutating func feed(_ bytes: [UInt8]) throws -> (Channel, [UInt8])? {
        buffer += bytes
        guard buffer.count >= 4 else { return nil }
        let pre = Array(buffer.prefix(4))
        guard let ch = Channel(preamble: pre) else { throw WireError.badPreamble(pre) }
        let rest = Array(buffer.dropFirst(4))
        buffer = []
        return (ch, rest)
    }
}

/// Media stream after the preamble: back-to-back packets.
public struct MediaStreamParser {
    private var buffer: [UInt8] = []
    private var pendingHeader: MediaPacketHeader?

    public init() {}

    public var bufferedByteCount: Int { buffer.count }

    public mutating func feed(_ bytes: [UInt8]) throws -> [MediaPacket] {
        buffer += bytes
        var out = [MediaPacket]()
        var consumed = 0
        while true {
            if pendingHeader == nil {
                guard buffer.count - consumed >= MediaProtocol.headerSize else { break }
                var r = ByteReader(buffer, offset: consumed)
                pendingHeader = try MediaPacketHeader.decode(&r)
                consumed = r.offset
            }
            guard let h = pendingHeader else { break }
            let n = Int(h.payloadLength)
            guard buffer.count - consumed >= n else { break }
            out.append(MediaPacket(header: h, payload: Array(buffer[consumed..<(consumed + n)])))
            consumed += n
            pendingHeader = nil
        }
        if consumed > 0 { buffer.removeFirst(consumed) }
        return out
    }
}

/// Control stream after the preamble: length-prefixed JSON messages.
public struct ControlStreamParser {
    private var buffer: [UInt8] = []

    public init() {}

    public mutating func feed(_ bytes: [UInt8]) throws -> [ControlMessage] {
        buffer += bytes
        var out = [ControlMessage]()
        var consumed = 0
        while buffer.count - consumed >= 4 {
            var r = ByteReader(buffer, offset: consumed)
            let n = try r.readLE(UInt32.self)
            guard n > 0 else { throw WireError.emptyMessage }
            guard n <= ControlProtocol.maxMessage else { throw WireError.messageTooLarge(n) }
            guard r.remaining >= Int(n) else { break }
            out.append(try ControlProtocol.decodeJSON(try r.read(count: Int(n))))
            consumed = r.offset
        }
        if consumed > 0 { buffer.removeFirst(consumed) }
        return out
    }
}
