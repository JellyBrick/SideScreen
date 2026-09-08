package com.sidescreen.app

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Process
import android.util.Log
import com.sidescreen.app.transport.StreamTransport
import com.sidescreen.app.transport.TcpTransport
import com.sidescreen.app.transport.TransportKind
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.DataInputStream
import java.io.IOException
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class StreamClient(
    private val host: String,
    private val port: Int,
    private val context: Context? = null,
) {
    private var socket: Socket? = null
    private var transport: StreamTransport? = null
    private var inputStream: DataInputStream? = null
    private var outputStream: java.io.DataOutputStream? = null
    private var isConnected = false

    // Callback includes actual frame size (may differ from buffer.size due to pooling),
    // receive timestamp, and whether the frame can restart HEVC decoding.
    var onFrameReceived: ((ByteArray, Int, Long, Boolean) -> Unit)? = null
    var onConnectionStatus: ((Boolean) -> Unit)? = null
    var onDisplaySize: ((Int, Int, Int, Boolean, Boolean) -> Unit)? = null
    var onStats: ((Double, Double) -> Unit)? = null

    /** Invoked when the server confirms the stream codec (true = HEVC). */
    var onCodecSelected: ((Boolean) -> Unit)? = null

    /** Stream codec for sync-frame parsing. HEVC unless the server says otherwise. */
    @Volatile var streamCodecIsHevc = true
        private set

    /** True once a MESSAGE_CODEC_SELECTED arrived — distinguishes new Macs from old. */
    @Volatile var codecNegotiated = false
        private set

    /** True once the host accepted protocol v2 (type 13). */
    @Volatile var v2Active = false
        private set

    /**
     * False between our type-12 advert and the host's first reply. Outbound
     * traffic (ping/touch/keyframe requests) is gated on this: a v2 host
     * switches its input parser right after our type 8, so any v1-format
     * bytes sent in that window would corrupt its stream.
     */
    @Volatile private var protocolDecided = false

    val clockSync = ClockSync()

    /** (rttMs, clockOffsetMs, wireAgeP50Ms, wireAgeP95Ms) at 1 Hz — v2 only. */
    var onWireStats: ((Double, Double, Double, Double) -> Unit)? = null
    private var csdCache: ByteArray? = null
    private val wireAgesMs = ArrayList<Double>(256)
    private var lastRttMs = 0.0

    private var bytesReceived = 0L
    private var framesReceived = 0L
    private var diagFrameCount = 0L
    private var lastStatsTime = System.currentTimeMillis()
    private val keyframeRequestLock = Any()
    private var lastKeyframeRequestNs = 0L
    private var lastKeyframeReceivedNs = 0L
    private var lastSelfHealRequestNs = 0L

    // Buffer pooling to reduce GC pressure from per-frame allocations
    // At 60fps with ~100KB frames, this prevents ~6MB/s of allocations
    private val framePool = FramePool()

    /**
     * Release a buffer back to the pool for reuse
     * Called after decode completes via onFrameDecoded callback
     */
    fun releaseBuffer(buffer: ByteArray) {
        framePool.release(buffer)
    }

    // Decode decoupling: the receive loop must never block on MediaCodec, or a
    // slow decoder stalls the TCP read (and with it ping/pong handling).
    // Frames are handed to a dedicated pump thread through a small queue; when
    // the decoder falls behind, frames are dropped HERE — before decode — and
    // a forced keyframe rebuilds the reference chain.
    private class PooledFrame(
        val buf: ByteArray,
        val size: Int,
        val recvNs: Long,
        val isKeyframe: Boolean,
    )

    private val frameQueue = ArrayDeque<PooledFrame>(FRAME_QUEUE_CAPACITY)
    private val frameQueueLock = Object()
    private var framePump: Thread? = null
    private var queueDropCount = 0L

    private fun startFramePump() {
        stopFramePump()
        val pump = Thread(::framePumpLoop, "FramePump")
        pump.isDaemon = true
        framePump = pump
        pump.start()
    }

    private fun stopFramePump() {
        framePump?.interrupt()
        framePump = null
        synchronized(frameQueueLock) {
            while (frameQueue.isNotEmpty()) {
                framePool.release(frameQueue.removeFirst().buf)
            }
        }
    }

    private fun framePumpLoop() {
        try {
            Process.setThreadPriority(Process.THREAD_PRIORITY_DISPLAY)
        } catch (_: Exception) {
        }
        while (true) {
            val frame: PooledFrame
            synchronized(frameQueueLock) {
                while (frameQueue.isEmpty()) {
                    if (!isConnected) return
                    try {
                        frameQueueLock.wait(500)
                    } catch (_: InterruptedException) {
                        return
                    }
                }
                frame = frameQueue.removeFirst()
                frameQueueLock.notify() // wake a producer blocked on a full queue
            }
            val callback = onFrameReceived
            if (callback != null) {
                callback(frame.buf, frame.size, frame.recvNs, frame.isKeyframe)
            } else {
                framePool.release(frame.buf)
            }
        }
    }

    /** Dropping frames until the next IDR (clean resync — no ghosting). */
    private var awaitingResyncKeyframe = false

    private fun enqueueFrame(frame: PooledFrame) {
        var dropped: List<PooledFrame> = emptyList()
        var resyncStarted = false
        synchronized(frameQueueLock) {
            if (awaitingResyncKeyframe && !frame.isKeyframe) {
                // Mid-resync: this P references frames the decoder will never
                // see. Discard before decode; the picture freezes on the last
                // good frame until the requested IDR lands.
                framePool.release(frame.buf)
                queueDropCount++
                return
            }
            if (frameQueue.size >= FRAME_QUEUE_CAPACITY && !frame.isKeyframe) {
                // Block briefly instead of dropping: dropping an undecoded
                // P-frame breaks the IPP reference chain — on screen that is
                // smeared windows and motion-compensation cursor ghosts
                // during fast scrolls. Blocking stalls the transport read,
                // the backpressure reaches the host through the link, and
                // the HOST drops pre-encode where it is harmless.
                val deadlineNs = System.nanoTime() + QUEUE_BLOCK_MAX_NS
                while (frameQueue.size >= FRAME_QUEUE_CAPACITY && isConnected) {
                    val remainMs = (deadlineNs - System.nanoTime()) / 1_000_000
                    if (remainMs <= 0) break
                    try {
                        frameQueueLock.wait(remainMs)
                    } catch (_: InterruptedException) {
                        framePool.release(frame.buf)
                        return
                    }
                }
            }
            if (frameQueue.size >= FRAME_QUEUE_CAPACITY) {
                if (frame.isKeyframe) {
                    // Everything queued is superseded: the decoder restarts
                    // cleanly at this IDR (parameter sets ride in-band).
                    dropped = frameQueue.toList()
                    frameQueue.clear()
                } else {
                    // Still wedged after the grace window: clean resync.
                    // Discard everything (nothing partial ever reaches the
                    // decoder) and freeze until the forced IDR arrives.
                    dropped = frameQueue.toList() + listOf(frame)
                    frameQueue.clear()
                    awaitingResyncKeyframe = true
                    resyncStarted = true
                }
            }
            if (frame.isKeyframe) {
                awaitingResyncKeyframe = false
            }
            if (dropped.none { it === frame }) {
                frameQueue.addLast(frame)
            }
            frameQueueLock.notify()
        }
        if (dropped.isEmpty()) return

        queueDropCount += dropped.size
        for (d in dropped) {
            framePool.release(d.buf)
        }
        if (queueDropCount <= 3L || queueDropCount % 60L == 0L) {
            diagLog("Decode queue full: dropped ${dropped.size} frame(s), total=$queueDropCount")
        }
        if (resyncStarted) {
            diagLog("Decode queue wedged — clean IDR resync")
            requestKeyframe(force = true, reason = "decode queue resync")
        }
    }

    // High-priority thread for touch events to minimize latency
    // Use THREAD_PRIORITY_DISPLAY instead of URGENT_DISPLAY to avoid starving system processes
    private val touchExecutor =
        Executors.newSingleThreadExecutor { runnable ->
            Thread(
                {
                    // Use DISPLAY priority (less aggressive than URGENT_DISPLAY).
                    // ThreadFactory runs on the caller thread, so set Linux priority
                    // from inside the worker thread before processing touch writes.
                    try {
                        Process.setThreadPriority(Process.THREAD_PRIORITY_DISPLAY)
                    } catch (_: Exception) {
                    }
                    runnable.run()
                },
                "TouchThread",
            ).apply {
                priority = Thread.MAX_PRIORITY
            }
        }
    private val touchDispatcher = touchExecutor.asCoroutineDispatcher()
    private val touchScope = CoroutineScope(touchDispatcher)

    suspend fun connect() =
        withContext(Dispatchers.IO) {
            try {
                val s =
                    Socket().apply {
                        tcpNoDelay = true
                        // Must be set before connect: the TCP window scale is
                        // negotiated on SYN, so a post-connect resize cannot
                        // grow the window past 64KB.
                        receiveBufferSize = USB_SOCKET_RECEIVE_BUFFER
                        connect(java.net.InetSocketAddress(host, port))
                    }
                socket = s
                attach(TcpTransport(s, TransportKind.TCP_USB))

                diagLog("Connected to $host:$port")
                onConnectionStatus?.invoke(true)

                receiveData()
            } catch (e: Exception) {
                Log.e(TAG, "❌ Connection error", e)
                onConnectionStatus?.invoke(false)
                cleanup()
            }
        }

    sealed class WirelessConnectError(msg: String) : Exception(msg) {
        object NetworkUnreachable : WirelessConnectError("Mac unreachable — check both on same WiFi")

        object TokenRejected : WirelessConnectError("Token rejected — re-pair required")

        object ProtocolError : WirelessConnectError("Connection error, please rescan QR")
    }

    /**
     * Code-pairing failures (issue #35). Kept OUT of [WirelessConnectError] on
     * purpose: these can only be thrown by [pairWithCode] and are handled in
     * the pairing dialog, so putting them in the shared sealed class would just
     * grow dead branches in every exhaustive `when` over connect errors.
     */
    sealed class PairingError(msg: String) : Exception(msg) {
        /** The Mac rejected the typed one-time code. */
        object CodeRejected : PairingError("Pairing code not accepted")

        /** The Mac runs a version that predates code pairing. */
        object HostTooOld : PairingError("Update Side Screen on the Mac to use code pairing")
    }

    data class PairingSuccess(val token: ByteArray, val macName: String)

    /**
     * Opens a TCP socket to host:port, bound to the active WiFi network. On some
     * Android setups (especially LG/Android 12), an app's default outbound socket
     * may take a route that silently drops LAN traffic; binding to the WIFI
     * Network explicitly avoids that.
     */
    private fun openWirelessSocket(): Socket {
        try {
            val sock = Socket()
            sock.tcpNoDelay = true
            // Before connect — see the USB path for why. Wireless gets a
            // bigger window: Wi-Fi BDP with retransmits far exceeds loopback.
            sock.receiveBufferSize = WIRELESS_SOCKET_RECEIVE_BUFFER
            val wifiNetwork =
                context?.let { ctx ->
                    val cm = ctx.getSystemService(ConnectivityManager::class.java)
                    cm.allNetworks.firstOrNull { net ->
                        val caps = cm.getNetworkCapabilities(net)
                        caps?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true &&
                            caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                    }
                }
            if (wifiNetwork != null) {
                Log.i(TAG, "openWirelessSocket: binding socket to WiFi network $wifiNetwork")
                wifiNetwork.bindSocket(sock)
            } else {
                Log.w(TAG, "openWirelessSocket: no WiFi network found, using default routing")
            }
            sock.connect(java.net.InetSocketAddress(host, port), 5000)
            return sock
        } catch (e: java.net.SocketTimeoutException) {
            Log.e(TAG, "openWirelessSocket: TCP connect timeout to $host:$port (5s)")
            throw WirelessConnectError.NetworkUnreachable
        } catch (e: IOException) {
            Log.e(TAG, "openWirelessSocket: TCP connect failed to $host:$port: ${e.javaClass.simpleName}: ${e.message}")
            throw WirelessConnectError.NetworkUnreachable
        }
    }

    private fun readFully(
        s: Socket,
        buf: ByteArray,
    ): Boolean {
        var read = 0
        try {
            while (read < buf.size) {
                val r = s.getInputStream().read(buf, read, buf.size - read)
                if (r <= 0) break
                read += r
            }
        } catch (e: IOException) {
            return false
        }
        return read == buf.size
    }

    /**
     * Code pairing (issue #35): send the typed one-time code, receive the real
     * 32-byte token + Mac name, then close. The caller stores the result and
     * reconnects through the normal [connectWireless] handshake.
     * Throws [WirelessConnectError] or [PairingError] on failure. `use {}`
     * guarantees the socket closes on every path, including coroutine
     * cancellation and unexpected exceptions.
     */
    suspend fun pairWithCode(
        code: String,
        deviceName: String,
    ): PairingSuccess =
        withContext(Dispatchers.IO) {
            Log.i(TAG, "pairWithCode: trying $host:$port (device=$deviceName)")
            openWirelessSocket().use { s ->
                // A silent listener (user typed the wrong port) must not hang
                // the dialog forever: bound every blocking read.
                s.soTimeout = PAIRING_READ_TIMEOUT_MS

                try {
                    s.getOutputStream().write(AuthHandshake.encodePairingRequest(code, deviceName))
                    s.getOutputStream().flush()
                } catch (e: IOException) {
                    throw WirelessConnectError.NetworkUnreachable
                }

                val header = ByteArray(5)
                if (!readFully(s, header)) {
                    throw WirelessConnectError.ProtocolError
                }
                val parsed =
                    AuthHandshake.parsePairingResponseHeader(header)
                        ?: throw WirelessConnectError.ProtocolError
                when (parsed) {
                    is AuthHandshake.PairingHeader.LegacyHost -> throw PairingError.HostTooOld
                    is AuthHandshake.PairingHeader.Pairing -> {
                        if (parsed.status != AuthHandshake.PairingStatus.OK) {
                            throw PairingError.CodeRejected
                        }
                    }
                }

                val token = ByteArray(32)
                val nameLenBuf = ByteArray(1)
                if (!readFully(s, token) || !readFully(s, nameLenBuf)) {
                    throw WirelessConnectError.ProtocolError
                }
                val nameLen = nameLenBuf[0].toInt() and 0xFF
                if (nameLen !in 1..64) {
                    throw WirelessConnectError.ProtocolError
                }
                val nameBuf = ByteArray(nameLen)
                if (!readFully(s, nameBuf)) {
                    throw WirelessConnectError.ProtocolError
                }
                val macName = String(nameBuf, Charsets.UTF_8)
                Log.i(TAG, "pairWithCode: token issued by $macName")
                PairingSuccess(token, macName)
            }
        }

    /**
     * Wireless connect: opens TCP, performs auth handshake, then resumes the existing receive loop on success.
     * Throws WirelessConnectError on any failure.
     */
    suspend fun connectWireless(
        token: ByteArray,
        deviceName: String,
    ) = withContext(Dispatchers.IO) {
        Log.i(TAG, "connectWireless: trying $host:$port (device=$deviceName, token bytes=${token.size})")

        val s = openWirelessSocket()
        Log.i(
            TAG,
            "connectWireless: TCP connected, sending handshake (${37 + deviceName.toByteArray().size} bytes)",
        )

        val request = AuthHandshake.encodeRequest(token, deviceName)
        try {
            s.getOutputStream().write(request)
            s.getOutputStream().flush()
        } catch (e: IOException) {
            try {
                s.close()
            } catch (_: IOException) {
            }
            throw WirelessConnectError.NetworkUnreachable
        }

        val responseBuf = ByteArray(5)
        var read = 0
        try {
            while (read < 5) {
                val r = s.getInputStream().read(responseBuf, read, 5 - read)
                if (r <= 0) break
                read += r
            }
        } catch (e: IOException) {
            try {
                s.close()
            } catch (_: IOException) {
            }
            throw WirelessConnectError.NetworkUnreachable
        }
        if (read != 5) {
            try {
                s.close()
            } catch (_: IOException) {
            }
            throw WirelessConnectError.ProtocolError
        }

        val status =
            AuthHandshake.parseResponse(responseBuf) ?: run {
                try {
                    s.close()
                } catch (_: IOException) {
                }
                throw WirelessConnectError.ProtocolError
            }
        Log.i(TAG, "connectWireless: handshake response status=$status")
        when (status) {
            AuthHandshake.ResponseStatus.OK -> {
                socket = s
                attach(TcpTransport(s, TransportKind.TCP_WIRELESS))
                diagLog("Wireless connected to $host:$port")
                onConnectionStatus?.invoke(true)
                receiveData()
            }
            AuthHandshake.ResponseStatus.INVALID_TOKEN -> {
                try {
                    s.close()
                } catch (_: IOException) {
                }
                throw WirelessConnectError.TokenRejected
            }
            else -> {
                try {
                    s.close()
                } catch (_: IOException) {
                }
                throw WirelessConnectError.ProtocolError
            }
        }
    }

    /**
     * Adopt an established transport and speak the streaming protocol over
     * it: wraps the streams, resets per-session codec/keyframe state, and
     * advertises client capabilities. AOA will plug in here too — everything
     * from this point on is transport-independent.
     */
    private fun attach(t: StreamTransport) {
        transport = t
        // AOA input is already staged through the 16KB chunk buffer, and bulk
        // reads bypass even that (direct kernel→frame-buffer). A Buffered
        // layer on top would just re-copy the whole stream a third time.
        inputStream =
            if (t.kind == TransportKind.AOA) {
                DataInputStream(t.input)
            } else {
                DataInputStream(java.io.BufferedInputStream(t.input, 65536))
            }
        outputStream = java.io.DataOutputStream(t.output)
        streamCodecIsHevc = true
        codecNegotiated = false
        v2Active = false
        protocolDecided = false
        csdCache = null
        clockSync.reset()
        synchronized(wireAgesMs) { wireAgesMs.clear() }
        advertiseAvcOnlyIfNeeded() // MUST precede type 8: type 8 can trigger the server's early protocol finish
        advertiseDecoderLimits() // Also before type 8, for the same reason
        advertiseV2Support() // Before type 8 too: the host flips to v2 input right after type 8
        advertiseFrameMetadataSupport()
        isConnected = true
        lastKeyframeReceivedNs = 0L
        synchronized(keyframeRequestLock) {
            lastKeyframeRequestNs = 0L
        }
        diagLog("Transport attached: ${t.descriptor}")
    }

    /**
     * Connect over an opened USB accessory. Runs the SSAC/SSAR anti-stale
     * preamble first; throws before any state/UI callbacks when the Mac does
     * not answer, so the caller can fall back to the adb TCP path silently.
     */
    suspend fun connectAoa(t: StreamTransport) =
        withContext(Dispatchers.IO) {
            try {
                performAoaPreamble(t)
            } catch (e: Exception) {
                try {
                    t.close()
                } catch (_: Exception) {
                }
                throw e
            }
            socket = null
            attach(t)
            diagLog("AOA connected: ${t.descriptor}")
            onConnectionStatus?.invoke(true)
            receiveData()
        }

    /**
     * Mac→client: "SSAC" + version + nonce(8). Reply "SSAR" + version + echoed
     * nonce. A watchdog closes the transport when nothing valid arrives in
     * time (blocking accessory reads cannot be interrupted otherwise —
     * closing the descriptor makes the read throw).
     */
    private fun performAoaPreamble(t: StreamTransport) {
        val done = java.util.concurrent.atomic.AtomicBoolean(false)
        val watchdog =
            Thread({
                try {
                    Thread.sleep(AOA_PREAMBLE_TIMEOUT_MS)
                } catch (_: InterruptedException) {
                    return@Thread
                }
                if (!done.get()) {
                    diagLog("AOA preamble timeout — closing transport")
                    try {
                        t.close()
                    } catch (_: Exception) {
                    }
                }
            }, "AoaPreambleWatchdog")
        watchdog.isDaemon = true
        watchdog.start()

        try {
            val hello = ByteArray(AOA_PREAMBLE_LENGTH)
            var filled = 0
            while (filled < hello.size) {
                val n = t.input.read(hello, filled, hello.size - filled)
                if (n <= 0) throw IOException("AOA preamble: stream closed")
                filled += n
            }
            if (hello[0] != 'S'.code.toByte() || hello[1] != 'S'.code.toByte() ||
                hello[2] != 'A'.code.toByte() || hello[3] != 'C'.code.toByte()
            ) {
                throw IOException("AOA preamble: bad magic")
            }
            if (hello[4].toInt() != AOA_PREAMBLE_VERSION) {
                throw IOException("AOA preamble: unsupported version ${hello[4]}")
            }
            val reply = ByteArray(AOA_PREAMBLE_LENGTH)
            reply[0] = 'S'.code.toByte()
            reply[1] = 'S'.code.toByte()
            reply[2] = 'A'.code.toByte()
            reply[3] = 'R'.code.toByte()
            reply[4] = AOA_PREAMBLE_VERSION.toByte()
            System.arraycopy(hello, 5, reply, 5, 8) // echo the nonce
            t.output.write(reply)
            t.output.flush()
            diagLog("AOA preamble OK")
        } finally {
            done.set(true)
            watchdog.interrupt()
        }
    }

    private fun advertiseFrameMetadataSupport() {
        outputStream?.let { out ->
            out.writeByte(MESSAGE_CLIENT_SUPPORTS_FRAME_METADATA)
            out.flush()
            diagLog("Advertised frame metadata support")
        }
    }

    private fun advertiseV2Support() {
        outputStream?.let { out ->
            out.writeByte(WireV2.NEGOTIATION_REQUEST)
            out.flush()
            diagLog("Advertised protocol v2 support")
        }
    }

    private fun advertiseAvcOnlyIfNeeded() {
        if (CodecCapabilities.hasHevcDecoder) return
        outputStream?.let { out ->
            out.writeByte(MESSAGE_CLIENT_AVC_ONLY)
            out.flush()
            diagLog("Advertised AVC-only (no HEVC decoder on this device)")
        }
    }

    private fun advertiseDecoderLimits() {
        val (maxW, maxH) = CodecCapabilities.maxDecodeSize(CodecCapabilities.streamMime) ?: return
        val w = maxW.coerceAtMost(16383)
        val h = maxH.coerceAtMost(16383)
        if (w < 256 || h < 256) return
        outputStream?.let { out ->
            out.writeByte(MESSAGE_CLIENT_DECODER_LIMITS)
            // 7 data bits per byte with the high bit always set: an old Mac
            // skips unknown types one byte at a time, so payload bytes must
            // never collide with real message-type values.
            out.writeByte(0x80 or ((w shr 7) and 0x7F))
            out.writeByte(0x80 or (w and 0x7F))
            out.writeByte(0x80 or ((h shr 7) and 0x7F))
            out.writeByte(0x80 or (h and 0x7F))
            out.flush()
            diagLog("Advertised decoder limit ${w}x$h for ${CodecCapabilities.streamMime}")
        }
    }

    private suspend fun receiveData() =
        withContext(Dispatchers.IO) {
            val input = inputStream ?: return@withContext
            startFramePump()

            try {
                while (isConnected) {
                    val type = input.readByte()

                    when (type.toInt()) {
                        MESSAGE_VIDEO_FRAME -> {
                            protocolDecided = true
                            receiveVideoFrame(input, hasMetadata = false)
                        }

                        MESSAGE_VIDEO_FRAME_WITH_METADATA -> {
                            protocolDecided = true
                            receiveVideoFrame(input, hasMetadata = true)
                        }

                        WireV2.NEGOTIATION_ACCEPT -> {
                            val version = input.readUnsignedByte()
                            v2Active = true
                            protocolDecided = true
                            diagLog("Host accepted protocol v2 (version $version)")
                            receiveV2Loop(input)
                            break
                        }

                        1 -> {
                            protocolDecided = true
                            val width = input.readInt()
                            val height = input.readInt()
                            val transform = input.readInt()
                            val rotation = transform % 1000
                            val flags = transform / 1000
                            val flipHorizontal = flags and 1 == 1
                            val flipVertical = flags and 2 == 2
                            diagLog("Display config: ${width}x$height @ $rotation°, h=$flipHorizontal, v=$flipVertical")
                            onDisplaySize?.invoke(width, height, rotation, flipHorizontal, flipVertical)
                        }

                        5 -> { // Pong response — measure round-trip latency
                            val buf = ByteArray(8)
                            input.readFully(buf)
                            val sentTime = ByteBuffer.wrap(buf).order(ByteOrder.LITTLE_ENDIAN).long
                            val rtt = (System.nanoTime() - sentTime) / 1_000_000.0 // ms
                            onLatencyMeasured?.invoke(rtt)
                        }

                        MESSAGE_CODEC_SELECTED -> {
                            protocolDecided = true
                            val codecId = input.readByte().toInt()
                            streamCodecIsHevc = codecId == 0
                            codecNegotiated = true
                            diagLog("Server selected codec: ${if (streamCodecIsHevc) "HEVC" else "H.264"}")
                            onCodecSelected?.invoke(streamCodecIsHevc)
                        }

                        else -> {
                            Log.e(
                                TAG,
                                "Unknown message type: ${type.toInt()}, stream may be misaligned — disconnecting",
                            )
                            break
                        }
                    }
                }
            } catch (e: IOException) {
                if (isConnected) {
                    Log.e(TAG, "❌ Read error", e)
                }
            } finally {
                disconnect()
            }
        }

    fun sendTouch(
        x: Float,
        y: Float,
        action: Int,
        pointerCount: Int = 1,
        x2: Float = 0f,
        y2: Float = 0f,
    ) {
        if (!isConnected || !protocolDecided) return

        // MOVE coalescing: when the writer thread falls behind (link busy or
        // 240Hz digitizer with unbuffered dispatch), stale MOVEs are replaced
        // by the newest one instead of queueing. DOWN/UP are never coalesced,
        // and they flush any pending MOVE first to preserve ordering.
        val snapshot = TouchSnapshot(x, y, action, pointerCount, x2, y2)
        if (action == WIRE_ACTION_MOVE) {
            pendingMove.set(snapshot)
            touchScope.launch {
                val move = pendingMove.getAndSet(null) ?: return@launch
                writeTouch(move)
            }
            return
        }
        touchScope.launch {
            pendingMove.getAndSet(null)?.let { writeTouch(it) }
            writeTouch(snapshot)
        }
    }

    private data class TouchSnapshot(
        val x: Float,
        val y: Float,
        val action: Int,
        val pointerCount: Int,
        val x2: Float,
        val y2: Float,
    )

    private val pendingMove = java.util.concurrent.atomic.AtomicReference<TouchSnapshot?>(null)

    private fun writeTouch(s: TouchSnapshot) {
        try {
            outputStream?.let { out ->
                if (v2Active) {
                    out.write(WireV2.encodeTouch(s.x, s.y, s.action, s.pointerCount, s.x2, s.y2))
                    out.flush()
                    return@let
                }
                val count = s.pointerCount.coerceIn(1, 2)
                val size = 6 + count * 8 // 1 type + 1 count + N*(4x+4y) + 4 action
                val buffer = ByteBuffer.allocate(size).order(ByteOrder.LITTLE_ENDIAN)
                buffer.put(2.toByte())
                buffer.put(count.toByte())
                buffer.putFloat(s.x)
                buffer.putFloat(s.y)
                if (count == 2) {
                    buffer.putFloat(s.x2)
                    buffer.putFloat(s.y2)
                }
                buffer.putInt(s.action)
                out.write(buffer.array())
                out.flush()
            }
        } catch (_: Exception) {
        }
    }

    // Callback for latency measurement (round-trip ping/pong)
    var onLatencyMeasured: ((Double) -> Unit)? = null

    /**
     * Ask the host to send an IDR/sync frame.
     *
     * Non-forced requests are rate-limited here so all callers share the same
     * backpressure guard. Forced requests are reserved for startup and hard
     * decoder recovery paths where waiting for the throttle would leave the
     * client black or unsynchronized.
     */
    fun requestKeyframe(
        force: Boolean = false,
        reason: String = "client request",
    ) {
        if (!isConnected || !protocolDecided) return
        val now = System.nanoTime()
        val shouldSend =
            synchronized(keyframeRequestLock) {
                if (!force &&
                    lastKeyframeRequestNs > 0L &&
                    now - lastKeyframeRequestNs < KEYFRAME_REQUEST_INTERVAL_NS
                ) {
                    false
                } else {
                    lastKeyframeRequestNs = now
                    true
                }
            }
        if (!shouldSend) return

        val flags = if (force) KEYFRAME_REQUEST_FLAG_FORCE else 0
        diagLog("Requesting keyframe: reason=$reason, force=$force")
        touchScope.launch {
            try {
                outputStream?.let { out ->
                    if (v2Active) {
                        out.write(WireV2.encodeKeyframeRequest(force))
                    } else {
                        out.write(byteArrayOf(MESSAGE_KEYFRAME_REQUEST.toByte(), flags.toByte()))
                    }
                    out.flush()
                }
            } catch (_: Exception) {
            }
        }
    }

    /**
     * Send a ping to measure round-trip latency through the USB connection
     */
    fun sendPing() {
        if (!isConnected || !protocolDecided) return
        touchScope.launch {
            try {
                outputStream?.let { out ->
                    if (v2Active) {
                        out.write(WireV2.encodePing(System.nanoTime()))
                        out.flush()
                        return@let
                    }
                    val buffer = ByteBuffer.allocate(9).order(ByteOrder.LITTLE_ENDIAN)
                    buffer.put(4.toByte()) // Type 4: ping
                    buffer.putLong(System.nanoTime())
                    out.write(buffer.array())
                    out.flush()
                }
            } catch (_: Exception) {
            }
        }
    }

    private fun updateStats(bytes: Int) {
        bytesReceived += bytes
        framesReceived++

        val now = System.currentTimeMillis()
        val elapsed = now - lastStatsTime

        if (elapsed >= 1000) {
            val mbps = (bytesReceived * 8.0) / (elapsed / 1000.0) / 1_000_000
            val fps = (framesReceived * 1000.0) / elapsed
            onStats?.invoke(fps, mbps)
            flushWireStats()

            bytesReceived = 0
            framesReceived = 0
            lastStatsTime = now
        }
    }

    private fun receiveVideoFrame(
        input: DataInputStream,
        hasMetadata: Boolean,
    ) {
        val frameSize = input.readInt()

        // Beyond the hard cap the length field is almost certainly garbage
        // (stream misalignment), so the connection is unrecoverable.
        if (frameSize <= 0 || frameSize > HARD_MAX_FRAME_SIZE) {
            throw IOException("Invalid frame size: $frameSize")
        }

        var isKeyframe = false
        if (hasMetadata) {
            val flags = input.readUnsignedByte()
            input.readLong() // Host capture timestamp; clocks are not comparable with Android.
            isKeyframe = (flags and FRAME_FLAG_KEYFRAME) != 0
        }

        // Between the caps the frame is plausible but too big to buffer or
        // decode: consume it, keep the connection, and ask for a fresh IDR.
        if (frameSize > MAX_FRAME_SIZE) {
            skipFully(input, frameSize)
            diagLog("Skipped oversized frame: $frameSize bytes (keyframe=$isKeyframe)")
            requestKeyframe(force = true, reason = "oversized frame skipped")
            updateStats(frameSize)
            return
        }

        val frameData = framePool.acquire(frameSize)
        input.readFully(frameData, 0, frameSize)

        if (!hasMetadata && !isKeyframe) {
            isKeyframe = isSyncFrame(frameData, frameSize, streamCodecIsHevc)
        }

        // Capture timestamp after full frame received for accurate age tracking.
        val receiveTimestamp = System.nanoTime()
        checkKeyframeFreshness(receiveTimestamp, isKeyframe)
        diagFrameCount++
        if (diagFrameCount == 1L) {
            diagLog(
                "First video frame: size=$frameSize, keyframe=$isKeyframe, " +
                    "metadata=$hasMetadata, callback=${onFrameReceived != null}",
            )
        }
        if (diagFrameCount % 60L == 0L) {
            diagLog("Frames received: $diagFrameCount")
        }

        enqueueFrame(PooledFrame(frameData, frameSize, receiveTimestamp, isKeyframe))
        updateStats(frameSize)
    }

    /**
     * Consume [count] bytes from the stream without buffering them.
     * skipBytes can return early, and skip alone cannot distinguish "no data
     * yet" from EOF — the blocking readByte fallback makes EOF throw.
     */
    private fun skipFully(
        input: DataInputStream,
        count: Int,
    ) {
        var remaining = count
        while (remaining > 0) {
            val skipped = input.skipBytes(remaining)
            if (skipped > 0) {
                remaining -= skipped
            } else {
                input.readByte()
                remaining--
            }
        }
    }

    // ---- protocol v2 receive path ----

    private class PendingV2Frame(
        val buf: ByteArray,
        val csdLen: Int,
        val begin: WireV2.FrameBegin,
        var fill: Int,
    )

    /**
     * v2: every message is [type u8][len u24 BE][payload]. Video arrives as
     * FRAME_BEGIN + n×FRAME_CHUNK, reassembled straight into a pooled buffer
     * (readFully at the fill offset — no intermediate copies). Cached codec
     * parameter sets are prepended into the same buffer before keyframes, and
     * AVCC/HVCC length prefixes are rewritten to start codes in place, so the
     * decoder sees exactly the byte layout v1 produced.
     */
    private fun receiveV2Loop(input: DataInputStream) {
        val envelope = ByteArray(WireV2.ENVELOPE_SIZE)
        val scratch = ByteArray(64)
        var pending: PendingV2Frame? = null

        while (isConnected) {
            input.readFully(envelope)
            val parsed = WireV2.parseEnvelope(envelope) ?: throw IOException("bad v2 envelope")
            val (type, len) = parsed

            when (type) {
                WireV2.MSG_FRAME_BEGIN -> {
                    if (len < WireV2.FRAME_BEGIN_PAYLOAD_SIZE) {
                        skipFully(input, len)
                        continue
                    }
                    input.readFully(scratch, 0, WireV2.FRAME_BEGIN_PAYLOAD_SIZE)
                    if (len > WireV2.FRAME_BEGIN_PAYLOAD_SIZE) {
                        skipFully(input, len - WireV2.FRAME_BEGIN_PAYLOAD_SIZE)
                    }
                    val begin = WireV2.parseFrameBegin(scratch) ?: continue
                    pending?.let { framePool.release(it.buf) }
                    pending = null
                    if (begin.totalSize <= 0 || begin.totalSize > MAX_FRAME_SIZE) {
                        diagLog("v2 frame ${begin.frameId} rejected: ${begin.totalSize} bytes")
                        requestKeyframe(force = true, reason = "oversized v2 frame")
                        continue
                    }
                    val csd = if (begin.isKeyframe && begin.isLengthPrefixed) csdCache else null
                    val csdLen = csd?.size ?: 0
                    val buf = framePool.acquire(csdLen + begin.totalSize)
                    csd?.copyInto(buf)
                    pending = PendingV2Frame(buf, csdLen, begin, 0)
                }

                WireV2.MSG_FRAME_CHUNK -> {
                    if (len < 4) {
                        skipFully(input, len)
                        continue
                    }
                    input.readFully(scratch, 0, 4)
                    val frameId =
                        ((scratch[0].toLong() and 0xFF) shl 24) or
                            ((scratch[1].toLong() and 0xFF) shl 16) or
                            ((scratch[2].toLong() and 0xFF) shl 8) or
                            (scratch[3].toLong() and 0xFF)
                    val body = len - 4
                    val p = pending
                    if (p == null || frameId != p.begin.frameId || p.fill + body > p.begin.totalSize) {
                        skipFully(input, body)
                        if (p != null) {
                            framePool.release(p.buf)
                            pending = null
                            requestKeyframe(force = true, reason = "v2 chunk mismatch")
                        }
                        continue
                    }
                    input.readFully(p.buf, p.csdLen + p.fill, body)
                    p.fill += body
                    if (p.fill == p.begin.totalSize) {
                        pending = null
                        finishV2Frame(p)
                    }
                }

                WireV2.MSG_PONG -> {
                    if (len < WireV2.PONG_PAYLOAD_SIZE) {
                        skipFully(input, len)
                        continue
                    }
                    input.readFully(scratch, 0, WireV2.PONG_PAYLOAD_SIZE)
                    if (len > WireV2.PONG_PAYLOAD_SIZE) skipFully(input, len - WireV2.PONG_PAYLOAD_SIZE)
                    val pong = WireV2.parsePong(scratch) ?: continue
                    val rttNs = clockSync.onPong(pong.t0, pong.t1, pong.t2, System.nanoTime())
                    lastRttMs = rttNs / 1_000_000.0
                    onLatencyMeasured?.invoke(lastRttMs)
                }

                WireV2.MSG_DISPLAY_CONFIG -> {
                    if (len < 12) {
                        skipFully(input, len)
                        continue
                    }
                    input.readFully(scratch, 0, 12)
                    if (len > 12) skipFully(input, len - 12)
                    val buf = ByteBuffer.wrap(scratch, 0, 12)
                    val width = buf.int
                    val height = buf.int
                    val transform = buf.int
                    val rotation = transform % 1000
                    val flags = transform / 1000
                    diagLog("v2 display config: ${width}x$height @ $rotation°")
                    onDisplaySize?.invoke(width, height, rotation, flags and 1 == 1, flags and 2 == 2)
                }

                WireV2.MSG_VIDEO_CONFIG -> {
                    if (len < 2 || len > 65536) {
                        skipFully(input, len)
                        continue
                    }
                    val payload = ByteArray(len)
                    input.readFully(payload)
                    val codecId = payload[0].toInt() and 0xFF
                    val isHevc = codecId == 0
                    val changed = isHevc != streamCodecIsHevc || !codecNegotiated
                    streamCodecIsHevc = isHevc
                    codecNegotiated = true
                    if (len > 2) {
                        csdCache = payload.copyOfRange(2, len)
                        diagLog("v2 videoConfig: ${if (isHevc) "HEVC" else "H.264"}, csd ${len - 2}B")
                    } else {
                        diagLog("v2 codec announcement: ${if (isHevc) "HEVC" else "H.264"}")
                    }
                    if (changed) {
                        onCodecSelected?.invoke(isHevc)
                    }
                }

                else -> skipFully(input, len)
            }
        }
    }

    private fun finishV2Frame(p: PendingV2Frame) {
        val totalLen = p.csdLen + p.begin.totalSize
        if (p.begin.isLengthPrefixed &&
            !WireV2.rewriteLengthPrefixesToStartCodes(p.buf, p.csdLen, p.begin.totalSize)
        ) {
            diagLog("v2 frame ${p.begin.frameId}: corrupt NAL length prefixes")
            framePool.release(p.buf)
            requestKeyframe(force = true, reason = "corrupt v2 frame")
            return
        }
        val receiveTimestamp = System.nanoTime()
        recordWireAge(receiveTimestamp, p.begin.captureNs)
        // Open GOP means a single corrupted frame would otherwise persist on
        // screen forever — a gentle 10s IDR refresh self-heals at 1% of the
        // old 1s-GOP burst cost.
        if (p.begin.isKeyframe) {
            lastKeyframeReceivedNs = receiveTimestamp
        } else if (lastKeyframeReceivedNs > 0L &&
            receiveTimestamp - lastKeyframeReceivedNs > V2_REFRESH_KEYFRAME_NS &&
            receiveTimestamp - lastSelfHealRequestNs > V2_REFRESH_RETRY_NS
        ) {
            lastSelfHealRequestNs = receiveTimestamp
            requestKeyframe(reason = "periodic refresh (open GOP self-heal)")
        }
        enqueueFrame(PooledFrame(p.buf, totalLen, receiveTimestamp, p.begin.isKeyframe))
        updateStats(totalLen)
    }

    /** Wire age = (client now mapped to host clock) - host capture time. */
    private fun recordWireAge(
        clientNowNs: Long,
        hostCaptureNs: Long,
    ) {
        if (!clockSync.isValid) return
        val ageMs = (clientNowNs + clockSync.offsetNs - hostCaptureNs) / 1_000_000.0
        if (ageMs < 0 || ageMs > 10_000) return
        synchronized(wireAgesMs) {
            wireAgesMs.add(ageMs)
        }
    }

    private fun flushWireStats() {
        val callback = onWireStats ?: return
        if (!clockSync.isValid) return
        val snapshot: List<Double>
        synchronized(wireAgesMs) {
            if (wireAgesMs.isEmpty()) return
            snapshot = ArrayList(wireAgesMs)
            wireAgesMs.clear()
        }
        val sorted = snapshot.sorted()
        val p50 = sorted[sorted.size / 2]
        val p95 = sorted[minOf(sorted.size - 1, sorted.size * 95 / 100)]
        callback(lastRttMs, clockSync.offsetNs / 1_000_000.0, p50, p95)
    }

    private fun checkKeyframeFreshness(
        receiveTimestamp: Long,
        isKeyframe: Boolean,
    ) {
        if (isKeyframe) {
            lastKeyframeReceivedNs = receiveTimestamp
            return
        }

        val lastKeyframeNs = lastKeyframeReceivedNs
        if (lastKeyframeNs <= 0L) return

        val keyframeAgeNs = receiveTimestamp - lastKeyframeNs
        if (keyframeAgeNs > KEYFRAME_STALE_INTERVAL_NS) {
            requestKeyframe(
                reason = "last keyframe ${keyframeAgeNs / 1_000_000L}ms ago",
            )
        }
    }

    fun disconnect() {
        isConnected = false
        cleanup()
        onConnectionStatus?.invoke(false)
        Log.d(TAG, "Disconnected")
    }

    private fun cleanup() {
        stopFramePump()
        try {
            outputStream?.close()
            inputStream?.close()
            transport?.close()
            socket?.close()

            // Properly shutdown executor with timeout to prevent orphaned threads
            touchExecutor.shutdown()
            try {
                if (!touchExecutor.awaitTermination(500, TimeUnit.MILLISECONDS)) {
                    touchExecutor.shutdownNow()
                    // Wait a bit more for forced shutdown
                    touchExecutor.awaitTermination(200, TimeUnit.MILLISECONDS)
                }
            } catch (e: InterruptedException) {
                touchExecutor.shutdownNow()
                Thread.currentThread().interrupt()
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error during cleanup", e)
        }
        outputStream = null
        inputStream = null
        socket = null
    }

    private fun diagLog(msg: String) = DiagLog.log("SC", msg)

    companion object {
        private const val TAG = "StreamClient"

        // Soft cap: plausible frame that is too big to buffer/decode — it is
        // skipped in-stream and an IDR is requested; the connection survives.
        // Matches FramePool's largest class and the decoder's max input size.
        private const val MAX_FRAME_SIZE = 16 * 1024 * 1024

        // Hard cap: treated as stream misalignment — the connection dies.
        private const val HARD_MAX_FRAME_SIZE = 64 * 1024 * 1024
        private const val FRAME_QUEUE_CAPACITY = 3
        private const val QUEUE_BLOCK_MAX_NS = 250_000_000L
        private const val USB_SOCKET_RECEIVE_BUFFER = 1 * 1024 * 1024
        private const val WIRELESS_SOCKET_RECEIVE_BUFFER = 4 * 1024 * 1024
        private const val PAIRING_READ_TIMEOUT_MS = 10_000

        // Wire action codes are app-defined (see MainActivity.handleTouch):
        // 0 = down, 1 = move, 2 = up. NOT MotionEvent constants.
        private const val WIRE_ACTION_MOVE = 1
        private const val AOA_PREAMBLE_LENGTH = 13
        private const val AOA_PREAMBLE_VERSION = 1

        // Must exceed the Mac's claim/preamble retry cycle (~12s): its SSAC
        // write NAKs until we read, so holding the descriptor open guarantees
        // catching the next cycle instead of racing it.
        private const val AOA_PREAMBLE_TIMEOUT_MS = 25_000L
        private const val KEYFRAME_REQUEST_INTERVAL_NS = 500_000_000L
        private const val KEYFRAME_STALE_INTERVAL_NS = 1_500_000_000L
        private const val V2_REFRESH_KEYFRAME_NS = 10_000_000_000L
        private const val V2_REFRESH_RETRY_NS = 5_000_000_000L
        private const val MESSAGE_VIDEO_FRAME = 0
        private const val MESSAGE_VIDEO_FRAME_WITH_METADATA = 6
        private const val MESSAGE_KEYFRAME_REQUEST = 7
        private const val MESSAGE_CLIENT_SUPPORTS_FRAME_METADATA = 8
        private const val MESSAGE_CLIENT_AVC_ONLY = 9
        private const val MESSAGE_CODEC_SELECTED = 10
        private const val MESSAGE_CLIENT_DECODER_LIMITS = 11
        private const val FRAME_FLAG_KEYFRAME = 1
        private const val KEYFRAME_REQUEST_FLAG_FORCE = 1

        /**
         * Codec-aware sync-frame (keyframe) detection on the legacy
         * MESSAGE_VIDEO_FRAME path. HEVC: IRAP NAL types 16..21 from
         * (header and 0x7E) shr 1. H.264: IDR slice, (header and 0x1F) == 5.
         * Internal (not private) so unit tests can exercise both branches.
         */
        internal fun isSyncFrame(
            data: ByteArray,
            size: Int,
            isHevc: Boolean,
        ): Boolean {
            var i = 0
            while (i + 5 < size) {
                var start = -1
                var startCodeLength = 0

                while (i + 3 < size) {
                    if (data[i] == 0.toByte() && data[i + 1] == 0.toByte()) {
                        if (data[i + 2] == 1.toByte()) {
                            start = i
                            startCodeLength = 3
                            break
                        }
                        if (i + 3 < size && data[i + 2] == 0.toByte() && data[i + 3] == 1.toByte()) {
                            start = i
                            startCodeLength = 4
                            break
                        }
                    }
                    i++
                }

                if (start < 0) return false

                val nalStart = start + startCodeLength
                if (nalStart + 1 >= size) return false

                val header = data[nalStart].toInt()
                val isSync =
                    if (isHevc) {
                        ((header and 0x7E) shr 1) in 16..21
                    } else {
                        (header and 0x1F) == 5
                    }
                if (isSync) {
                    return true
                }

                i = nalStart + 2
            }
            return false
        }
    }
}
