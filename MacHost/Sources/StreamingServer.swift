import CoreMedia
import Foundation
import Network
import os

private enum WireMessage {
    static let legacyVideoFrame: UInt8 = 0
    static let displayConfig: UInt8 = 1
    static let touchEvent: UInt8 = 2
    static let ping: UInt8 = 4
    static let pong: UInt8 = 5
    static let videoFrameWithMetadata: UInt8 = 6
    static let keyframeRequest: UInt8 = 7
    static let clientSupportsFrameMetadata: UInt8 = 8
    /// Client→server, payload-free (old hosts consume 1 byte safely):
    /// "this device has no HEVC decoder".
    static let clientAvcOnly: UInt8 = 9
    /// Server→client, 1-byte payload (StreamCodec.wireId). Sent ONLY to
    /// clients that sent clientAvcOnly — old clients disconnect on unknown
    /// message types, so this must never be sent unsolicited.
    static let codecSelected: UInt8 = 10
    /// Client→server, 4-byte payload: the client's max decode size (issue
    /// #41). Every payload byte has the high bit set, so old hosts that
    /// consume unknown types byte-by-byte skip the payload harmlessly.
    static let clientDecoderLimits: UInt8 = 11
    /// Client→server, payload-free: "I understand desktopGeometry, and I read
    /// displayConfig as the encoded stream size."
    static let clientSupportsDesktopGeometry: UInt8 = 12
    /// Server→client, 8-byte payload: the logical desktop size, for display
    /// only. Sent ONLY to clients that sent clientSupportsDesktopGeometry —
    /// older clients disconnect on unknown message types.
    static let desktopGeometry: UInt8 = 13
}

/// Deterministic v2 switch-over (see WireProtocolV2.swift):
/// - Client advertises v1 types in the order 9, 11, 12, 14, 8 and then goes
///   SILENT until it receives either v1 type 15 (→ v2) or any other v1
///   message (→ legacy host, stay v1).
/// - Host: on type 14 it immediately answers 15+version (its only pre-startup
///   byte), and switches its INPUT parser to v2 right after processing the
///   type 8 that follows. Output switches at protocol startup.

enum StreamingServerStartError: LocalizedError {
    case listenerFailed(port: UInt16, underlying: Error)
    case cancelledBeforeReady(port: UInt16)
    case startupTimedOut(port: UInt16, lastWaitingError: Error?)

    var errorDescription: String? {
        switch self {
        case .listenerFailed(let port, let underlying):
            return "Could not listen on port \(port): \(underlying.localizedDescription)"
        case .cancelledBeforeReady(let port):
            return "Server startup on port \(port) was cancelled before the listener became ready."
        case .startupTimedOut(let port, let lastWaitingError):
            let detail = lastWaitingError.map { " Last listener error: \($0.localizedDescription)" } ?? ""
            return "Timed out while waiting for the server to listen on port \(port).\(detail)"
        }
    }
}

/// Bridges NWListener's state callback to async startup without risking a
/// leaked or double-resumed continuation. The listener may publish a state
/// before `wait()` installs its continuation, so the first result is cached.
final class ListenerStartupGate: @unchecked Sendable {
    private enum State {
        case pending
        case waiting(CheckedContinuation<Void, Error>)
        case completed(Result<Void, Error>)
    }

    private let lock = NSLock()
    private var state: State = .pending
    private var lastWaitingError: Error?

    func wait() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let completedResult: Result<Void, Error>?
                lock.lock()
                switch state {
                case .pending:
                    state = .waiting(continuation)
                    completedResult = nil
                case .completed(let result):
                    completedResult = result
                case .waiting:
                    // A StreamingServer has exactly one startup waiter.
                    completedResult = .failure(
                        NSError(
                            domain: "StreamingServer",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "Server startup was awaited more than once."]
                        )
                    )
                }
                lock.unlock()

                if let completedResult {
                    continuation.resume(with: completedResult)
                }
            }
        } onCancel: {
            resolve(.failure(CancellationError()))
        }
    }

    func noteWaitingError(_ error: Error) {
        lock.lock()
        lastWaitingError = error
        lock.unlock()
    }

    func resolveTimeout(port: UInt16) {
        lock.lock()
        let waitingError = lastWaitingError
        lock.unlock()
        resolve(.failure(StreamingServerStartError.startupTimedOut(port: port, lastWaitingError: waitingError)))
    }

    func resolve(_ result: Result<Void, Error>) {
        let continuation: CheckedContinuation<Void, Error>?
        lock.lock()
        switch state {
        case .pending:
            state = .completed(result)
            continuation = nil
        case .waiting(let waiter):
            state = .completed(result)
            continuation = waiter
        case .completed:
            continuation = nil
        }
        lock.unlock()

        continuation?.resume(with: result)
    }
}

