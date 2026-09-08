import Foundation

/// Protocol v2 (negotiated over the v1 stream, then framed).
///
/// Negotiation: the client sends v1 type 12 (payload-free — old hosts consume
/// one byte harmlessly, the same convention as types 8/9) BEFORE type 8. A v2
/// host answers with v1 type 13 + [version], after which BOTH directions
/// speak enveloped v2 exclusively. Old clients never send 12, old hosts never
/// answer 13, so both legacy pairings keep speaking byte-identical v1.
///
/// Envelope: [type u8][len u24 BE][payload len bytes]. Unknown types are
/// skipped by length — protocol growth no longer needs the high-bit padding
/// tricks of v1 (see v1 type 11).
///
/// Video rides as FRAME_BEGIN + n×FRAME_CHUNK so small control messages
/// (pong, display config) can preempt between chunks instead of queueing
/// behind a multi-megabyte keyframe (head-of-line blocking).
enum WireV2 {
    /// v1 message types used for the handshake.
    static let negotiationRequest: UInt8 = 12
    static let negotiationAccept: UInt8 = 13
    static let version: UInt8 = 2

    static let envelopeSize = 4
    /// Chunk payload ceiling per transport. TCP favors small chunks (finer
    /// preemption); USB bulk favors bigger writes (fewer syscalls/URBs).
    static let tcpChunkSize = 16 * 1024
    static let aoaChunkSize = 64 * 1024

    enum MsgType: UInt8 {
        case displayConfig = 1  // w u32, h u32, transform u32 (BE, as v1)
        case touch = 2          // count u8, count×(x f32, y f32), action i32 (LE, as v1)
        case ping = 4           // t0 u64 — client clock, echoed verbatim
        case pong = 5           // t0 u64, t1 u64, t2 u64 (client send, host recv, host send)
        case frameBegin = 6     // frameId u32, totalSize u32, flags u8, capture/encodeDone/sendStart u64×3
        case frameChunk = 7     // frameId u32, then chunk bytes
        case keyframeRequest = 8 // flags u8 (bit0 = force)
        case videoConfig = 9    // codecId u8, nalLengthSize u8, Annex-B parameter sets
        case clientStats = 10   // reserved: client→host 1 Hz stats report
        case nop = 11           // padding (AOA uplink 512-multiple avoidance)
    }

    struct FrameFlags {
        static let keyframe: UInt8 = 1
        /// Payload NAL units are 4-byte length-prefixed (AVCC/HVCC) instead of
        /// Annex-B: the client rewrites lengths to start codes in place while
        /// copying into the codec input buffer.
        static let lengthPrefixed: UInt8 = 2
    }

    struct FrameBegin: Equatable {
        let frameId: UInt32
        let totalSize: UInt32
        let flags: UInt8
        let captureNs: UInt64
        let encodeDoneNs: UInt64
        let sendStartNs: UInt64
    }

    static let frameBeginPayloadSize = 33

    static func envelope(_ type: MsgType, payloadCount: Int) -> Data {
        precondition(payloadCount >= 0 && payloadCount < (1 << 24), "payload too large for u24 length")
        var data = Data(capacity: envelopeSize)
        data.append(type.rawValue)
        data.append(UInt8((payloadCount >> 16) & 0xFF))
        data.append(UInt8((payloadCount >> 8) & 0xFF))
        data.append(UInt8(payloadCount & 0xFF))
        return data
    }

    /// Parses an envelope header. Returns nil until 4 bytes are available.
    /// Unknown types still parse (caller skips `length` bytes).
    static func parseEnvelope(_ data: Data) -> (type: UInt8, length: Int)? {
        guard data.count >= envelopeSize else { return nil }
        let bytes = [UInt8](data.prefix(envelopeSize))
        let length = (Int(bytes[1]) << 16) | (Int(bytes[2]) << 8) | Int(bytes[3])
        return (bytes[0], length)
    }

    static func encodeFrameBegin(_ begin: FrameBegin) -> Data {
        var data = envelope(.frameBegin, payloadCount: frameBeginPayloadSize)
        appendBE(begin.frameId, to: &data)
        appendBE(begin.totalSize, to: &data)
        data.append(begin.flags)
        appendBE(begin.captureNs, to: &data)
        appendBE(begin.encodeDoneNs, to: &data)
        appendBE(begin.sendStartNs, to: &data)
        return data
    }

    /// Payload-only parse (envelope already consumed).
    static func parseFrameBegin(_ payload: Data) -> FrameBegin? {
        guard payload.count >= frameBeginPayloadSize else { return nil }
        let b = [UInt8](payload)
        return FrameBegin(
            frameId: readBE32(b, 0),
            totalSize: readBE32(b, 4),
            flags: b[8],
            captureNs: readBE64(b, 9),
            encodeDoneNs: readBE64(b, 17),
            sendStartNs: readBE64(b, 25))
    }

    static func encodeChunkHeader(frameId: UInt32, chunkBytes: Int) -> Data {
        var data = envelope(.frameChunk, payloadCount: 4 + chunkBytes)
        appendBE(frameId, to: &data)
        return data
    }

    static func encodePong(t0: UInt64, t1: UInt64, t2: UInt64) -> Data {
        var data = envelope(.pong, payloadCount: 24)
        appendBE(t0, to: &data)
        appendBE(t1, to: &data)
        appendBE(t2, to: &data)
        return data
    }

    static func encodeVideoConfig(codecId: UInt8, nalLengthSize: UInt8, parameterSets: Data) -> Data {
        var data = envelope(.videoConfig, payloadCount: 2 + parameterSets.count)
        data.append(codecId)
        data.append(nalLengthSize)
        data.append(parameterSets)
        return data
    }

    static func encodeDisplayConfig(width: Int, height: Int, transform: Int) -> Data {
        var data = envelope(.displayConfig, payloadCount: 12)
        appendBE(UInt32(width), to: &data)
        appendBE(UInt32(height), to: &data)
        appendBE(UInt32(transform), to: &data)
        return data
    }

    private static func appendBE<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var big = value.bigEndian
        withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
    }

    private static func readBE32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16) |
            (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
    }

    private static func readBE64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<8 {
            value = (value << 8) | UInt64(bytes[offset + i])
        }
        return value
    }
}
