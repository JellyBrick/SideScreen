package com.sidescreen.app.transport

import java.io.InputStream
import java.io.OutputStream
import java.net.Socket

class TcpTransport(
    private val socket: Socket,
    override val kind: TransportKind,
) : StreamTransport {
    override val input: InputStream get() = socket.getInputStream()
    override val output: OutputStream get() = socket.getOutputStream()

    override val descriptor: String
        get() {
            val via = if (kind == TransportKind.TCP_USB) " via adb" else ""
            return "${socket.inetAddress?.hostAddress}:${socket.port}$via"
        }

    override fun close() {
        socket.close()
    }
}