/// Speaks the streaming protocol over any established ByteChannel. Transport
/// mechanics (TCP listener, loopback trust, SSWA auth, SSPC pairing — and
/// later the AOA bulk pipe) live in ChannelSource implementations; this class
/// owns protocol startup, framing, touch input, and stats.
class StreamingServer {
    private let port: UInt16
    private let tcpSource: TCPChannelSource
    private var channel: ByteChannel?
    var onClientConnected: (() -> Void)?
    var onClientDisconnected: (() -> Void)?
    /// Fired once per connection during protocol startup, BEFORE the display
    /// config is sent, for every outcome (.hevc or .h264) — so the capture
    /// pipeline can also revert to HEVC after an AVC-only client goes away.
    var onCodecNegotiated: ((StreamCodec) -> Void)?
    // Touch callback: (x1, y1, action, pointerCount, x2, y2)
    var onTouchEvent: ((Float, Float, Int, Int, Float, Float) -> Void)?
    var onStats: ((Double, Double) -> Void)?
    var onKeyframeRequested: ((Bool) -> Void)?
    /// Transport of the active client: true = physically secured (USB — adb
    /// reverse loopback today, AOA later), false = LAN (wireless), nil = no
    /// client has completed protocol startup.
    private(set) var activeClientIsLoopback: Bool?
    // Whether host wants to receive touch events from client. Ping/pong is
    // handled regardless. When false, incoming touch frames are dropped
    // immediately without parsing or dispatching to main queue.
    var touchEnabled: Bool = true

    // Wireless auth + code pairing are transport (TCP) concerns; these
    // forward to the TCP source so existing callers stay unchanged.
    var expectedAuthToken: Data? {
        get { tcpSource.expectedAuthToken }
        set { tcpSource.expectedAuthToken = newValue }
    }

    var onWirelessClientPaired: ((String) -> Void)? {
        get { tcpSource.onWirelessClientPaired }
        set { tcpSource.onWirelessClientPaired = newValue }
    }

    var expectedPairingCode: String? {
        get { tcpSource.expectedPairingCode }
        set { tcpSource.expectedPairingCode = newValue }
    }

    var pairingMacName: String {
        get { tcpSource.pairingMacName }
        set { tcpSource.pairingMacName = newValue }
    }

    var onPairingSuccess: ((String) -> Void)? {
        get { tcpSource.onPairingSuccess }
        set { tcpSource.onPairingSuccess = newValue }
    }

    var onPairingCodeExhausted: (() -> Void)? {
        get { tcpSource.onPairingCodeExhausted }
        set { tcpSource.onPairingCodeExhausted = newValue }
    }

    private let frameQueue = DispatchQueue(label: "frameQueue", qos: .userInteractive)
    private let receiveQueue = DispatchQueue(label: "receiveQueue", qos: .userInteractive)
    private let networkQueue = DispatchQueue(label: "networkQueue", qos: .userInteractive)
    private var bytesSent: UInt64 = 0
    private var frameCount: UInt64 = 0
    private var droppedFrames: UInt64 = 0
    private var lastStatsTime = DispatchTime.now()
    private var displayWidth = 1920
    private var displayHeight = 1080
    private var rotation = 0
    private var flipHorizontal = false
    private var flipVertical = false
    private var isReceiving = false
    private var isStopped = false
    private var connectionReady = false
    private var waitingForSyncFrame = false
    private var clientSupportsFrameMetadata = false
    private var clientIsAvcOnly = false
    /// Max decode size reported by the connected client (issue #41).
    private(set) var clientDecodeLimits: (width: Int, height: Int)?
    /// Set when the client opts in via type 12. Gates desktopGeometry sends.
    private var clientSupportsDesktopGeometry = false
    /// Logical desktop size, reported alongside the encoded size for display.
    private var desktopWidth = 0
    private var desktopHeight = 0
    // Input parse buffer with a consume cursor: advancing `inputStart`
    // replaces the old remove-from-front pattern (which shifted the whole
    // remainder on every message); the storage compacts periodically.
    private var inputBuffer = Data()
    private var inputStart = 0

    private var inputAvailable: Int { inputBuffer.count - inputStart }

    private func inputData(at offset: Int, count: Int) -> Data {
        let base = inputStart + offset
        return inputBuffer.subdata(in: base..<(base + count))
    }

    // ---- protocol v2 state ----
    /// Client sent type 12 (set on receiveQueue during startup).
    private var clientRequestedV2 = false
    /// Input parser mode: flips after the type-8 that follows a type-12.
    private var v2InputActive = false
    /// Output mode: v2 envelopes from protocol startup on. Written on
    /// receiveQueue before connectionReady, read afterwards — the
    /// connectionReady handshake orders it.
    private var v2Active = false
    private var negotiatedCodec: StreamCodec = .hevc
    private var lastSentFormat: CMFormatDescription?

    // v2 send scheduler — every field below is touched ONLY on frameQueue.
    private var controlQueue: [Data] = []
    private var pendingV2Frames: [EncodedFrame] = []
    private var pendingV2Bytes = 0
    private var currentFrame: EncodedFrame?
    private var currentFrameId: UInt32 = 0
    private var nextFrameId: UInt32 = 0
    private var currentOffset = 0
    private var inflightBytes = 0
    private var needKeyframeResync = false
    /// Exposed for capture-side admission. True while the in-flight byte
    /// watermark is exceeded. Written on frameQueue, read from capture
    /// threads — hence the lock.
    private let congestedFlag = OSAllocatedUnfairLock(initialState: false)
    var isCongested: Bool { congestedFlag.withLock { $0 } }
    /// True when the active client negotiated protocol v2.
    var clientUsesV2: Bool { v2Active }
    private var chunkSize = WireV2.tcpChunkSize
    /// In-flight byte ceiling before video dequeue pauses. Per-transport:
    /// AOA gets a shallower queue (measured ~335 Mbps ceiling → 256KB ≈ 6ms)
    /// so control preemption stays tight.
    private var watermarkBytes = 512 * 1024
    private static let tcpWatermarkBytes = 512 * 1024
    private static let aoaWatermarkBytes = 256 * 1024
    private static let maxQueuedV2Bytes = 8 * 1024 * 1024

