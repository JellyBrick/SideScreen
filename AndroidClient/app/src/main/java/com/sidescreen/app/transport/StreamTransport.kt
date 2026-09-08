package com.sidescreen.app.transport

import java.io.Closeable
import java.io.InputStream
import java.io.OutputStream

enum class TransportKind {
    TCP_USB, // adb reverse loopback
    TCP_WIRELESS, // LAN, token-authenticated
    AOA, // USB accessory bulk pipe
}

/**
 * A reliable bidirectional byte stream carrying the streaming protocol.
 * The protocol layer (StreamClient) reads and writes streams only; how the
 * bytes reach the Mac — TCP socket or AOA accessory file descriptor — is the
 * transport's business.
 */
interface StreamTransport : Closeable {
    val input: InputStream
    val output: OutputStream
    val kind: TransportKind

    /** For logs and status UI, e.g. "127.0.0.1:54321 via adb". */
    val descriptor: String
}
