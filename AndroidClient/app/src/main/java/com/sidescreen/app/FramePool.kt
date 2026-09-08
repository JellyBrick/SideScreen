package com.sidescreen.app

import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicInteger

/**
 * Size-bucketed frame buffer pool. [acquire] rounds the request up to the
 * nearest size class and pops a pooled array in O(1) without holding a lock;
 * [release] returns it when the class is below capacity. Requests larger than
 * the biggest class are allocated directly and never pooled.
 *
 * Replaces the old single-deque pool whose acquire did a linear scan under a
 * lock on the hot receive path.
 */
class FramePool {
    private class Bucket(val size: Int, val capacity: Int) {
        val buffers = ConcurrentLinkedQueue<ByteArray>()
        val pooledCount = AtomicInteger(0)
    }

    // ~48MB worst case with every bucket full. The 16MB class matches the
    // soft frame-size cap in StreamClient.
    private val buckets =
        arrayOf(
            Bucket(256 * 1024, 8),
            Bucket(1024 * 1024, 6),
            Bucket(4 * 1024 * 1024, 3),
            Bucket(16 * 1024 * 1024, 2),
        )

    fun acquire(minSize: Int): ByteArray {
        for (bucket in buckets) {
            if (bucket.size >= minSize) {
                val pooled = bucket.buffers.poll()
                if (pooled != null) {
                    bucket.pooledCount.decrementAndGet()
                    return pooled
                }
                return ByteArray(bucket.size)
            }
        }
        return ByteArray(minSize)
    }

    fun release(buffer: ByteArray) {
        for (bucket in buckets) {
            if (bucket.size == buffer.size) {
                if (bucket.pooledCount.incrementAndGet() <= bucket.capacity) {
                    bucket.buffers.add(buffer)
                } else {
                    bucket.pooledCount.decrementAndGet()
                }
                return
            }
        }
        // Not a pooled size class (oversized or legacy allocation): let GC take it.
    }
}
