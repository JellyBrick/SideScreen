import Network
import XCTest
@testable import SideScreen

/// Loopback integration tests for the v1/v2 protocol switch-over: a real
/// StreamingServer on a test port, a raw NWConnection as the client.
final class StreamingServerProtocolTests: XCTestCase {
    private var server: StreamingServer!
    private var connection: NWConnection!
    private var received = Data()
    private let receiveLock = NSLock()
    private static var nextPort: UInt16 = 54871

    override func setUp() {
        super.setUp()
        Self.nextPort += 1
        server = StreamingServer(port: Self.nextPort)
        server.setDisplaySize(width: 1920, height: 1080)
        server.start()

        connection = NWConnection(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: Self.nextPort)!,
            using: .tcp)
        let ready = expectation(description: "connected")
        connection.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        connection.start(queue: DispatchQueue(label: "test.client"))
        wait(for: [ready], timeout: 5)
        startDraining()
    }

    override func tearDown() {
        connection.cancel()
        server.stop()
        super.tearDown()
    }

    private func startDraining() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self = self else { return }
            if let data = data {
                self.receiveLock.lock()
                self.received.append(data)
                self.receiveLock.unlock()
            }
            if error == nil && !done {
                self.startDraining()
            }
        }
    }

    private func send(_ bytes: [UInt8]) {
        connection.send(content: Data(bytes), completion: .contentProcessed { _ in })
    }

    private func waitForBytes(_ count: Int, timeout: TimeInterval = 5) -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            receiveLock.lock()
            let snapshot = received
            receiveLock.unlock()
            if snapshot.count >= count { return snapshot }
            Thread.sleep(forTimeInterval: 0.02)
        }
        receiveLock.lock()
        defer { receiveLock.unlock() }
        return received
    }

    private func makeFrame(keyframe: Bool) -> EncodedFrame {
        // Two length-prefixed NALs: 3 bytes and 2 bytes.
        let payload = Data([0, 0, 0, 3, 0x40, 0x01, 0x02, 0, 0, 0, 2, 0x26, 0x7F])
        return EncodedFrame(
            payload: payload,
            formatDescription: nil,
            isKeyframe: keyframe,
            captureNanos: 1_000,
            encodeDoneNanos: 2_000)
    }

    func testLegacyV1ClientGetsAnnexBFrames() {
        send([8]) // metadata support only — a v1 client
        // displayConfig: [1][w u32][h u32][transform u32] = 13 bytes
        var data = waitForBytes(13)
        XCTAssertGreaterThanOrEqual(data.count, 13)
        XCTAssertEqual(data[0], 1)

        server.sendFrame(makeFrame(keyframe: true))
        // type 6 header (14B) + converted Annex-B payload (same size as AVCC)
        data = waitForBytes(13 + 14 + 13)
        let frame = Data(data.dropFirst(13))
        XCTAssertEqual(frame[0], 6) // videoFrameWithMetadata
        let sizeBytes = [UInt8](frame[1...4])
        let frameSize = (Int(sizeBytes[0]) << 24) | (Int(sizeBytes[1]) << 16) | (Int(sizeBytes[2]) << 8) | Int(sizeBytes[3])
        XCTAssertEqual(frameSize, 13)
        XCTAssertEqual(frame[5], 1) // keyframe flag
        let payload = [UInt8](frame.suffix(13))
        // Annex-B start codes where the length prefixes were.
        XCTAssertEqual(Array(payload[0..<4]), [0, 0, 0, 1])
        XCTAssertEqual(payload[4], 0x40)
        XCTAssertEqual(Array(payload[7..<11]), [0, 0, 0, 1])
        XCTAssertEqual(payload[11], 0x26)
    }

    func testV2ClientNegotiatesAndReceivesChunkedFrames() {
        send([12, 8]) // v2 request, then metadata support (client's last v1 bytes)

        // Expect: [13][version] then v2 envelopes: videoConfig announcement +
        // displayConfig = 2 + (4+2) + (4+12) = 24 bytes minimum.
        var data = waitForBytes(24)
        XCTAssertGreaterThanOrEqual(data.count, 24)
        XCTAssertEqual(data[0], 13)
        XCTAssertEqual(data[1], WireV2.version)

        var offset = 2
        // videoConfig announcement: empty parameter sets, codec HEVC (0).
        let vcEnv = WireV2.parseEnvelope(Data(data.dropFirst(offset)))
        XCTAssertEqual(vcEnv?.type, WireV2.MsgType.videoConfig.rawValue)
        XCTAssertEqual(vcEnv?.length, 2)
        XCTAssertEqual(data[offset + 4], 0) // codecId hevc
        XCTAssertEqual(data[offset + 5], 0) // nalLengthSize: announcement
        offset += 4 + 2

        let dcEnv = WireV2.parseEnvelope(Data(data.dropFirst(offset)))
        XCTAssertEqual(dcEnv?.type, WireV2.MsgType.displayConfig.rawValue)
        XCTAssertEqual(dcEnv?.length, 12)
        offset += 4 + 12

        // A keyframe: FRAME_BEGIN (4+33) + chunk header (4+4) + 13B payload.
        server.sendFrame(makeFrame(keyframe: true))
        data = waitForBytes(offset + 37 + 8 + 13)
        let beginEnv = WireV2.parseEnvelope(Data(data.dropFirst(offset)))
        XCTAssertEqual(beginEnv?.type, WireV2.MsgType.frameBegin.rawValue)
        let begin = WireV2.parseFrameBegin(Data(data.dropFirst(offset + 4)))
        XCTAssertEqual(begin?.totalSize, 13)
        XCTAssertEqual(begin?.flags, WireV2.FrameFlags.keyframe | WireV2.FrameFlags.lengthPrefixed)
        XCTAssertEqual(begin?.captureNs, 1_000)
        offset += 4 + 33

        let chunkEnv = WireV2.parseEnvelope(Data(data.dropFirst(offset)))
        XCTAssertEqual(chunkEnv?.type, WireV2.MsgType.frameChunk.rawValue)
        XCTAssertEqual(chunkEnv?.length, 4 + 13)
        // Payload arrives as raw length-prefixed AVCC — NOT Annex-B.
        let chunkPayload = [UInt8](data.dropFirst(offset + 4 + 4).prefix(13))
        XCTAssertEqual(Array(chunkPayload[0..<4]), [0, 0, 0, 3])
        offset += 4 + 4 + 13

        // v2 ping → pong carrying t0 and host timestamps.
        var ping = Data([WireV2.MsgType.ping.rawValue, 0, 0, 8])
        var t0 = UInt64(0xAABBCCDD).bigEndian
        withUnsafeBytes(of: &t0) { ping.append(contentsOf: $0) }
        connection.send(content: ping, completion: .contentProcessed { _ in })

        data = waitForBytes(offset + 4 + 24)
        let pongEnv = WireV2.parseEnvelope(Data(data.dropFirst(offset)))
        XCTAssertEqual(pongEnv?.type, WireV2.MsgType.pong.rawValue)
        XCTAssertEqual(pongEnv?.length, 24)
        let echoed = [UInt8](data.dropFirst(offset + 4).prefix(8))
        XCTAssertEqual(Array(echoed[4...7]), [0xAA, 0xBB, 0xCC, 0xDD])
    }

    func testV2NonKeyframeIsDroppedUntilFirstKeyframe() {
        send([12, 8])
        _ = waitForBytes(24)

        server.sendFrame(makeFrame(keyframe: false)) // must be dropped
        server.sendFrame(makeFrame(keyframe: true))

        let data = waitForBytes(24 + 37 + 8 + 13)
        // First frame message after startup must be the keyframe.
        let begin = WireV2.parseFrameBegin(Data(data.dropFirst(24 + 4)))
        XCTAssertNotNil(begin)
        XCTAssertEqual(begin!.flags & WireV2.FrameFlags.keyframe, WireV2.FrameFlags.keyframe)
    }
}
