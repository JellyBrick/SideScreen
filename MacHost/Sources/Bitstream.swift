import Foundation
import CoreMedia

/// One encoded frame, zero-copy from VideoToolbox.
///
/// `payload` is the raw AVCC/HVCC bitstream (4-byte length-prefixed NAL
/// units) wrapped WITHOUT copying: a custom deallocator keeps the backing
/// CMSampleBuffer alive until the last reference (send completion) drops.
/// v2 clients receive it as-is (they rewrite prefixes to start codes during
/// their codec-input copy); the legacy v1 path converts via
/// `Bitstream.annexB(from:codec:)`.
struct EncodedFrame {
    let payload: Data
    let formatDescription: CMFormatDescription?
    let isKeyframe: Bool
    let captureNanos: UInt64
    let encodeDoneNanos: UInt64
}

private let nalStartCode: [UInt8] = [0, 0, 0, 1]

enum Bitstream {
    /// Wrap a sample buffer's data without copying. Falls back to a contiguous
    /// copy only when the CMBlockBuffer is fragmented (rare for VT output; the
    /// old code silently misread that case by trusting the first segment).
    static func lengthPrefixedPayload(from sampleBuffer: CMSampleBuffer) -> Data? {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }

        var lengthAtOffset = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer)
        guard status == kCMBlockBufferNoErr, let pointer = dataPointer else { return nil }

        if lengthAtOffset == totalLength {
            // Contiguous: zero-copy wrap; the deallocator pins the sample
            // buffer (and with it the block buffer memory) until Data dies.
            let retained = sampleBuffer
            return Data(
                bytesNoCopy: UnsafeMutableRawPointer(pointer),
                count: totalLength,
                deallocator: .custom { _, _ in withExtendedLifetime(retained) {} })
        }

        // Fragmented block buffer: assemble one contiguous copy.
        var assembled = Data(capacity: totalLength)
        var offset = 0
        while offset < totalLength {
            var segmentLength = 0
            var segmentPointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(
                dataBuffer,
                atOffset: offset,
                lengthAtOffsetOut: &segmentLength,
                totalLengthOut: nil,
                dataPointerOut: &segmentPointer) == kCMBlockBufferNoErr,
                let segment = segmentPointer else { return nil }
            assembled.append(UnsafeRawPointer(segment).assumingMemoryBound(to: UInt8.self), count: segmentLength)
            offset += segmentLength
        }
        return assembled
    }

    /// Annex-B parameter sets (VPS/SPS/PPS for HEVC, SPS/PPS for H.264) from
    /// a format description, each prefixed with a start code.
    static func parameterSets(from formatDescription: CMFormatDescription, codec: StreamCodec) -> Data {
        var result = Data()
        var parameterSetCount = 0
        let countStatus: OSStatus
        if codec == .hevc {
            countStatus = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                formatDescription, parameterSetIndex: 0, parameterSetPointerOut: nil,
                parameterSetSizeOut: nil, parameterSetCountOut: &parameterSetCount, nalUnitHeaderLengthOut: nil)
        } else {
            countStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDescription, parameterSetIndex: 0, parameterSetPointerOut: nil,
                parameterSetSizeOut: nil, parameterSetCountOut: &parameterSetCount, nalUnitHeaderLengthOut: nil)
        }
        guard countStatus == noErr else {
            debugLog("Parameter set count query failed: \(countStatus)")
            return result
        }

        for i in 0..<parameterSetCount {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            if codec == .hevc {
                CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    formatDescription, parameterSetIndex: i, parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            } else {
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    formatDescription, parameterSetIndex: i, parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            }
            if let pointer = pointer {
                result.append(contentsOf: nalStartCode)
                result.append(pointer, count: size)
            }
        }
        return result
    }

    /// Legacy v1 conversion: Annex-B with in-band parameter sets before
    /// keyframes — byte-identical to the pre-refactor encoder output.
    static func annexB(from frame: EncodedFrame, codec: StreamCodec) -> Data {
        let payload = frame.payload
        var out = Data(capacity: payload.count + (frame.isKeyframe ? 256 : 0) + 32)

        if frame.isKeyframe, let formatDescription = frame.formatDescription {
            out.append(parameterSets(from: formatDescription, codec: codec))
        }

        payload.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset + 4 <= raw.count {
                var nalLength: UInt32 = 0
                memcpy(&nalLength, base.advanced(by: offset), 4)
                nalLength = UInt32(bigEndian: nalLength)
                offset += 4
                guard offset + Int(nalLength) <= raw.count else { return }
                out.append(contentsOf: nalStartCode)
                out.append(base.advanced(by: offset).assumingMemoryBound(to: UInt8.self), count: Int(nalLength))
                offset += Int(nalLength)
            }
        }
        return out
    }
}
