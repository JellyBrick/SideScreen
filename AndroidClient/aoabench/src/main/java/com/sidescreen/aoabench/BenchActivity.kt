package com.sidescreen.aoabench

import android.annotation.SuppressLint
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbAccessory
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Bundle
import android.os.ParcelFileDescriptor
import android.widget.Button
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

/**
 * AOA PoC bench receiver (plan Phase 0). Counterpart of MacHost/AOATest:
 * consumes "SSAB" blocks (verifying the 64-bit word-sum checksum), answers
 * ping blocks with "SSAP" pongs immediately, and reports "SSAA" ACKs at 1 Hz.
 * The wire format lives in MacHost/AOATest/Sources/AOAConstants.swift.
 */
class BenchActivity : AppCompatActivity() {
    private lateinit var statsText: TextView
    private var pfd: ParcelFileDescriptor? = null
    private var socket: Socket? = null
    private var readerThread: Thread? = null
    private var ackThread: Thread? = null
    private val running = AtomicBoolean(false)

    private val totalBytes = AtomicLong(0)
    private val windowBytes = AtomicLong(0)
    private val lastSeq = AtomicLong(0)
    private val checksumErrors = AtomicInteger(0)
    private val resyncErrors = AtomicInteger(0)
    private var sessionLabel = "idle"

    private val usbPermissionReceiver =
        object : BroadcastReceiver() {
            override fun onReceive(
                context: Context,
                intent: Intent,
            ) {
                if (intent.action != ACTION_USB_PERMISSION) return
                val accessory: UsbAccessory? = intent.getParcelableExtra(UsbManager.EXTRA_ACCESSORY)
                val granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
                if (granted && accessory != null) {
                    openAccessory(accessory)
                } else {
                    log("USB permission denied")
                }
            }
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_bench)
        statsText = findViewById(R.id.statsText)
        findViewById<Button>(R.id.accessoryButton).setOnClickListener { tryOpenAccessory() }
        findViewById<Button>(R.id.tcpButton).setOnClickListener { startTcpBaseline() }
        findViewById<Button>(R.id.stopButton).setOnClickListener { stopSession() }
        window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        ContextCompat.registerReceiver(
            this,
            usbPermissionReceiver,
            IntentFilter(ACTION_USB_PERMISSION),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )

        handleIntent(intent)
        statsUpdateLoop()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    override fun onDestroy() {
        super.onDestroy()
        stopSession()
        unregisterReceiver(usbPermissionReceiver)
    }

    private fun handleIntent(intent: Intent?) {
        if (intent?.action == UsbManager.ACTION_USB_ACCESSORY_ATTACHED) {
            val accessory: UsbAccessory? = intent.getParcelableExtra(UsbManager.EXTRA_ACCESSORY)
            if (accessory != null) {
                // Delivered via the system dialog: permission is implicit.
                openAccessory(accessory)
            }
        }
    }

