package com.sidescreen.app.transport

import android.os.ParcelFileDescriptor
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.InputStream
import java.io.OutputStream

/**
 * Streams over an opened USB accessory (AOA bulk pipes).
 *
 * Reads go through [AccessoryChunkedInputStream]: the f_accessory kernel
 * driver DISCARDS the remainder of a completed 16KB URB when the userspace
 * read buffer is smaller, so every kernel read must use a 16384-byte buffer.
 * Callers then consume from that buffer at any granularity.
 */
class AoaTransport(
    private val pfd: ParcelFileDescriptor,
) : StreamTransport {
    override val input: InputStream = AccessoryChunkedInputStream(FileInputStream(pfd.fileDescriptor))
    override val output: OutputStream = FileOutputStream(pfd.fileDescriptor)
    override val kind = TransportKind.AOA
    override val descriptor = "USB direct (AOA)"

    override fun close() {
        // Also unblocks a reader parked in read().
        pfd.close()
    }
}

class AccessoryChunkedInputStream(
    private val raw: FileInputStream,
) : InputStream() {
    private val chunk = ByteArray(16384)
    private var chunkLen = 0
    private var chunkPos = 0

    private fun fill(): Boolean {
        val n = raw.read(chunk, 0, chunk.size)
        if (n <= 0) return false
        chunkLen = n
        chunkPos = 0
        return true
    }

    override fun read(): Int {
        if (chunkPos >= chunkLen && !fill()) return -1
        return chunk[chunkPos++].toInt() and 0xFF
    }

    override fun read(
        b: ByteArray,
        off: Int,
        len: Int,
    ): Int {
        if (len == 0) return 0
        if (chunkPos >= chunkLen) {
            // The f_accessory rule is about the KERNEL read buffer being at
            // least 16384 bytes — when the caller's remaining window already
            // satisfies that (bulk frame reads do), read straight into it and
            // skip the staging copy entirely.
            if (len >= chunk.size) {
                return raw.read(b, off, len)
            }
            if (!fill()) return -1
        }
        val take = minOf(len, chunkLen - chunkPos)
        System.arraycopy(chunk, chunkPos, b, off, take)
        chunkPos += take
        return take
    }

    override fun available(): Int = chunkLen - chunkPos

    override fun close() {
        raw.close()
    }
}
