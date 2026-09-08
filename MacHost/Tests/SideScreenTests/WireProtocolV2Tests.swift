import XCTest
@testable import SideScreen

final class WireProtocolV2Tests: XCTestCase {
    func testEnvelopeRoundTrip() {
        let env = WireV2.envelope(.frameChunk, payloadCount: 0x012345)
        XCTAssertEqual(env.count, WireV2.envelopeSize)
        let parsed = WireV2.parseEnvelope(env)
        XCTAssertEqual(parsed?.type, WireV2.MsgType.frameChunk.rawValue)
        XCTAssertEqual(parsed?.length, 0x012345)
    }

    func testEnvelopeZeroLength() {
        let env = WireV2.envelope(.nop, payloadCount: 0)
        let parsed = WireV2.parseEnvelope(env)
        XCTAssertEqual(parsed?.type, WireV2.MsgType.nop.rawValue)
        XCTAssertEqual(parsed?.length, 0)
    }

    func testEnvelopeShortInputReturnsNil() {
        XCTAssertNil(WireV2.parseEnvelope(Data([1, 2, 3])))
    }

    func testFrameBeginRoundTrip() {
        let begin = WireV2.FrameBegin(
            frameId: 0xDEADBEEF,
            totalSize: 1_234_567,
            flags: WireV2.FrameFlags.keyframe | WireV2.FrameFlags.lengthPrefixed,
            captureNs: 0x0102030405060708,
            encodeDoneNs: 0x1112131415161718,
            sendStartNs: 0xFFEEDDCCBBAA9988)
        let encoded = WireV2.encodeFrameBegin(begin)
        XCTAssertEqual(encoded.count, WireV2.envelopeSize + WireV2.frameBeginPayloadSize)

        let parsedEnv = WireV2.parseEnvelope(encoded)
        XCTAssertEqual(parsedEnv?.type, WireV2.MsgType.frameBegin.rawValue)
        XCTAssertEqual(parsedEnv?.length, WireV2.frameBeginPayloadSize)

        let payload = encoded.dropFirst(WireV2.envelopeSize)
        XCTAssertEqual(WireV2.parseFrameBegin(Data(payload)), begin)
    }

    func testChunkHeaderCarriesFrameIdAndLength() {
        let header = WireV2.encodeChunkHeader(frameId: 7, chunkBytes: 16 * 1024)
        let parsed = WireV2.parseEnvelope(header)
        XCTAssertEqual(parsed?.type, WireV2.MsgType.frameChunk.rawValue)
        XCTAssertEqual(parsed?.length, 4 + 16 * 1024)
        // frameId lives in the first 4 payload bytes, big endian.
        let bytes = [UInt8](header)
        XCTAssertEqual(bytes[4...7].map { $0 }, [0, 0, 0, 7])
    }

    func testPongLayout() {
        let pong = WireV2.encodePong(t0: 1, t1: 2, t2: 3)
        XCTAssertEqual(pong.count, WireV2.envelopeSize + 24)
        let bytes = [UInt8](pong)
        XCTAssertEqual(bytes[0], WireV2.MsgType.pong.rawValue)
        XCTAssertEqual(bytes[11], 1) // t0 LSB (big endian)
        XCTAssertEqual(bytes[19], 2) // t1 LSB
        XCTAssertEqual(bytes[27], 3) // t2 LSB
    }

    func testVideoConfigCarriesParameterSets() {
        let sets = Data([0, 0, 0, 1, 0x40, 0x01, 0xAA])
        let config = WireV2.encodeVideoConfig(codecId: 0, nalLengthSize: 4, parameterSets: sets)
        let parsed = WireV2.parseEnvelope(config)
        XCTAssertEqual(parsed?.type, WireV2.MsgType.videoConfig.rawValue)
        XCTAssertEqual(parsed?.length, 2 + sets.count)
        XCTAssertEqual(Data(config.suffix(sets.count)), sets)
    }

    func testDisplayConfigMatchesV1PayloadLayout() {
        let config = WireV2.encodeDisplayConfig(width: 2560, height: 1600, transform: 1090)
        let bytes = [UInt8](config)
        XCTAssertEqual(bytes[0], WireV2.MsgType.displayConfig.rawValue)
        // width 2560 = 0x0A00 BE at payload offset 0
        XCTAssertEqual(Array(bytes[4...7]), [0, 0, 0x0A, 0])
        // height 1600 = 0x0640
        XCTAssertEqual(Array(bytes[8...11]), [0, 0, 0x06, 0x40])
    }
}
