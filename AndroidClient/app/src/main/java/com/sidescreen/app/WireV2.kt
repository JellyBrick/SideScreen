package com.sidescreen.app

import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Protocol v2 codec — mirror of MacHost/Sources/WireProtocolV2.swift.
 *
 * Negotiation: the client sends v1 type 14 (payload-free) before type 8; a v2
 * host answers v1 type 15 + [version], after which both directions speak the
 * [type u8][len u24 BE] envelope exclusively. Legacy pairings are unaffected.
 * (v1 types 12/13 belong to the upstream desktop-geometry exchange and must
 * never be reused here.)
 *
 * All multi-byte integers are big endian except the touch payload, which
 * keeps v1's little-endian layout verbatim.
 */
object WireV2 {
    const val NEGOTIATION_REQUEST = 14
    const val NEGOTIATION_ACCEPT = 15
    const val VERSION = 2

    const val ENVELOPE_SIZE = 4

    const val MSG_DISPLAY_CONFIG = 1
    const val MSG_TOUCH = 2
    const val MSG_PING = 4
    const val MSG_PONG = 5
    const val MSG_FRAME_BEGIN = 6
    const val MSG_FRAME_CHUNK = 7
    const val MSG_KEYFRAME_REQUEST = 8
    const val MSG_VIDEO_CONFIG = 9
    const val MSG_CLIENT_STATS = 10
    const val MSG_NOP = 11
    const val MSG_DESKTOP_GEOMETRY = 12

    const val FRAME_FLAG_KEYFRAME = 1
    const val FRAME_FLAG_LENGTH_PREFIXED = 2

    const val FRAME_BEGIN_PAYLOAD_SIZE = 33
    const val PONG_PAYLOAD_SIZE = 24

    data class FrameBegin(
        val frameId: Long,
        val totalSize: Int,
        val flags: Int,
        val captureNs: Long,
        val encodeDoneNs: Long,
        val sendStartNs: Long,
    ) {
        val isKeyframe: Boolean get() = flags and FRAME_FLAG_KEYFRAME != 0
        val isLengthPrefixed: Boolean get() = flags and FRAME_FLAG_LENGTH_PREFIXED != 0
    }

    data class Pong(val t0: Long, val t1: Long, val t2: Long)

    fun envelope(
        type: Int,
        payloadLength: Int,
    ): ByteArray {
        require(payloadLength in 0 until (1 shl 24)) { "payload too large for u24: $payloadLength" }
        return byteArrayOf(
            type.toByte(),
            ((payloadLength shr 16) and 0xFF).toByte(),
            ((payloadLength shr 8) and 0xFF).toByte(),
            (payloadLength and 0xFF).toByte(),
        )
    }

    /** Returns (type, payloadLength) or null when fewer than 4 bytes given. */
    fun parseEnvelope(header: ByteArray): Pair<Int, Int>? {
        if (header.size < ENVELOPE_SIZE) return null
        val type = header[0].toInt() and 0xFF
        val len =
            ((header[1].toInt() and 0xFF) shl 16) or
                ((header[2].toInt() and 0xFF) shl 8) or
                (header[3].toInt() and 0xFF)
        return type to len
    }

    fun parseFrameBegin(payload: ByteArray): FrameBegin? {
        if (payload.size < FRAME_BEGIN_PAYLOAD_SIZE) return null
        val buf = ByteBuffer.wrap(payload).order(ByteOrder.BIG_ENDIAN)
        val frameId = buf.int.toLong() and 0xFFFFFFFFL
        val totalSize = buf.int
        val flags = buf.get().toInt() and 0xFF
        val captureNs = buf.long
        val encodeDoneNs = buf.long
        val sendStartNs = buf.long
        return FrameBegin(frameId, totalSize, flags, captureNs, encodeDoneNs, sendStartNs)
    }

    fun parsePong(payload: ByteArray): Pong? {
        if (payload.size < PONG_PAYLOAD_SIZE) return null
        val buf = ByteBuffer.wrap(payload).order(ByteOrder.BIG_ENDIAN)
        return Pong(buf.long, buf.long, buf.long)
    }

    fun encodePing(t0: Long): ByteArray {
        val out = ByteBuffer.allocate(ENVELOPE_SIZE + 8).order(ByteOrder.BIG_ENDIAN)
        out.put(envelope(MSG_PING, 8))
        out.putLong(t0)
        return out.array()
    }

    fun encodeKeyframeRequest(force: Boolean): ByteArray {
        val out = ByteArray(ENVELOPE_SIZE + 1)
        envelope(MSG_KEYFRAME_REQUEST, 1).copyInto(out)
        out[ENVELOPE_SIZE] = if (force) 1 else 0
        return out
    }

    /**
     * Touch payload keeps the v1 little-endian body (count, floats, action) —
     * only the envelope is new.
     */
    fun encodeTouch(
        x: Float,
        y: Float,
        action: Int,
        pointerCount: Int,
        x2: Float,
        y2: Float,
    ): ByteArray {
        val count = pointerCount.coerceIn(1, 2)
        val payloadSize = 1 + count * 8 + 4
        val out = ByteBuffer.allocate(ENVELOPE_SIZE + payloadSize)
        out.put(envelope(MSG_TOUCH, payloadSize))
        out.order(ByteOrder.LITTLE_ENDIAN)
        out.put(count.toByte())
        out.putFloat(x)
        out.putFloat(y)
        if (count == 2) {
            out.putFloat(x2)
            out.putFloat(y2)
        }
        out.putInt(action)
        return out.array()
    }

    /**
     * Rewrite 4-byte NAL length prefixes to Annex-B start codes in place.
     * Same byte count, so this fuses with the copy into the codec input
     * buffer that has to happen anyway. Returns false when the prefixes do
     * not add up to [length] (corrupt frame — caller should resync on IDR).
     */
    fun rewriteLengthPrefixesToStartCodes(
        data: ByteArray,
        start: Int,
        length: Int,
    ): Boolean {
        var offset = start
        val end = start + length
        while (offset + 4 <= end) {
            val nalLength =
                ((data[offset].toInt() and 0xFF) shl 24) or
                    ((data[offset + 1].toInt() and 0xFF) shl 16) or
                    ((data[offset + 2].toInt() and 0xFF) shl 8) or
                    (data[offset + 3].toInt() and 0xFF)
            if (nalLength <= 0 || offset + 4 + nalLength > end) return false
            data[offset] = 0
            data[offset + 1] = 0
            data[offset + 2] = 0
            data[offset + 3] = 1
            offset += 4 + nalLength
        }
        return offset == end
    }
}
