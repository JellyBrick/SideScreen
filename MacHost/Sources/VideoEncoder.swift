import Foundation
import VideoToolbox
import CoreMedia
import os

class VideoEncoder {
    private struct EncoderState {
        var pendingForceKeyframe = false
    }

    private var compressionSession: VTCompressionSession?
    var onEncodedFrame: ((EncodedFrame) -> Void)?
    private var width: Int
    private var height: Int
    let codec: StreamCodec
    private var bitrateMbps: Int = 20
    private var quality: String = "medium"
    private var gamingBoost: Bool = false
    private var frameRate: Int = 60
    private let stateLock = OSAllocatedUnfairLock(initialState: EncoderState())
    init(width: Int, height: Int, codec: StreamCodec = .hevc, bitrateMbps: Int = 20, quality: String = "ultralow", gamingBoost: Bool = false, frameRate: Int = 60) {
        self.width = width
        self.height = height
        self.codec = codec
        self.bitrateMbps = bitrateMbps
        self.quality = quality
        self.gamingBoost = gamingBoost
        self.frameRate = frameRate
        setupCompressionSession()
    }

    func updateSettings(bitrateMbps: Int, quality: String, gamingBoost: Bool) {
        self.bitrateMbps = bitrateMbps
        self.quality = quality
        self.gamingBoost = gamingBoost

        // Bitrate/quality/fps are all runtime-settable on an existing session;
        // recreating one drops the stream for hundreds of ms (new client sync).
        if applyRuntimeProperties() { return }

        // Drain pending frames before invalidation
        if let session = compressionSession {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        setupCompressionSession()
    }

    /// Adjust only the average bitrate on the live session. Entry point for the
    /// adaptive bitrate controller; must not recreate the session.
    func setLiveBitrate(mbps: Int) {
        bitrateMbps = mbps
        guard let session = compressionSession else { return }
        let status = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: mbps * 1_000_000 as CFNumber)
        if status != noErr {
            debugLog("Live bitrate change to \(mbps)Mbps rejected: \(status)")
        }
    }

    /// Request-based IDR mode for v2 clients: the transport is reliable, so
    /// periodic keyframes only exist for new-client sync and decoder recovery
    /// — both already served by explicit requests (type 7 / v2 keyframe
    /// request). Killing the 1s IDR cadence removes the per-second burst that
    /// shows up as a sawtooth in E2E latency. v1 clients keep the 1s GOP
    /// (their stale-keyframe watchdog expects it).
    func setRequestBasedKeyframes(_ enabled: Bool) {
        guard requestBasedKeyframes != enabled else { return }
        requestBasedKeyframes = enabled
        guard let session = compressionSession else { return }
        applyKeyframePolicy(session)
        debugLog("Keyframe policy: \(enabled ? "request-based (open GOP)" : "1s GOP")")
    }

    private var requestBasedKeyframes = false