    private fun tryOpenAccessory() {
        val usbManager = getSystemService(Context.USB_SERVICE) as UsbManager
        val accessory = usbManager.accessoryList?.firstOrNull()
        if (accessory == null) {
            log("No accessory present. Run `AOATest switch` on the Mac first.")
            return
        }
        if (usbManager.hasPermission(accessory)) {
            openAccessory(accessory)
            return
        }
        val flags =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                // Must be MUTABLE: the system appends the accessory + grant
                // result extras when it fires this intent back at us.
                PendingIntent.FLAG_MUTABLE
            } else {
                0
            }
        val pi =
            PendingIntent.getBroadcast(
                this,
                0,
                Intent(ACTION_USB_PERMISSION).setPackage(packageName),
                flags,
            )
        log("Requesting USB permission…")
        usbManager.requestPermission(accessory, pi)
    }

    private fun openAccessory(accessory: UsbAccessory) {
        stopSession()
        val usbManager = getSystemService(Context.USB_SERVICE) as UsbManager
        val descriptor = usbManager.openAccessory(accessory)
        if (descriptor == null) {
            log("openAccessory failed (already open elsewhere?)")
            return
        }
        pfd = descriptor
        sessionLabel = "AOA ${accessory.manufacturer}/${accessory.model}"
        log("Accessory opened: $sessionLabel")
        startSession(
            FileInputStream(descriptor.fileDescriptor),
            FileOutputStream(descriptor.fileDescriptor),
        )
    }

    private fun startTcpBaseline() {
        stopSession()
        sessionLabel = "TCP 127.0.0.1:$TCP_PORT (adb reverse)"
        Thread({
            try {
                val s = Socket()
                s.tcpNoDelay = true
                s.receiveBufferSize = 1 shl 20
                s.connect(InetSocketAddress("127.0.0.1", TCP_PORT), 3000)
                socket = s
                log("TCP connected")
                startSession(s.getInputStream(), s.getOutputStream())
            } catch (e: Exception) {
                log("TCP connect failed: ${e.message} — is `adb reverse tcp:$TCP_PORT tcp:$TCP_PORT` set?")
            }
        }, "TcpConnect").start()
    }

    private fun startSession(
        input: InputStream,
        output: OutputStream,
    ) {
        running.set(true)
        totalBytes.set(0)
        windowBytes.set(0)
        lastSeq.set(0)
        checksumErrors.set(0)
        resyncErrors.set(0)
        val outputLock = Object()

        readerThread =
            Thread({ readerLoop(input, output, outputLock) }, "BenchReader").apply {
                priority = Thread.MAX_PRIORITY
                start()
            }
        ackThread =
            Thread({ ackLoop(output, outputLock) }, "BenchAck").apply { start() }
    }

    private fun stopSession() {
        running.set(false)
        try {
            pfd?.close()
        } catch (_: Exception) {
        }
        try {
            socket?.close()
        } catch (_: Exception) {
        }
        pfd = null
        socket = null
        readerThread?.interrupt()
        ackThread?.interrupt()
        readerThread = null
        ackThread = null
    }

    /**
     * Stream parser. AOA rule: EVERY kernel read must use a buffer of at
     * least 16384 bytes — f_accessory discards the remainder of a URB when
     * the userspace buffer is smaller than the completed transfer.
     */
    private fun readerLoop(
        input: InputStream,
        output: OutputStream,
        outputLock: Object,
    ) {
        val readBuf = ByteArray(16384)
        val header = ByteArray(BLOCK_HEADER_SIZE)
        var headerFill = 0
        var payload = ByteArray(512 * 1024)
        var payloadFill = 0
        var payloadLen = 0
        var inPayload = false
        var seq = 0L
        var flags = 0
        var wantedChecksum = 0L
        var sendNs = 0L

        try {
            while (running.get()) {
                val n = input.read(readBuf, 0, readBuf.size)
                if (n <= 0) break
                totalBytes.addAndGet(n.toLong())
                windowBytes.addAndGet(n.toLong())

                var off = 0
                while (off < n) {
                    if (!inPayload) {
                        val take = minOf(BLOCK_HEADER_SIZE - headerFill, n - off)
                        System.arraycopy(readBuf, off, header, headerFill, take)
                        headerFill += take
                        off += take
                        if (headerFill < BLOCK_HEADER_SIZE) continue

                        val buf = ByteBuffer.wrap(header).order(ByteOrder.LITTLE_ENDIAN)
                        val magic = buf.int
                        if (magic != BLOCK_MAGIC) {
                            // Resync: slide the header window by one byte.
                            resyncErrors.incrementAndGet()
                            System.arraycopy(header, 1, header, 0, BLOCK_HEADER_SIZE - 1)
                            headerFill = BLOCK_HEADER_SIZE - 1
                            continue
                        }
                        seq = buf.long
                        payloadLen = buf.int
                        flags = buf.int
                        wantedChecksum = buf.long
                        sendNs = buf.long
                        headerFill = 0
                        if (payloadLen < 0 || payloadLen > 8 * 1024 * 1024) {
                            resyncErrors.incrementAndGet()
                            continue
                        }
                        if (payload.size < payloadLen) payload = ByteArray(payloadLen)
                        payloadFill = 0
                        inPayload = true
                    } else {
                        val take = minOf(payloadLen - payloadFill, n - off)
                        System.arraycopy(readBuf, off, payload, payloadFill, take)
                        payloadFill += take
                        off += take
                        if (payloadFill < payloadLen) continue

                        inPayload = false
                        lastSeq.set(seq)
                        if (flags and FLAG_NO_VERIFY == 0) {
                            if (checksum64(payload, payloadLen) != wantedChecksum) {
                                checksumErrors.incrementAndGet()
                            }
                        }
                        if (flags and FLAG_PING != 0) {
                            val pong = ByteBuffer.allocate(PONG_SIZE).order(ByteOrder.LITTLE_ENDIAN)
                            pong.putInt(PONG_MAGIC)
                            pong.putLong(seq)
                            pong.putLong(sendNs)
                            synchronized(outputLock) {
                                output.write(pong.array())
                                output.flush()
                            }
                        }
                    }
                }
            }
        } catch (e: Exception) {
            if (running.get()) log("Reader stopped: ${e.message}")
        }
    }

    private fun ackLoop(
        output: OutputStream,
        outputLock: Object,
    ) {
        try {
            while (running.get()) {
                Thread.sleep(1000)
                val ack = ByteBuffer.allocate(ACK_SIZE).order(ByteOrder.LITTLE_ENDIAN)
                ack.putInt(ACK_MAGIC)
                ack.putLong(lastSeq.get())
                ack.putLong(totalBytes.get())
                ack.putInt(checksumErrors.get())
                synchronized(outputLock) {
                    output.write(ack.array())
                    output.flush()
                }
            }
        } catch (_: Exception) {
        }
    }

    /** Mirrors BenchWire.checksum on the Mac: wrapping sum of u64 words. */
    private fun checksum64(
        data: ByteArray,
        length: Int,
    ): Long {
        val buf = ByteBuffer.wrap(data, 0, length).order(ByteOrder.LITTLE_ENDIAN)
        var sum = 0L
        val words = length / 8
        for (i in 0 until words) {
            sum += buf.getLong(i * 8)
        }
        for (i in words * 8 until length) {
            sum += (data[i].toLong() and 0xFF)
        }
        return sum
    }

    @SuppressLint("SetTextI18n")
    private fun statsUpdateLoop() {
        statsText.postDelayed(
            {
                val bytes = windowBytes.getAndSet(0)
                val mbps = bytes * 8.0 / 1_000_000.0
                if (running.get()) {
                    statsText.text =
                        "session: $sessionLabel\n" +
                        String.format("throughput: %.1f Mbps\n", mbps) +
                        String.format("total: %.1f MB\n", totalBytes.get() / 1e6) +
                        "last seq: ${lastSeq.get()}\n" +
                        "checksum errors: ${checksumErrors.get()}\n" +
                        "resync errors: ${resyncErrors.get()}"
                }
                statsUpdateLoop()
            },
            1000,
        )
    }

    private fun log(message: String) {
        runOnUiThread { statsText.text = message }
    }

    companion object {
        private const val ACTION_USB_PERMISSION = "com.sidescreen.aoabench.USB_PERMISSION"
        private const val TCP_PORT = 54399

        // Wire constants — see MacHost/AOATest/Sources/AOAConstants.swift.
        private const val BLOCK_MAGIC = 0x42415353 // "SSAB" LE
        private const val ACK_MAGIC = 0x41415353 // "SSAA"
        private const val PONG_MAGIC = 0x50415353 // "SSAP"
        private const val BLOCK_HEADER_SIZE = 36
        private const val ACK_SIZE = 24
        private const val PONG_SIZE = 20
        private const val FLAG_PING = 1
        private const val FLAG_NO_VERIFY = 2
    }
}
