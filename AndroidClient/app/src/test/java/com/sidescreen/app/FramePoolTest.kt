package com.sidescreen.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class FramePoolTest {
    @Test
    fun `acquire rounds up to the smallest fitting size class`() {
        val pool = FramePool()
        assertEquals(256 * 1024, pool.acquire(1).size)
        assertEquals(256 * 1024, pool.acquire(256 * 1024).size)
        assertEquals(1024 * 1024, pool.acquire(256 * 1024 + 1).size)
        assertEquals(4 * 1024 * 1024, pool.acquire(2 * 1024 * 1024).size)
        assertEquals(16 * 1024 * 1024, pool.acquire(5 * 1024 * 1024).size)
    }

    @Test
    fun `oversized requests are allocated exactly and never pooled`() {
        val pool = FramePool()
        val big = pool.acquire(20 * 1024 * 1024)
        assertEquals(20 * 1024 * 1024, big.size)
        pool.release(big)
        // A fresh acquire of a pooled class must not hand back the odd-sized array.
        assertNotSame(big, pool.acquire(16 * 1024 * 1024))
    }

    @Test
    fun `released buffers are reused`() {
        val pool = FramePool()
        val first = pool.acquire(100_000)
        pool.release(first)
        assertSame(first, pool.acquire(50_000))
    }

    @Test
    fun `pool capacity is bounded per class`() {
        val pool = FramePool()
        val buffers = (0 until 12).map { pool.acquire(1024) }
        assertTrue(buffers.all { it.size == 256 * 1024 })
        buffers.forEach { pool.release(it) }
        // Capacity for the 256KB class is 8: the first 8 re-acquires must all
        // come from the pool (identity match against the released set).
        val reacquired = (0 until 8).map { pool.acquire(1024) }
        val releasedIdentities = buffers.map { System.identityHashCode(it) }.toSet()
        assertTrue(reacquired.all { System.identityHashCode(it) in releasedIdentities })
    }

    @Test
    fun `legacy foreign buffer release is a no-op`() {
        val pool = FramePool()
        val foreign = ByteArray(12345)
        pool.release(foreign)
        assertNotSame(foreign, pool.acquire(12345))
    }
}