    private func applyKeyframePolicy(_ session: VTCompressionSession) {
        let interval: CFNumber = requestBasedKeyframes ? (Int32.max as CFNumber) : (frameRate as CFNumber)
        let duration: CFNumber = requestBasedKeyframes ? (86_400.0 as CFNumber) : (1.0 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: interval)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: duration)
    }

    /// Apply the current bitrate/quality/frameRate to the existing session
    /// without recreating it. Returns false when any property is rejected so
    /// the caller can fall back to full session recreation.
    private func applyRuntimeProperties() -> Bool {
        guard let session = compressionSession else { return false }
        let properties: [(CFString, CFTypeRef)] = [
            (kVTCompressionPropertyKey_AverageBitRate, bitrateMbps * 1_000_000 as CFNumber),
            (kVTCompressionPropertyKey_Quality, currentQualityValue as CFNumber),
            (kVTCompressionPropertyKey_ExpectedFrameRate, frameRate as CFNumber)
        ]
        for (key, value) in properties {
            let status = VTSessionSetProperty(session, key: key, value: value)
            guard status == noErr else {
                debugLog("Live update rejected for \(key): \(status) — recreating session")
                return false
            }
        }
        debugLog("Encoder settings applied live (\(bitrateMbps)Mbps, \(gamingBoost ? "🎮" : quality), \(frameRate)fps)")
        return true
    }

    // Quality based on preset. Gaming Boost is a latency-first preset: the
    // encoder favors speed over per-frame quality; bitrate stays user-set.
    //
    // Every value stays ≤ 0.65: on Apple HW encoders a Quality around 0.8+
    // DOMINATES rate control — measured on-device, the encoder emitted
    // 250-320 Mbps while AverageBitRate commanded 10-24, saturating the USB
    // link into permanent congestion (the adaptive bitrate controller then
    // floored, and capture half-drops pinned the stream at ~60fps). Below
    // ~0.65 the bitrate target is authoritative and the preset only trades
    // encoder effort/sharpness within that budget.
    private var currentQualityValue: Float {
        if gamingBoost {
            return 0.3  // Ultra low quality for maximum speed
        }
        return switch quality {
        case "ultralow": 0.5
        case "low": 0.58
        case "medium": 0.62
        case "high": 0.65
        default: 0.5
        }
    }

    private func setupCompressionSession() {
        var session: VTCompressionSession?

        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            encoderSpecification: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: encodingOutputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )

        guard status == noErr, let session = session else {
            debugLog("Failed to create compression session: \(status)")
            return
        }

        compressionSession = session

        // Ultra-low latency config for real-time streaming
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        // H.264 Main profile: decodable by every AVC hardware decoder
        // (Baseline/Main/High all accept Main-constrained streams' feature
        // set we use). High adds 8x8 transform that some low-end vendor OMX
        // decoders reject — not worth the marginal gain for screen content.
        let profile: CFString = codec == .hevc
            ? kVTProfileLevel_HEVC_Main_AutoLevel
            : kVTProfileLevel_H264_Main_AutoLevel
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: profile)

        // AverageBitRate is a VBR target: actual output follows scene
        // complexity, so the user's setting is applied as-is. Wireless links
        // are capped upstream (AppDelegate) until adaptive bitrate lands.
        let bitrateBps = bitrateMbps * 1_000_000
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrateBps as CFNumber)
        // Removed DataRateLimits - was causing bursty traffic and buffer stalls

        // Frame rate settings
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: frameRate as CFNumber)

        // Short-GOP IPP: 1 keyframe per second, P-frames in between.
        // All-intra (every frame keyframe) was producing 3-5x more data than needed,
        // saturating tablet decode/compose pipeline at high panel resolutions and
        // starving Mac WindowServer with encoder load. Short-GOP IPP gives 99% of
        // the resilience (frame loss recovery within 1 second) at a fraction of
        // the per-frame cost. TCP over USB-C rarely drops, so 1s GOP is safe.
        // v2 clients switch to request-based IDR (see setRequestBasedKeyframes).
        applyKeyframePolicy(session)

        // Critical for low latency - NO frame reordering (no B-frames)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)

        // NOTE: MaxFrameDelayCount is deliberately NOT set. With frame
        // reordering already disabled (no B-frames) it adds no latency
        // benefit, but 0 forbids the HW encoder from pipelining consecutive
        // frames — throughput collapses from 1/interval to 1/latency and a
        // 3840x2400 stream capped out near 70fps because of it.

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_Quality, value: currentQualityValue as CFNumber)

        // Use VBR (variable bitrate) instead of CBR for burst capacity during fast scene changes
        // CBR causes over-quantization (blocky artifacts) when scene complexity spikes
        // Removed: kVTCompressionPropertyKey_ConstantBitRate

        VTCompressionSessionPrepareToEncodeFrames(session)

        // Verify HW engagement: Require* fails session creation on non-HW
        // paths, but log the property too so silent regressions are visible.
        var usingHW: CFTypeRef?
        VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder, allocator: nil, valueOut: &usingHW)
        let hwText = (usingHW as? Bool) == true ? "HW" : "SW?!"
        let mode = gamingBoost ? "🎮 GAMING BOOST" : quality.uppercased()
        debugLog("VideoToolbox encoder configured (\(codec == .hevc ? "H.265" : "H.264"), \(bitrateMbps)Mbps, \(frameRate)fps, \(mode), \(hwText))")
    }

    /// Force the next encoded frame to be an IDR (sync) frame.
    /// Used when a fresh client connects so its decoder can start immediately
    /// instead of waiting up to one full GOP for the next scheduled keyframe.
    func requestKeyframe() {
        stateLock.withLock { $0.pendingForceKeyframe = true }
    }

    func encode(pixelBuffer: CVPixelBuffer, presentationTimeStamp: CMTime) {
        guard let session = compressionSession else { return }

        let duration = CMTime(value: 1, timescale: CMTimeScale(frameRate))

        // Use system uptime clock — MUST match DispatchTime.now().uptimeNanoseconds
        let captureNanos = DispatchTime.now().uptimeNanoseconds
        // Pointer-payload: the timestamp IS the pointer value. Kills the
        // per-frame heap allocate/deallocate pair the old refcon needed.
        // uptimeNanoseconds is never 0, so bitPattern never yields nil.
        let refconValue = UnsafeMutableRawPointer(bitPattern: UInt(captureNanos))

        let shouldForceKeyframe = stateLock.withLock { state -> Bool in
            guard state.pendingForceKeyframe else { return false }
            state.pendingForceKeyframe = false
            return true
        }
        let frameProperties: CFDictionary? = shouldForceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            : nil

        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTimeStamp,
            duration: duration,
            frameProperties: frameProperties,
            sourceFrameRefcon: refconValue,
            infoFlagsOut: nil
        )
    }

    deinit {
        if let session = compressionSession {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
    }
}

private let encodingOutputCallback: VTCompressionOutputCallback = { (outputCallbackRefCon, sourceFrameRefCon, status, _, sampleBuffer) in
    guard status == noErr,
          let sampleBuffer = sampleBuffer,
          let refcon = outputCallbackRefCon else {
        return
    }

    let encoder = Unmanaged<VideoEncoder>.fromOpaque(refcon).takeUnretainedValue()

    // Get timestamp for frame age tracking (pointer-payload — see encode()).
    let timestamp: UInt64
    if let refcon = sourceFrameRefCon {
        timestamp = UInt64(UInt(bitPattern: refcon))
    } else {
        timestamp = DispatchTime.now().uptimeNanoseconds
    }

    // Check if this is a keyframe
    let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
    let isKeyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)

    // No Annex-B conversion here anymore: the raw length-prefixed bitstream is
    // wrapped zero-copy; the transport converts only for legacy v1 clients.
    guard let payload = Bitstream.lengthPrefixedPayload(from: sampleBuffer) else { return }

    encoder.onEncodedFrame?(EncodedFrame(
        payload: payload,
        formatDescription: CMSampleBufferGetFormatDescription(sampleBuffer),
        isKeyframe: isKeyframe,
        captureNanos: timestamp,
        encodeDoneNanos: DispatchTime.now().uptimeNanoseconds))
}
