package com.sidescreen.app

import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat

/**
 * One-shot decoder capability probe. AVC-only devices drive the H.264
 * wire-protocol negotiation (the Mac encodes H.264 instead of HEVC).
 *
 * "Has HEVC" means the device has a *usable hardware* HEVC decoder — not merely
 * any decoder that advertises the type. Two classes of device are deliberately
 * routed to H.264 instead:
 *
 *  - **Software-only HEVC** (e.g. Onyx Boox Nova Air C, whose vendor
 *    media_codecs.xml disables HW HEVC): the Google software decoder
 *    (c2.android.hevc / OMX.google.hevc) is far too slow for real-time mirroring.
 *
 *  - **Broken vendor HW HEVC**: Spreadtrum/Unisoc (OMX.sprd.hevc, c2.sprd.*)
 *    advertise a HW HEVC decoder that configures and starts successfully but
 *    never renders decoded frames to the output Surface — the SurfaceView stays
 *    empty and the user sees a black screen (e.g. Yuho Tab 10, SC9863A + PowerVR).
 *
 * Both classes have a working hardware H.264 decoder, so H.264 is the reliable
 * path for them.
 */
object CodecCapabilities {
    /** Decoder-name prefixes whose HEVC implementation is unusable for surface output. */
    private val BROKEN_HEVC_HW_PREFIXES = listOf("omx.sprd.", "c2.sprd.")

    /**
     * Usable *hardware* decoder for [mime]: not an encoder, not the (too slow
     * for real-time mirroring) Google software implementation, and for HEVC
     * not one of the vendor implementations that never render to a Surface.
     * Shared by [hasHevcDecoder] and [nominalMaxDecodeSize] so the classification
     * cannot drift between them. Same hardware/software split
     * VideoDecoder.findBestDecoder uses.
     */
    private fun isUsableHardwareDecoder(
        info: MediaCodecInfo,
        mime: String,
    ): Boolean {
        if (info.isEncoder) return false
        if (info.supportedTypes.none { it.equals(mime, ignoreCase = true) }) return false
        val name = info.name.lowercase()
        val isSoftware = name.startsWith("c2.android.") || name.startsWith("omx.google.")
        val isBrokenHevc =
            mime.equals(MediaFormat.MIMETYPE_VIDEO_HEVC, ignoreCase = true) &&
                BROKEN_HEVC_HW_PREFIXES.any { name.startsWith(it) }
        return !isSoftware && !isBrokenHevc
    }

    val hasHevcDecoder: Boolean by lazy {
        try {
            MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos.any {
                isUsableHardwareDecoder(it, MediaFormat.MIMETYPE_VIDEO_HEVC)
            }
        } catch (_: Exception) {
            true // fail open: assume HEVC, preserving legacy behavior
        }
    }

    /** Mime the client will ask the Mac to stream: HEVC when usable, else AVC. */
    val streamMime: String
        get() = if (hasHevcDecoder) MediaFormat.MIMETYPE_VIDEO_HEVC else MediaFormat.MIMETYPE_VIDEO_AVC

    private val nominalSizeCache = HashMap<String, Pair<Int, Int>?>()

    /**
     * The `size` limit the largest usable *hardware* decoder for [mime] advertises. Null when
     * nothing usable exists or the probe fails (legacy behavior: advertise no limit to the Mac).
     * Cached per mime: enumerating MediaCodecList is not cheap and the answer never changes at
     * runtime (same reason hasHevcDecoder is lazy).
     *
     * Nominal, not achievable. Vendor decoders routinely advertise a `size` far above what their
     * `blocks-per-second` budget can sustain, and configuring above that budget succeeds and then
     * silently never outputs a frame. Prefer [maxStreamSize] for anything the Mac will encode.
     */
    fun nominalMaxDecodeSize(mime: String): Pair<Int, Int>? =
        synchronized(nominalSizeCache) {
            nominalSizeCache.getOrPut(mime.lowercase()) { probeNominalSize(mime) }
        }

    private fun probeNominalSize(mime: String): Pair<Int, Int>? =
        bestVideoCapabilities(mime)?.let { it.supportedWidths.upper to it.supportedHeights.upper }

    /** Video capabilities of the largest usable hardware decoder for [mime]. */
    private fun bestVideoCapabilities(mime: String): MediaCodecInfo.VideoCapabilities? =
        try {
            MediaCodecList(MediaCodecList.ALL_CODECS)
                .codecInfos
                .asSequence()
                .filter { isUsableHardwareDecoder(it, mime) }
                .mapNotNull { info ->
                    try {
                        info.getCapabilitiesForType(mime).videoCapabilities
                    } catch (_: Exception) {
                        null
                    }
                }.maxByOrNull { it.supportedWidths.upper.toLong() * it.supportedHeights.upper.toLong() }
        } catch (_: Exception) {
            null
        }

    private const val BLOCK_ALIGN = 16

    /**
     * The largest frame the Mac should ever encode for us: no larger than the panel can show, and
     * within what the decoder sustains at [fps]. Null when no usable decoder exists or the probe
     * fails, which leaves the legacy "advertise nothing" behavior in place.
     *
     * The panel is the upper bound because anything above it is downscaled on arrival anyway, so
     * spending decode budget there buys nothing. [MediaCodecInfo.VideoCapabilities.areSizeAndRateSupported]
     * is the check that consults `blocks-per-second`, which [nominalMaxDecodeSize] misses. Shrinks
     * stepwise rather than solving directly because the budget counts aligned macroblocks.
     */
    fun maxStreamSize(
        mime: String,
        panelWidth: Int,
        panelHeight: Int,
        fps: Int,
    ): Pair<Int, Int>? {
        if (panelWidth <= 0 || panelHeight <= 0) return null
        val caps = bestVideoCapabilities(mime) ?: return null
        val rate = fps.coerceAtLeast(1).toDouble()

        var w = panelWidth.coerceAtMost(caps.supportedWidths.upper)
        var h = panelHeight.coerceAtMost(caps.supportedHeights.upper)
        val aspect = panelWidth.toDouble() / panelHeight.toDouble()

        repeat(40) {
            val alignedW = (w / BLOCK_ALIGN) * BLOCK_ALIGN
            val alignedH = (h / BLOCK_ALIGN) * BLOCK_ALIGN
            if (alignedW < 256 || alignedH < 256) return null
            val supported =
                try {
                    caps.areSizeAndRateSupported(alignedW, alignedH, rate)
                } catch (_: IllegalArgumentException) {
                    false
                } catch (_: Exception) {
                    return null
                }
            if (supported) return alignedW to alignedH
            w = (w * 0.95).toInt()
            h = (w / aspect).toInt()
        }
        return null
    }
}
