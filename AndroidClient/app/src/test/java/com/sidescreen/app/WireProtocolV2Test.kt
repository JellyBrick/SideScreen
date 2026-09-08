package com.sidescreen.app

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

class WireProtocolV2Test {
    @Test
    fun `envelope round trip`() {
        val env = WireV2.envelope(WireV2.MSG_FRAME_CHUNK, 0x012345)
        assertEquals(WireV2.ENVELOPE_SIZE, env.size)
        val (type, len) = WireV2.parseEnvelope(env)!!
        assertEquals(WireV2.MSG_FRAME_CHUNK, type)
        assertEquals(0x012345, len)
    }

    @Test
    fun `short envelope returns null`() {
        assertNull(WireV2.parseEnvelope(byteArrayOf(1, 2, 3)))
    }

    @Test
    fun `frame begin parses swift layout`() {
        // Mirror of WireV2.encodeFrameBegin on the Mac: BE fields after envelope.
        val buf = ByteBuffer.allocate(WireV2.FRAME_BEGIN_PAYLOAD_SIZE).order(ByteOrder.BIG_ENDIAN)
        buf.putInt(-0x21524111) // 0xDEADBEEF
        buf.putInt(1_234_567)
        buf.put((WireV2.FRAME_FLAG_KEYFRAME or WireV2.FRAME_FLAG_LENGTH_PREFIXED).toByte())
        buf.putLong(0x0102030405060708L)
        buf.putLong(0x1112131415161718L)
        buf.putLong(-0x112233445566778L)
        val begin = WireV2.parseFrameBegin(buf.array())!!
        assertEquals(0xDEADBEEFL, begin.frameId)
        assertEquals(1_234_567, begin.totalSize)
        assertTrue(begin.isKeyframe)
        assertTrue(begin.isLengthPrefixed)
        assertEquals(0x0102030405060708L, begin.captureNs)
    }

    @Test
    fun `pong parses three timestamps`() {
        val buf = ByteBuffer.allocate(WireV2.PONG_PAYLOAD_SIZE).order(ByteOrder.BIG_ENDIAN)
        buf.putLong(1)
        buf.putLong(2)
        buf.putLong(3)
        val pong = WireV2.parsePong(buf.array())!!
        assertEquals(1L, pong.t0)
        assertEquals(2L, pong.t1)
        assertEquals(3L, pong.t2)
    }

    @Test
    fun `touch payload keeps v1 little endian body`() {
        val msg = WireV2.encodeTouch(0.5f, 0.25f, 2, 1, 0f, 0f)
        val (type, len) = WireV2.parseEnvelope(msg)!!
        assertEquals(WireV2.MSG_TOUCH, type)
        assertEquals(1 + 8 + 4, len)
        val body = ByteBuffer.wrap(msg, WireV2.ENVELOPE_SIZE, len).order(ByteOrder.LITTLE_ENDIAN)
        assertEquals(1, body.get().toInt())
        assertEquals(0.5f, body.float, 0f)
        assertEquals(0.25f, body.float, 0f)
        assertEquals(2, body.int)
    }

    @Test
    fun `length prefix rewrite produces start codes`() {
        // Two NALs: 3 bytes and 2 bytes.
        val data =
            byteArrayOf(
                0, 0, 0, 3, 0x40, 0x01, 0x02,
                0, 0, 0, 2, 0x26, 0x7F,
            )
        assertTrue(WireV2.rewriteLengthPrefixesToStartCodes(data, 0, data.size))
        assertArrayEquals(byteArrayOf(0, 0, 0, 1), data.copyOfRange(0, 4))
        assertArrayEquals(byteArrayOf(0, 0, 0, 1), data.copyOfRange(7, 11))
        assertEquals(0x40.toByte(), data[4])
        assertEquals(0x26.toByte(), data[11])
    }

    @Test
    fun `corrupt length prefix is rejected`() {
        val overrun = byteArrayOf(0, 0, 0, 9, 1, 2, 3) // claims 9 bytes, has 3
        assertFalse(WireV2.rewriteLengthPrefixesToStartCodes(overrun, 0, overrun.size))
        val truncatedTail = byteArrayOf(0, 0, 0, 2, 1, 2, 0, 0) // dangling 2 bytes
        assertFalse(WireV2.rewriteLengthPrefixesToStartCodes(truncatedTail, 0, truncatedTail.size))
    }

    @Test
    fun `keyframe request flag byte`() {
        val forced = WireV2.encodeKeyframeRequest(force = true)
        val (type, len) = WireV2.parseEnvelope(forced)!!
        assertEquals(WireV2.MSG_KEYFRAME_REQUEST, type)
        assertEquals(1, len)
        assertEquals(1, forced[WireV2.ENVELOPE_SIZE].toInt())
        assertEquals(0, WireV2.encodeKeyframeRequest(force = false)[WireV2.ENVELOPE_SIZE].toInt())
    }
}