    // ---- adaptive bitrate (AIMD, v2 clients only) ----
    // Signals: send-watermark congestion (primary) and forced keyframe
    // requests (client-side pain). Decrease multiplicatively and hold;
    // increase additively toward the user's ceiling. Applied through
    // setLiveBitrate — no encoder session recreation.
    var onBitrateSuggestion: ((Int) -> Void)?
    private var abrTimer: DispatchSourceTimer?
    private var abrCeilingMbps = 0
    private var abrCurrentMbps = 0
    private var abrHoldTicks = 0
    private var abrStableTicks = 0
    private var abrCongestedTicks = 0
    private var abrForcedKeyframes = 0
    private static let abrFloorMbps = 10
    private static let aoaSafeCeilingMbps = 300

    /// Start/refresh the controller for the active session. `ceilingMbps` is
    /// the user's setting (already wireless-capped by the caller).
    func configureAdaptiveBitrate(ceilingMbps: Int) {
        frameQueue.async { [weak self] in
            guard let self = self else { return }
            var ceilingMbps = ceilingMbps
            if self.channel?.kind == .aoa {
                // Soak finding (Galaxy Tab): sustained saturation (~480 Mbps)
                // progressively crashed the device's USB gadget stack — adb
                // first, then the whole bus, recoverable only by replug.
                // Stay well below the ~480 Mbps ceiling.
                ceilingMbps = min(ceilingMbps, Self.aoaSafeCeilingMbps)
            }
            self.abrCeilingMbps = ceilingMbps
            self.abrCurrentMbps = min(max(self.abrCurrentMbps, Self.abrFloorMbps), ceilingMbps)
            if self.abrCurrentMbps == Self.abrFloorMbps { self.abrCurrentMbps = ceilingMbps }
            // Apply the (possibly transport-capped) starting rate to the
            // encoder NOW. Without this the encoder ran at the raw user
            // setting (up to 5000 Mbps — 15x the AOA link) until the first
            // congestion cut, guaranteeing a session-start congestion storm.
            self.onBitrateSuggestion?(self.abrCurrentMbps)
            self.abrCongestedTicks = 0
            self.abrForcedKeyframes = 0
            guard self.abrTimer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.frameQueue)
            timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
            timer.setEventHandler { [weak self] in
                self?.abrTick()
            }
            timer.resume()
            self.abrTimer = timer
        }
    }

    func stopAdaptiveBitrate() {
        frameQueue.async { [weak self] in
            self?.abrTimer?.cancel()
            self?.abrTimer = nil
        }
    }

    /// frameQueue only. Congestion is sampled at tick time and must persist
    /// for two consecutive ticks: a latched any-time-in-window flag turned
    /// every keyframe transit (a ~1MB burst through a 256KB watermark) into a
    /// bitrate cut, and the periodic self-heal IDRs then walked the rate down
    /// to the floor.
    private func abrTick() {
        guard v2Active, connectionReady, abrCeilingMbps > 0 else { return }
        if isCongested {
            abrCongestedTicks += 1
        } else {
            abrCongestedTicks = 0
        }
        let congested = abrCongestedTicks >= 2
        let pain = abrForcedKeyframes >= 2
        abrForcedKeyframes = 0

        if abrHoldTicks > 0 {
            abrHoldTicks -= 1
            return
        }
        if congested || pain {
            let reduced = max(Self.abrFloorMbps, Int(Double(abrCurrentMbps) * 0.7))
            if reduced != abrCurrentMbps {
                abrCurrentMbps = reduced
                abrStableTicks = 0
                abrHoldTicks = 8 // 2s hold after a cut
                debugLog("ABR: congestion — bitrate ↓ \(abrCurrentMbps) Mbps")
                onBitrateSuggestion?(abrCurrentMbps)
            }
            return
        }
        abrStableTicks += 1
        if abrStableTicks >= 4, abrCurrentMbps < abrCeilingMbps {
            abrStableTicks = 0
            let increased = min(abrCeilingMbps, max(abrCurrentMbps + 5, Int(Double(abrCurrentMbps) * 1.08)))
            if increased != abrCurrentMbps {
                abrCurrentMbps = increased
                onBitrateSuggestion?(abrCurrentMbps)
            }
        }
    }

    init(port: UInt16) {
        self.port = port
        self.tcpSource = TCPChannelSource(port: port, queue: networkQueue)
        wireSource(tcpSource)
    }

    private func wireSource(_ source: ChannelSource) {
        source.onIncomingConnection = { [weak self] incoming in
            guard let self = self else { return }
            // Protect an active USB-direct session from the client's TCP
            // fallback probes and stray loopback connections.
            if let current = self.channel, current.kind == .aoa, incoming.kind != .aoa {
                debugLog("TCP client ignored — USB-direct session active")
                incoming.cancel()
                return
            }
            self.prepareForNewClient()
        }
        source.onChannelEstablished = { [weak self] channel in
            self?.beginExistingProtocol(on: channel)
        }
        source.onChannelClosed = { [weak self] closed in
            guard let self = self else { return }
            // Only the active channel's death is a client disconnect;
            // rejected/preempted connections die silently.
            guard self.channel === closed else { return }
            self.activeClientIsLoopback = nil
            self.channel = nil
            self.onClientDisconnected?()
        }
    }

    /// Opt-in AOA bulk transport (USB direct). Safe to call before start().
    func enableUSBDirect() {
        guard aoaSource == nil else { return }
        let source = AOAChannelSource(callbackQueue: networkQueue)
        // Block the mode switch only for sessions the switch would truly
        // break: wireless clients (possibly a different device). A loopback
        // (adb TCP) session is the same plugged-in tablet — switching cuts it
        // for a few seconds and it reconnects over AOA, which is the upgrade
        // we want. Auto-reconnecting clients would otherwise never leave TCP.
        source.isSessionActive = { [weak self] in
            guard let self = self else { return false }
            return self.connectionReady && self.activeClientIsLoopback != true
        }
        wireSource(source)
        aoaSource = source
        if !isStopped {
            source.start()
        }
    }

    /// e.g. "USB 10 Gbps" while an AOA link is up, nil otherwise.
    var usbDirectLinkDescription: String? { aoaSource?.linkDescription }

    private var aoaSource: AOAChannelSource?

    /// Port the TCP listener actually bound (differs from `port` when 0 was
    /// requested).
    var boundPort: UInt16? {
        tcpSource.boundPort
    }

    /// Returns once the TCP listener is actually ready; throws on failure or
    /// timeout instead of logging and pretending the server is up.
    func start(startupTimeout: TimeInterval = 10) async throws {
        isStopped = false
        try await tcpSource.start(startupTimeout: startupTimeout)
        aoaSource?.start()
    }

    /// Single-client policy, exactly as before the transport refactor: any
    /// incoming peer preempts the active session before it is even vetted.
    private func prepareForNewClient() {
        if let oldChannel = channel {
            isReceiving = false
            oldChannel.cancel()
        }
        channel = nil
        connectionReady = false
        clientSupportsFrameMetadata = false
        clientIsAvcOnly = false
        clientDecodeLimits = nil
        clientSupportsDesktopGeometry = false
        waitingForSyncFrame = true
        inputBuffer.removeAll(keepingCapacity: true)
        inputStart = 0
        droppedFrames = 0
        clientRequestedV2 = false
        v2InputActive = false
        v2Active = false
        lastSentFormat = nil
        frameQueue.async { [weak self] in
            guard let self = self else { return }
            self.controlQueue.removeAll()
            self.pendingV2Frames.removeAll()
            self.pendingV2Bytes = 0
            self.currentFrame = nil
            self.currentOffset = 0
            self.inflightBytes = 0
            self.congestedFlag.withLock { $0 = false }
            self.needKeyframeResync = false
        }
    }

    private func beginExistingProtocol(on channel: ByteChannel) {
        self.channel = channel
        // "Loopback" historically meant USB; physically-secured covers the
        // AOA transport too. Read by AppDelegate to cap wireless bitrate
        // until adaptive bitrate control lands.
        activeClientIsLoopback = channel.trust == .physicallySecured
        chunkSize = channel.kind == .aoa ? WireV2.aoaChunkSize : WireV2.tcpChunkSize
        watermarkBytes = channel.kind == .aoa ? Self.aoaWatermarkBytes : Self.tcpWatermarkBytes
        startReceivingTouch()

        // Give new clients a short chance to opt in before the first frame.
        // Legacy clients send no capability message, so we continue shortly
        // after this window with the old frame type. AOA clients are always
        // current-version and their adverts can take >100ms through the USB
        // round-trip and app scheduling — starting v1 and upgrading mid-
        // session corrupts the stream, so give them a generous window (their
        // type 8 still finishes startup the moment it arrives).
        let optInWindow: DispatchTimeInterval = channel.kind == .aoa ? .seconds(2) : .milliseconds(100)
        networkQueue.asyncAfter(deadline: .now() + optInWindow) { [weak self, weak channel] in
            guard let self = self, let channel = channel else { return }
            self.finishProtocolStartup(on: channel)
        }
    }

    private func finishProtocolStartup(on channel: ByteChannel) {
        guard self.channel === channel, !isStopped, !connectionReady else { return }

        let codec: StreamCodec = clientIsAvcOnly ? .h264 : .hevc
        negotiatedCodec = codec
        if v2Active {
            // v2 announces the codec to every client via an empty videoConfig
            // (parameter sets follow with the first keyframe).
            enqueueControl(WireV2.encodeVideoConfig(codecId: codec.wireId, nalLengthSize: 0, parameterSets: Data()))
            debugLog("Sent v2 codec announcement: \(codec)")
        } else if clientIsAvcOnly {
            // Safe to send: this client opted in via type 9. Must precede the
            // display config so the client knows the codec before it sizes
            // and configures its decoder.
            let msg = Data([WireMessage.codecSelected, codec.wireId])
            channel.send(msg, completion: nil)
            debugLog("Sent codecSelected: H.264")
        }
        // Synchronous, before sendDisplaySize(): the handler switches the
        // encoder AND updates displayWidth/Height (clamped for H.264) so the
        // display config below carries decoder-safe dimensions.
        onCodecNegotiated?(codec)

        debugLog("Client connected - sending display config first")
        sendDisplaySize()
        connectionReady = true
        debugLog("Connection ready for frames (metadata=\(clientSupportsFrameMetadata ? "on" : "off"), codec=\(codec), v2=\(v2Active))")
        onClientConnected?()
    }

    /// The logical desktop the user picked. Purely informational: the client
    /// must size its decoder from displayConfig, never from this.
    func setDesktopSize(width: Int, height: Int) {
        desktopWidth = width
        desktopHeight = height
    }

    func setDisplaySize(width: Int, height: Int, rotation: Int = 0, flipHorizontal: Bool = false, flipVertical: Bool = false) {
        displayWidth = width
        displayHeight = height
        self.rotation = rotation
        self.flipHorizontal = flipHorizontal
        self.flipVertical = flipVertical
    }

    func updateDisplayTransform(rotation: Int, flipHorizontal: Bool, flipVertical: Bool) {
        self.rotation = rotation
        self.flipHorizontal = flipHorizontal
        self.flipVertical = flipVertical
        sendDisplaySize()
    }

    func sendDisplaySize() {
        guard let channel = channel else { return }

        let transform = rotation + (flipHorizontal ? 1000 : 0) + (flipVertical ? 2000 : 0)
        if v2Active {
            enqueueControl(WireV2.encodeDisplayConfig(width: displayWidth, height: displayHeight, transform: transform))
        } else {
            var data = Data()
            data.append(WireMessage.displayConfig)
            data.append(contentsOf: withUnsafeBytes(of: Int32(displayWidth).bigEndian) { Data($0) })
            data.append(contentsOf: withUnsafeBytes(of: Int32(displayHeight).bigEndian) { Data($0) })
            data.append(contentsOf: withUnsafeBytes(of: Int32(transform).bigEndian) { Data($0) })
            channel.send(data, completion: nil)
        }
        debugLog("Sent display config: \(displayWidth)x\(displayHeight) @ \(rotation)°, h=\(flipHorizontal), v=\(flipVertical)")
        sendDesktopGeometry()
    }

    /// Follows every display config so the two can never disagree on screen.
    private func sendDesktopGeometry() {
        guard let channel = channel else { return }
        guard desktopWidth > 0, desktopHeight > 0 else { return }

        if v2Active {
            // v2 envelopes are length-prefixed, so no opt-in is needed —
            // clients that predate the message skip it by length.
            enqueueControl(WireV2.encodeDesktopGeometry(width: desktopWidth, height: desktopHeight))
        } else {
            guard clientSupportsDesktopGeometry else { return }
            var data = Data()
            data.append(WireMessage.desktopGeometry)
            data.append(contentsOf: withUnsafeBytes(of: Int32(desktopWidth).bigEndian) { Data($0) })
            data.append(contentsOf: withUnsafeBytes(of: Int32(desktopHeight).bigEndian) { Data($0) })
            channel.send(data, completion: nil)
        }
        debugLog("Sent desktop geometry: \(desktopWidth)x\(desktopHeight)")
    }

    private func startReceivingTouch() {
        guard !isReceiving else {
            debugLog("Already receiving touch events")
            return
        }
        isReceiving = true
        debugLog("Starting input receive loop... (touch=\(touchEnabled ? "on" : "off"))")

        // Use loop-based pattern instead of recursion to prevent stack overflow
        receiveQueue.async { [weak self] in
            self?.touchReceiveLoop()
        }
    }

    private func touchReceiveLoop() {
        guard let channel = channel, isReceiving, !isStopped else {
            isReceiving = false
            return
        }

        channel.receive(minimum: 1, maximum: 256) { [weak self] data, isComplete, error in
            guard let self = self, self.isReceiving, !self.isStopped else { return }

            if error != nil || isComplete {
                self.isReceiving = false
                self.inputBuffer.removeAll(keepingCapacity: true)
                self.inputStart = 0
                return
            }

            if let data = data, !data.isEmpty {
                self.inputBuffer.append(data)
                self.processInputBuffer(channel: channel)
            }

            self.receiveQueue.async {
                self.touchReceiveLoop()
            }
        }
    }

    private func processInputBuffer(channel: ByteChannel) {
        if v2InputActive {
            processV2InputBuffer(channel: channel)
            return
        }
        while inputAvailable > 0 {
            let msgType = inputByte(at: 0)
            switch msgType {
            case WireMessage.touchEvent:
                // Touch event: 1 type + 1 pointerCount + N*(4x+4y) + 4 action.
                // 1 finger: 14 bytes, 2 fingers: 22 bytes.
                guard inputAvailable >= 2 else { return }

                let pointerCount = Int(inputByte(at: 1))
                guard pointerCount == 1 || pointerCount == 2 else {
                    debugLog("Invalid touch pointer count: \(pointerCount)")
                    consumeInputBytes(1)
                    continue
                }

                let expectedSize = 2 + pointerCount * 8 + 4
                guard inputAvailable >= expectedSize else { return }

                let message = inputData(at: 0, count: expectedSize)
                consumeInputBytes(expectedSize)

                // Drop early if host has touch disabled, after consuming exactly
                // this touch frame so coalesced ping/keyframe messages survive.
                if touchEnabled {
                    handleTouchMessage(message, pointerCount: pointerCount)
                }

            case WireMessage.ping:
                // Ping from client: echo back as pong (type=5) with client's timestamp.
                guard inputAvailable >= 9 else { return }

                let clientTimestamp = inputData(at: 1, count: 8)
                consumeInputBytes(9)

                var pong = Data(capacity: 9)
                pong.append(WireMessage.pong) // Type: Pong
                pong.append(clientTimestamp)
                channel.send(pong, completion: nil)

            case WireMessage.keyframeRequest:
                // Keyframe request from Android decoder. The client sends a
                // two-byte message: type + flags.
                guard inputAvailable >= 2 else { return }

                let flags = inputByte(at: 1)
                consumeInputBytes(2)
                onKeyframeRequested?((flags & 1) != 0)

            case WireMessage.clientSupportsFrameMetadata:
                // One-byte opt-in from newer clients. Keeping this payload-free
                // lets older hosts safely ignore it without misaligning input.
                consumeInputBytes(1)
                if !clientSupportsFrameMetadata {
                    clientSupportsFrameMetadata = true
                    debugLog("Client supports video frame metadata")
                }
                if clientRequestedV2 {
                    // Type 8 is the client's last v1 byte (it stays silent
                    // until it sees our 13) — everything after is enveloped.
                    v2InputActive = true
                    v2Active = true
                }
                finishProtocolStartup(on: channel)
                if v2InputActive {
                    processV2InputBuffer(channel: channel)
                    return
                }

            case WireV2.negotiationRequest:
                // Payload-free v2 opt-in (same convention as types 8/9).
                consumeInputBytes(1)
                if connectionReady {
                    // Startup already completed as v1 — switching formats
                    // mid-session interleaves v1 frames with v2 envelopes and
                    // corrupts the client's parse. Stay v1; the client
                    // reconnects to upgrade.
                    debugLog("v2 request after v1 startup — ignored (reconnect to upgrade)")
                } else if !clientRequestedV2 {
                    clientRequestedV2 = true
                    debugLog("Client requested protocol v2 — accepting")
                    // Only host byte before protocol startup; the client
                    // switches its own output to v2 upon receiving it.
                    channel.send(Data([WireV2.negotiationAccept, WireV2.version]), completion: nil)
                }

            case WireMessage.clientAvcOnly:
                // Payload-free opt-in (same convention as type 8): the client
                // has no HEVC decoder, stream H.264 instead. Clients send this
                // BEFORE type 8, so it lands before finishProtocolStartup runs.
                consumeInputBytes(1)
                if !clientIsAvcOnly {
                    clientIsAvcOnly = true
                    debugLog("Client is AVC-only — will negotiate H.264")
                }

            case WireMessage.clientDecoderLimits:
                // Type + 4 payload bytes: [w-hi][w-lo][h-hi][h-lo], 7 data
                // bits each with the high bit always set (old hosts skip the
                // payload harmlessly). Sent BEFORE type 8, like type 9.
                guard inputAvailable >= 5 else { return }

                let payload = (1...4).map { inputByte(at: $0) }
                consumeInputBytes(5)
                guard payload.allSatisfy({ $0 & 0x80 != 0 }) else {
                    debugLog("Malformed decoder-limits payload — ignoring")
                    continue
                }
                let w = (Int(payload[0] & 0x7F) << 7) | Int(payload[1] & 0x7F)
                let h = (Int(payload[2] & 0x7F) << 7) | Int(payload[3] & 0x7F)
                // Anything below QVGA-ish is a nonsense report — ignore it.
                if w >= 256 && h >= 256 {
                    clientDecodeLimits = (w, h)
                    debugLog("Client decoder limit: \(w)x\(h)")
                    // Arrived after the 100 ms legacy grace already finished
                    // startup (slow link, slow device): re-negotiate now so the
                    // limit still takes effect instead of waiting for the next
                    // restart. The handler re-sends the display config itself
                    // when the encode size changes.
                    if connectionReady {
                        debugLog("Decoder limit arrived late — re-negotiating")
                        let before = (displayWidth, displayHeight)
                        onCodecNegotiated?(clientIsAvcOnly ? .h264 : .hevc)
                        if (displayWidth, displayHeight) != before {
                            sendDisplaySize()
                        }
                    }
                }

            case WireMessage.clientSupportsDesktopGeometry:
                // Payload-free opt-in (same convention as types 8 and 9), sent
                // BEFORE type 8 so it lands before finishProtocolStartup runs.
                consumeInputBytes(1)
                if !clientSupportsDesktopGeometry {
                    clientSupportsDesktopGeometry = true
                    debugLog("Client reads displayConfig as the encoded size")
                    // Late opt-in (after startup): the display config already
                    // went out without geometry, so send it on its own.
                    if connectionReady { sendDesktopGeometry() }
                }

            default:
                debugLog("Unknown client input type: \(msgType)")
                consumeInputBytes(1)
            }
        }
    }

    /// v2 input: every client message is [type u8][len u24 BE][payload].
    /// Unknown types are skipped by length — no more high-bit padding tricks.
    private func processV2InputBuffer(channel: ByteChannel) {
        while inputAvailable >= WireV2.envelopeSize {
            guard let (type, length) = WireV2.parseEnvelope(inputData(at: 0, count: WireV2.envelopeSize)) else { return }
            guard inputAvailable >= WireV2.envelopeSize + length else { return }
            let payload = inputData(at: WireV2.envelopeSize, count: length)
            consumeInputBytes(WireV2.envelopeSize + length)

            switch type {
            case WireV2.MsgType.touch.rawValue:
                guard let count = payload.first, count == 1 || count == 2,
                      payload.count >= 1 + Int(count) * 8 + 4 else { continue }
                if touchEnabled {
                    // Reuse the v1 body parser: it expects a leading type byte.
                    handleTouchMessage(Data([WireMessage.touchEvent]) + payload, pointerCount: Int(count))
                }

            case WireV2.MsgType.ping.rawValue:
                guard payload.count >= 8 else { continue }
                let t0 = payload.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).bigEndian }
                let t1 = DispatchTime.now().uptimeNanoseconds
                enqueueControl(WireV2.encodePong(t0: t0, t1: t1, t2: DispatchTime.now().uptimeNanoseconds))

            case WireV2.MsgType.keyframeRequest.rawValue:
                guard let flags = payload.first else { continue }
                let force = (flags & 1) != 0
                if force {
                    frameQueue.async { [weak self] in
                        self?.abrForcedKeyframes += 1
                    }
                }
                onKeyframeRequested?(force)

            case WireV2.MsgType.clientStats.rawValue, WireV2.MsgType.nop.rawValue:
                continue

            default:
                debugLog("Unknown v2 client message type \(type) (\(length)B) — skipped")
            }
        }
    }

    // MARK: - v2 send scheduler

    /// Control messages (pong, display config, video config) jump the video
    /// queue: the pump drains them between chunks, so a pong never waits
    /// behind a multi-megabyte keyframe.
    private func enqueueControl(_ message: Data) {
        frameQueue.async { [weak self] in
            guard let self = self else { return }
            self.controlQueue.append(message)
            self.pumpV2Send()
        }
    }

    /// Runs on frameQueue only. Issues sends while under the in-flight byte
    /// watermark; each completion re-enters. Order of channel.send calls is
    /// the wire order.
    private func pumpV2Send() {
        guard let channel = channel, !isStopped else { return }
        while inflightBytes < watermarkBytes {
            if !controlQueue.isEmpty {
                dispatchV2(channel, controlQueue.removeFirst())
                continue
            }
            if currentFrame == nil {
                guard !pendingV2Frames.isEmpty else { break }
                let frame = pendingV2Frames.removeFirst()
                pendingV2Bytes -= frame.payload.count
                currentFrame = frame
                currentFrameId = nextFrameId
                nextFrameId &+= 1
                currentOffset = 0
                var flags: UInt8 = WireV2.FrameFlags.lengthPrefixed
                if frame.isKeyframe { flags |= WireV2.FrameFlags.keyframe }
                dispatchV2(channel, WireV2.encodeFrameBegin(WireV2.FrameBegin(
                    frameId: currentFrameId,
                    totalSize: UInt32(frame.payload.count),
                    flags: flags,
                    captureNs: frame.captureNanos,
                    encodeDoneNs: frame.encodeDoneNanos,
                    sendStartNs: DispatchTime.now().uptimeNanoseconds)))
                continue
            }
            guard let frame = currentFrame else { continue }
            let payload = frame.payload
            let take = min(chunkSize, payload.count - currentOffset)
            dispatchV2(channel, WireV2.encodeChunkHeader(frameId: currentFrameId, chunkBytes: take))
            // Data slice: zero-copy view sharing the encoder buffer's storage
            // (subdata here used to copy every chunk — ~40MB/s at 300Mbps).
            let start = payload.index(payload.startIndex, offsetBy: currentOffset)
            let end = payload.index(start, offsetBy: take)
            dispatchV2(channel, payload[start..<end])
            currentOffset += take
            if currentOffset >= payload.count {
                let age = DispatchTime.now().uptimeNanoseconds &- frame.captureNanos
                updateStats(bytes: payload.count, frameAgeNs: age)
                currentFrame = nil
            }
        }
        let congested = inflightBytes >= watermarkBytes
        congestedFlag.withLock { $0 = congested }
    }

    private func dispatchV2(_ channel: ByteChannel, _ data: Data) {
        inflightBytes += data.count
        channel.send(data) { [weak self] error in
            guard let self = self else { return }
            self.frameQueue.async {
                self.inflightBytes -= data.count
                if error != nil {
                    self.droppedFrames += 1
                }
                self.pumpV2Send()
            }
        }
    }

    private func handleTouchMessage(_ data: Data, pointerCount: Int) {
        let x1 = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 2, as: Float.self) }
        let y1 = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 6, as: Float.self) }

        var x2: Float = 0
        var y2: Float = 0
        if pointerCount >= 2 {
            x2 = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 10, as: Float.self) }
            y2 = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 14, as: Float.self) }
        }

        let actionOffset = 2 + pointerCount * 8
        let action = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: actionOffset, as: Int32.self) }

        DispatchQueue.main.async {
            self.onTouchEvent?(x1, y1, Int(action), pointerCount, x2, y2)
        }
    }

    private func inputByte(at offset: Int) -> UInt8 {
        inputBuffer[inputBuffer.index(inputBuffer.startIndex, offsetBy: inputStart + offset)]
    }

    private func consumeInputBytes(_ count: Int) {
        inputStart += count
        // Compact occasionally; O(1) amortized instead of O(n) per consume.
        if inputStart >= 4096 {
            inputBuffer.removeSubrange(0..<inputStart)
            inputStart = 0
        } else if inputStart == inputBuffer.count {
            inputBuffer.removeAll(keepingCapacity: true)
            inputStart = 0
        }
    }

    func sendFrame(_ frame: EncodedFrame) {
        guard let channel = channel, !isStopped, connectionReady else { return }

        // With short-GOP encoding, a fresh client must start on a keyframe —
        // sending P-frames before the first IDR would feed garbage to its decoder.
        if waitingForSyncFrame {
            guard frame.isKeyframe else {
                droppedFrames += 1
                return
            }
            waitingForSyncFrame = false
            debugLog("First keyframe sent to new client")
        }

        if v2Active {
            frameQueue.async { [weak self] in
                self?.enqueueV2Frame(frame)
            }
            return
        }

        // Legacy v1 path: convert to Annex-B (in-band parameter sets before
        // keyframes) — byte-identical to the pre-refactor stream.
        // No frame-age dropping or backpressure — send everything immediately.
        // The encode queue depth limit (2 pending) in ScreenCapture handles flow control.
        frameQueue.async { [weak self] in
            guard let self = self else { return }

            let annexB = Bitstream.annexB(from: frame, codec: self.negotiatedCodec)
            let packet = self.makeFramePacket(annexB, timestamp: frame.captureNanos, isKeyframe: frame.isKeyframe)

            channel.send(packet) { error in
                if error != nil {
                    self.droppedFrames += 1
                }
            }

            // Track frame age at send time for pipeline profiling
            let sendAge = DispatchTime.now().uptimeNanoseconds - frame.captureNanos
            self.updateStats(bytes: annexB.count, frameAgeNs: sendAge)
        }
    }

    /// frameQueue only. Emits a videoConfig ahead of the keyframe whenever the
    /// encoder's format description changed, then queues the frame for the
    /// pump. When the link is badly backlogged the queue is cleared and the
    /// stream resyncs on the next keyframe (frames must never be dropped
    /// individually — IPP reference chains).
    private func enqueueV2Frame(_ frame: EncodedFrame) {
        if needKeyframeResync {
            guard frame.isKeyframe else {
                droppedFrames += 1
                return
            }
            needKeyframeResync = false
        }
        if frame.isKeyframe, let format = frame.formatDescription, format !== lastSentFormat {
            lastSentFormat = format
            let sets = Bitstream.parameterSets(from: format, codec: negotiatedCodec)
            controlQueue.append(WireV2.encodeVideoConfig(codecId: negotiatedCodec.wireId, nalLengthSize: 4, parameterSets: sets))
            debugLog("v2 videoConfig queued (\(sets.count)B parameter sets)")
        }
        pendingV2Frames.append(frame)
        pendingV2Bytes += frame.payload.count
        if pendingV2Bytes > Self.maxQueuedV2Bytes {
            // Deep backlog: drop everything and restart at an IDR. Byte-based
            // cap so the worst-case memory (pinned CMSampleBuffers) stays
            // fixed regardless of frame size.
            droppedFrames += UInt64(pendingV2Frames.count)
            pendingV2Frames.removeAll()
            pendingV2Bytes = 0
            needKeyframeResync = true
            debugLog("v2 send queue overflow — resyncing on next keyframe")
            // With an open GOP nobody else will produce that IDR: the client
            // is starved (its watchdogs live in the frame-receive path), so
            // the HOST must ask its own encoder or the stream freezes.
            onKeyframeRequested?(true)
        }
        pumpV2Send()
    }

    private func makeFramePacket(_ data: Data, timestamp: UInt64, isKeyframe: Bool) -> Data {
        if clientSupportsFrameMetadata {
            var packet = Data(capacity: data.count + 14)
            packet.append(WireMessage.videoFrameWithMetadata)
            appendFrameSize(data.count, to: &packet)
            packet.append(isKeyframe ? 1 : 0)
            var captureTimestamp = timestamp.bigEndian
            withUnsafeBytes(of: &captureTimestamp) { packet.append(contentsOf: $0) }
            packet.append(data)
            return packet
        }

        // Keep legacy frame type 0 for clients that do not advertise
        // metadata support; remove after legacy clients age out.
        var packet = Data(capacity: data.count + 5)
        packet.append(WireMessage.legacyVideoFrame)
        appendFrameSize(data.count, to: &packet)
        packet.append(data)
        return packet
    }

    private func appendFrameSize(_ size: Int, to packet: inout Data) {
        var frameSize = Int32(size).bigEndian
        withUnsafeBytes(of: &frameSize) { packet.append(contentsOf: $0) }
    }

    // Pipeline profiling: track frame age at send time
    private var totalFrameAgeNs: UInt64 = 0
    private var profiledFrameCount: UInt64 = 0

    private func updateStats(bytes: Int, frameAgeNs: UInt64 = 0) {
        bytesSent += UInt64(bytes)
        frameCount += 1
        if frameAgeNs > 0 {
            totalFrameAgeNs += frameAgeNs
            profiledFrameCount += 1
        }

        let now = DispatchTime.now()
        let elapsed = Double(now.uptimeNanoseconds - lastStatsTime.uptimeNanoseconds) / 1_000_000_000

        if elapsed >= 1.0 {
            let mbps = Double(bytesSent * 8) / elapsed / 1_000_000
            let fps = Double(frameCount) / elapsed
            onStats?(fps, mbps)

            // Log pipeline latency profile
            if profiledFrameCount > 0 {
                let avgAgeMs = Double(totalFrameAgeNs) / Double(profiledFrameCount) / 1_000_000.0
                debugLog("Pipeline: \(String(format: "%.1f", fps))fps, \(String(format: "%.1f", mbps))Mbps, avg frame age: \(String(format: "%.1f", avgAgeMs))ms, dropped: \(droppedFrames)")
            }

            bytesSent = 0
            frameCount = 0
            droppedFrames = 0
            totalFrameAgeNs = 0
            profiledFrameCount = 0
            lastStatsTime = now
        }
    }

    func stop() {
        isStopped = true
        isReceiving = false
        stopAdaptiveBitrate()

        // Wait for pending operations before cancelling
        frameQueue.sync {}
        receiveQueue.sync {}

        channel?.cancel()
        tcpSource.stop()
        aoaSource?.stop()
        channel = nil
    }
}
