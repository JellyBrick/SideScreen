/// Video codec used for the encode session and wire stream.
enum StreamCodec {
    case hevc
    case h264

    /// Wire id used in the codecSelected (type 10) message.
    var wireId: UInt8 {
        switch self {
        case .hevc: return 0
        case .h264: return 1
        }
    }
}

enum CodecLimits {
    /// Conservative floor every AVC hardware decoder meets (H.264 level 4.x).
    /// AVC-only devices are low-end; their real cap is at or above this.
    static let avcMaxWidth = 1920
    static let avcMaxHeight = 1088

    /// Scale (width, height) down to fit within (maxWidth, maxHeight),
    /// preserving aspect ratio, flooring each dimension to a multiple of 16
    /// (codec macroblock alignment). Sizes already within the limit pass
    /// through unchanged.
    static func clamp(width: Int, height: Int, maxWidth: Int, maxHeight: Int) -> (width: Int, height: Int) {
        guard width > maxWidth || height > maxHeight else {
            return (width, height)
        }
        let scale = min(Double(maxWidth) / Double(width),
                        Double(maxHeight) / Double(height))
        let w = max(16, Int((Double(width) * scale).rounded()) & ~15)
        let h = max(16, Int((Double(height) * scale).rounded()) & ~15)
        return (w, h)
    }

    /// Conservative fallback for AVC clients that report no decoder limit.
    static func clampForAvc(width: Int, height: Int) -> (width: Int, height: Int) {
        clamp(width: width, height: height, maxWidth: avcMaxWidth, maxHeight: avcMaxHeight)
    }

    /// Frame rate the client measures its advertised limit at (mirrors
    /// CodecCapabilities.REFERENCE_FPS on Android).
    static let clientLimitReferenceFps = 60

    /// The client's limit is a blocks-per-second budget expressed as a frame
    /// size at `clientLimitReferenceFps`. Streaming faster than that spends the
    /// same budget on more frames, so shrink the box's area by
    /// reference/fps (each side by the square root), keeping its aspect.
    /// Slower streams do not grow it: the panel bound still applies.
    static func scaleLimit(_ limit: (width: Int, height: Int), forFps fps: Int) -> (width: Int, height: Int) {
        guard fps > clientLimitReferenceFps, limit.width > 0, limit.height > 0 else { return limit }
        let k = (Double(clientLimitReferenceFps) / Double(fps)).squareRoot()
        let w = max(16, Int((Double(limit.width) * k).rounded()) & ~15)
        let h = max(16, Int((Double(limit.height) * k).rounded()) & ~15)
        return (w, h)
    }

    /// Clamp into a client-reported ceiling, transposing the box when its
    /// orientation differs from the capture's. Clients report the ceiling in
    /// their panel's natural orientation, but it stands for a macroblock area
    /// budget, which is indifferent to which side is longer.
    static func clampToClientLimit(
        width: Int,
        height: Int,
        limit: (width: Int, height: Int)
    ) -> (width: Int, height: Int) {
        let box = (height > width) == (limit.height > limit.width)
            ? limit
            : (width: limit.height, height: limit.width)
        return clamp(width: width, height: height, maxWidth: box.width, maxHeight: box.height)
    }
}
