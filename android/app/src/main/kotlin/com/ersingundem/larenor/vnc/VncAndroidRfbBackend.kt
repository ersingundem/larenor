package com.ersingundem.larenor.vnc

import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import java.util.Base64
import java.util.concurrent.atomic.AtomicBoolean
import javax.crypto.Cipher
import javax.crypto.spec.SecretKeySpec
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocket
import javax.net.ssl.X509TrustManager

/** Production RFB 3.8 + VeNCrypt 0.2/X509Vnc backend used by the packaged APK. */
internal class VncAndroidRfbBackend(
    private val publish: (Long, Int, Int, ByteArray) -> Boolean,
    private val disconnected: () -> Unit,
) : VncNativeBackend, VncNativeCertificateInspector {
    override fun capabilities() = VncNativeCapabilities.parse(mapOf(
        "schemaVersion" to 1,
        "availability" to "available",
        "engineRevision" to ENGINE_REVISION,
        "rfbVersions" to listOf("3.8"),
        "securityTypes" to listOf("vencryptTlsVncAuth"),
        "transport" to mapOf("tls" to true, "spkiPinning" to true),
        "auth" to mapOf("password" to true),
        "framebuffer" to mapOf(
            "encodings" to listOf("raw"), "trueColor32" to true,
            "dynamicResolution" to true, "externalDisplay" to true,
            "maxWidth" to MAX_DIMENSION, "maxHeight" to MAX_DIMENSION, "maxDpi" to 640,
        ),
        "input" to mapOf("pointer" to true, "keyboard" to true, "clipboard" to false),
    ))

    override fun inspect(host: String, port: Int): String {
        val transport = Connection.connect(host, port)
        try {
            transport.negotiateVencrypt()
            transport.upgradeTls(expectedPin = null)
            return transport.peerPin()
        } finally {
            transport.close()
        }
    }

    override fun open(
        request: VncNativeRequest,
        plan: VncNativePlan,
        secrets: VncNativeSecrets,
    ): VncNativeSession {
        if (plan.engineRevision != ENGINE_REVISION || plan.framebufferEncoding != VncFramebufferEncoding.RAW) {
            throw VncNativeFailure("staleSession")
        }
        val password = CharArray(4096)
        var passwordLength = 0
        secrets.use { value ->
            passwordLength = value.size
            value.copyInto(password)
        }
        val connection = Connection.connect(request.directTargetHost, request.directTargetPort)
        try {
            connection.negotiateVencrypt()
            connection.upgradeTls(request.directSpkiFingerprint)
            connection.authenticate(password, passwordLength)
            val desktop = connection.initialize()
            if (desktop.first.toLong() * desktop.second * 4 > MAX_FRAME_BYTES) {
                throw VncNativeFailure("framebufferUnavailable")
            }
            return Session(connection, desktop.first, desktop.second, publish, disconnected)
        } catch (failure: VncNativeFailure) {
            connection.close()
            throw failure
        } catch (_: Exception) {
            connection.close()
            throw VncNativeFailure("connectionFailed")
        } finally {
            password.fill('\u0000')
        }
    }

    private class Session(
        private val connection: Connection,
        private var width: Int,
        private var height: Int,
        private val publish: (Long, Int, Int, ByteArray) -> Boolean,
        private val disconnected: () -> Unit,
    ) : VncNativeInputSession, VncNativeFrameSession, VncNativeDeferredStartSession {
        private val closed = AtomicBoolean(false)
        private val lock = Any()
        private var sequence = 0L
        private var waitingForAck = false
        private var framebuffer = ByteArray(width * height * 4)
        private lateinit var reader: Thread

        override fun start() {
            connection.configureFramebuffer(width, height)
            reader = Thread({ readLoop() }, "larenor-vnc-rfb").apply {
                isDaemon = true
                start()
            }
        }

        private fun readLoop() {
            try {
                while (!closed.get()) {
                    when (connection.readUnsignedByte()) {
                        0 -> readFramebufferUpdate()
                        2 -> Unit // Bell.
                        3 -> connection.skipServerCutText()
                        else -> throw VncNativeFailure("connectionFailed")
                    }
                }
            } catch (_: Exception) {
                close()
                disconnected()
            }
        }

        private fun readFramebufferUpdate() {
            connection.readUnsignedByte() // padding
            val rectangles = connection.readUnsignedShort()
            if (rectangles !in 1..256) throw VncNativeFailure("framebufferUnavailable")
            repeat(rectangles) {
                val x = connection.readUnsignedShort()
                val y = connection.readUnsignedShort()
                val rectangleWidth = connection.readUnsignedShort()
                val rectangleHeight = connection.readUnsignedShort()
                val encoding = connection.readInt()
                if (encoding == DESKTOP_SIZE_ENCODING) {
                    connection.skipExtendedDesktopSize()
                    resizeFramebuffer(rectangleWidth, rectangleHeight)
                    return@repeat
                }
                if (encoding != RAW_ENCODING || rectangleWidth == 0 || rectangleHeight == 0 ||
                    x + rectangleWidth > width || y + rectangleHeight > height ||
                    rectangleWidth.toLong() * rectangleHeight * 4 > MAX_FRAME_BYTES
                ) throw VncNativeFailure("framebufferUnavailable")
                val row = ByteArray(rectangleWidth * 4)
                try {
                    repeat(rectangleHeight) { rowIndex ->
                        connection.readFully(row)
                        var source = 0
                        var target = ((y + rowIndex) * width + x) * 4
                        repeat(rectangleWidth) {
                            framebuffer[target] = row[source]
                            framebuffer[target + 1] = row[source + 1]
                            framebuffer[target + 2] = row[source + 2]
                            framebuffer[target + 3] = 0xff.toByte()
                            source += 4
                            target += 4
                        }
                    }
                } finally {
                    row.fill(0)
                }
            }
            val pixels: ByteArray
            val next: Long
            synchronized(lock) {
                if (waitingForAck || closed.get()) throw VncNativeFailure("staleSession")
                waitingForAck = true
                next = ++sequence
                pixels = framebuffer.copyOf()
            }
            if (!publish(next, width, height, pixels)) {
                pixels.fill(0)
                throw VncNativeFailure("staleSession")
            }
        }

        private fun resizeFramebuffer(nextWidth: Int, nextHeight: Int) {
            if (nextWidth !in 1..MAX_DIMENSION || nextHeight !in 1..MAX_DIMENSION ||
                nextWidth.toLong() * nextHeight * 4 > MAX_FRAME_BYTES
            ) throw VncNativeFailure("framebufferUnavailable")
            framebuffer.fill(0)
            width = nextWidth
            height = nextHeight
            framebuffer = ByteArray(width * height * 4)
        }

        override fun acknowledgeFrame(sequence: Long): Boolean = synchronized(lock) {
            if (closed.get() || !waitingForAck || sequence != this.sequence) return@synchronized false
            waitingForAck = false
            connection.requestFramebuffer(width, height, incremental = true)
            true
        }

        override fun resize(width: Int, height: Int): Boolean = synchronized(lock) {
            if (closed.get() || waitingForAck || width !in 640..MAX_DIMENSION ||
                height !in 480..MAX_DIMENSION || width.toLong() * height * 4 > MAX_FRAME_BYTES
            ) return@synchronized false
            connection.setDesktopSize(width, height)
            true
        }

        override fun input(sequence: Long, event: Map<String, Any>): Boolean = synchronized(lock) {
            if (closed.get()) return@synchronized false
            when (event["kind"]) {
                "pointer" -> connection.pointer(
                    ((event["x"] as Double) * (width - 1)).toInt(),
                    ((event["y"] as Double) * (height - 1)).toInt(),
                    event["buttons"] as Int,
                )
                "key" -> connection.key(hidKeysym(event["code"] as Int), event["down"] as Boolean)
                "text" -> connection.text(event["text"] as String)
                else -> return@synchronized false
            }
            true
        }

        override fun close() {
            if (!closed.compareAndSet(false, true)) return
            framebuffer.fill(0)
            connection.close()
        }

        private fun hidKeysym(code: Int): Int = when (code) {
            in 0x04..0x1d -> 'a'.code + code - 0x04
            in 0x1e..0x26 -> '1'.code + code - 0x1e
            0x27 -> '0'.code
            0x28 -> 0xff0d
            0x29 -> 0xff1b
            0x2a -> 0xff08
            0x2b -> 0xff09
            0x2c -> 0x20
            0x4f -> 0xff53
            0x50 -> 0xff51
            0x51 -> 0xff54
            0x52 -> 0xff52
            0xe0 -> 0xffe3
            0xe1 -> 0xffe1
            0xe2 -> 0xffe9
            0xe3 -> 0xffeb
            0xe4 -> 0xffe4
            0xe5 -> 0xffe2
            0xe6 -> 0xffea
            0xe7 -> 0xffec
            else -> code
        }
    }

    private class Connection private constructor(
        private var socket: Socket,
        private var input: DataInputStream,
        private var output: DataOutputStream,
        private val host: String,
        private val port: Int,
    ) : AutoCloseable {
        private var ssl: SSLSocket? = null
        private var spkiDigest: ByteArray? = null

        fun negotiateVencrypt() {
            if (!readBytes(12).contentEquals(VERSION)) throw VncNativeFailure("rfbVersionUnavailable")
            write(VERSION)
            val count = readUnsignedByte()
            if (count !in 1..32) throw VncNativeFailure("authUnavailable")
            val types = readBytes(count)
            if (VENCRYPT !in types.map { it.toInt() and 0xff }) throw VncNativeFailure("authUnavailable")
            write(byteArrayOf(VENCRYPT.toByte()))
            if (!readBytes(2).contentEquals(VENCRYPT_VERSION)) throw VncNativeFailure("authUnavailable")
            write(VENCRYPT_VERSION)
            if (readUnsignedByte() != 0) throw VncNativeFailure("authUnavailable")
            val subtypeCount = readUnsignedByte()
            if (subtypeCount !in 1..16) throw VncNativeFailure("authUnavailable")
            var supported = false
            repeat(subtypeCount) { if (readInt().toLong() and 0xffffffffL == X509_VNC) supported = true }
            if (!supported) throw VncNativeFailure("authUnavailable")
            writeInt(X509_VNC.toInt())
        }

        fun upgradeTls(expectedPin: String?) {
            val secured = try {
                (discoveryTlsContext.socketFactory
                    .createSocket(socket, host, port, true) as SSLSocket).apply {
                    enabledProtocols = arrayOf("TLSv1.3")
                    soTimeout = IO_TIMEOUT_MILLIS
                    startHandshake()
                }
            } catch (_: Exception) {
                throw VncNativeFailure("tlsRequired")
            }
            ssl = secured
            socket = secured
            input = DataInputStream(BufferedInputStream(secured.inputStream))
            output = DataOutputStream(BufferedOutputStream(secured.outputStream))
            val spki = secured.session.peerCertificates.firstOrNull()?.publicKey?.encoded
                ?: throw VncNativeFailure("tlsRequired")
            val digest = MessageDigest.getInstance("SHA-256").digest(spki)
            spki.fill(0)
            spkiDigest = digest
            if (expectedPin != null) {
                val expected = decodePin(expectedPin)
                try {
                    if (!MessageDigest.isEqual(expected, digest)) throw VncNativeFailure("spkiPinningRequired")
                } finally {
                    expected.fill(0)
                }
            }
        }

        fun peerPin(): String {
            val digest = spkiDigest ?: throw VncNativeFailure("tlsRequired")
            return "SHA256:${Base64.getEncoder().withoutPadding().encodeToString(digest)}"
        }

        fun authenticate(password: CharArray, length: Int) {
            val challenge = readBytes(16)
            val key = ByteArray(8)
            try {
                for (index in 0 until minOf(8, length)) {
                    val code = password[index].code
                    if (code > 0xff) throw VncNativeFailure("invalidSecrets")
                    key[index] = reverseBits(code.toByte())
                }
                val cipher = Cipher.getInstance("DES/ECB/NoPadding")
                cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "DES"))
                val response = cipher.doFinal(challenge)
                try { write(response) } finally { response.fill(0) }
            } finally {
                challenge.fill(0)
                key.fill(0)
            }
            if (readInt() != 0) throw VncNativeFailure("authUnavailable")
        }

        fun initialize(): Pair<Int, Int> {
            write(byteArrayOf(1))
            val width = readUnsignedShort()
            val height = readUnsignedShort()
            if (width !in 1..MAX_DIMENSION || height !in 1..MAX_DIMENSION) {
                throw VncNativeFailure("framebufferUnavailable")
            }
            val pixelFormat = readBytes(16)
            val valid = pixelFormat[0].toInt() and 0xff == 32 &&
                pixelFormat[1].toInt() and 0xff == 24 && pixelFormat[2] == 0.toByte() &&
                pixelFormat[3] == 1.toByte()
            pixelFormat.fill(0)
            if (!valid) throw VncNativeFailure("framebufferUnavailable")
            val nameLength = readInt().toLong() and 0xffffffffL
            if (nameLength > 4096) throw VncNativeFailure("connectionFailed")
            val name = readBytes(nameLength.toInt())
            name.fill(0)
            return width to height
        }

        fun configureFramebuffer(width: Int, height: Int) {
            write(byteArrayOf(
                0, 0, 0, 0, 32, 24, 0, 1,
                0, 0xff.toByte(), 0, 0xff.toByte(), 0, 0xff.toByte(), 0, 8, 16, 0, 0, 0,
            ))
            // Raw plus DesktopSize pseudo-encoding.
            write(byteArrayOf(2, 0, 0, 2, 0, 0, 0, 0, 0xff.toByte(), 0xff.toByte(), 0xfe.toByte(), 0xcc.toByte()))
            requestFramebuffer(width, height, incremental = false)
        }

        fun requestFramebuffer(width: Int, height: Int, incremental: Boolean) = write(byteArrayOf(
            3, if (incremental) 1 else 0, 0, 0, 0, 0,
            (width ushr 8).toByte(), width.toByte(), (height ushr 8).toByte(), height.toByte(),
        ))

        fun setDesktopSize(width: Int, height: Int) = write(byteArrayOf(
            251.toByte(), 0, (width ushr 8).toByte(), width.toByte(),
            (height ushr 8).toByte(), height.toByte(), 1, 0,
            0, 0, 0, 0, 0, 0, 0, 0,
            (width ushr 8).toByte(), width.toByte(), (height ushr 8).toByte(), height.toByte(),
            0, 0, 0, 0,
        ))

        fun skipExtendedDesktopSize() {
            val count = readUnsignedByte()
            readBytes(3).fill(0)
            if (count !in 1..16) throw VncNativeFailure("framebufferUnavailable")
            readBytes(count * 16).fill(0)
        }

        fun pointer(x: Int, y: Int, buttons: Int) = write(byteArrayOf(
            5, buttons.toByte(), (x ushr 8).toByte(), x.toByte(), (y ushr 8).toByte(), y.toByte(),
        ))

        fun key(keysym: Int, down: Boolean) = write(byteArrayOf(
            4, if (down) 1 else 0, 0, 0,
            (keysym ushr 24).toByte(), (keysym ushr 16).toByte(), (keysym ushr 8).toByte(), keysym.toByte(),
        ))

        fun text(value: String) {
            value.codePoints().forEach { codepoint ->
                val keysym = if (codepoint <= 0xff) codepoint else 0x01000000 or codepoint
                key(keysym, true); key(keysym, false)
            }
        }

        fun skipServerCutText() {
            readBytes(3).fill(0)
            val length = readInt().toLong() and 0xffffffffL
            if (length > 65_536) throw VncNativeFailure("connectionFailed")
            readBytes(length.toInt()).fill(0)
        }

        fun readUnsignedByte() = input.readUnsignedByte()
        fun readUnsignedShort() = input.readUnsignedShort()
        fun readInt() = input.readInt()
        fun readFully(value: ByteArray) = input.readFully(value)
        private fun readBytes(length: Int) = ByteArray(length).also(input::readFully)
        private fun writeInt(value: Int) { output.writeInt(value); output.flush() }
        private fun write(value: ByteArray) { output.write(value); output.flush() }

        override fun close() {
            spkiDigest?.fill(0)
            spkiDigest = null
            try { socket.close() } catch (_: Exception) { /* terminal */ }
        }

        companion object {
            fun connect(host: String, port: Int): Connection {
                val addresses = try { InetAddress.getAllByName(host).toList() }
                catch (_: Exception) { throw VncNativeFailure("connectionFailed") }
                if (addresses.isEmpty() || addresses.size > 8) throw VncNativeFailure("connectionFailed")
                val sorted = addresses.map { VncIpAddress.take(it.address) }.sorted()
                if (sorted.any { !it.allowedForDirectVnc }) throw VncNativeFailure("invalidRequest")
                val selected = addresses.sortedBy { Base64.getEncoder().encodeToString(it.address) }.first()
                val socket = Socket()
                try {
                    socket.connect(InetSocketAddress(selected, port), CONNECT_TIMEOUT_MILLIS)
                    socket.soTimeout = IO_TIMEOUT_MILLIS
                    val confirmed = InetAddress.getAllByName(host).map { VncIpAddress.take(it.address) }.sorted()
                    if (confirmed != sorted || !socket.inetAddress.address.contentEquals(selected.address)) {
                        throw VncNativeFailure("connectionFailed")
                    }
                    return Connection(
                        socket,
                        DataInputStream(BufferedInputStream(socket.inputStream)),
                        DataOutputStream(BufferedOutputStream(socket.outputStream)),
                        host,
                        port,
                    )
                } catch (failure: VncNativeFailure) {
                    try { socket.close() } catch (_: Exception) {}
                    throw failure
                } catch (_: Exception) {
                    try { socket.close() } catch (_: Exception) {}
                    throw VncNativeFailure("connectionFailed")
                }
            }
        }
    }

    companion object {
        private const val ENGINE_REVISION = "android-rfb-vencrypt-1"
        private const val CONNECT_TIMEOUT_MILLIS = 10_000
        private const val IO_TIMEOUT_MILLIS = 30_000
        private const val MAX_DIMENSION = 2048
        private const val MAX_FRAME_BYTES = 16L * 1024 * 1024
        private const val VENCRYPT = 19
        private const val X509_VNC = 261L
        private const val RAW_ENCODING = 0
        private const val DESKTOP_SIZE_ENCODING = -308
        private val VERSION = "RFB 003.008\n".encodeToByteArray()
        private val VENCRYPT_VERSION = byteArrayOf(0, 2)
        // Certificate discovery is deliberately identity-neutral: it sends no
        // password or RFB application data and only returns the leaf SPKI for
        // an explicit user trust decision. The real session compares that
        // profile-bound pin before VNC authentication is allowed to begin.
        private val discoveryTlsContext: SSLContext = SSLContext.getInstance("TLSv1.3").apply {
            init(null, arrayOf(object : X509TrustManager {
                override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()

                override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) {
                    throw CertificateException("Client certificates are unsupported")
                }

                override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) {
                    if (chain.isNullOrEmpty() || chain.size > 16 || authType.isNullOrBlank()) {
                        throw CertificateException("Missing peer certificate")
                    }
                }
            }), SecureRandom())
        }

        private fun decodePin(value: String): ByteArray = try {
            Base64.getDecoder().decode(value.removePrefix("SHA256:") + "=").also {
                if (it.size != 32) throw VncNativeFailure("spkiPinningRequired")
            }
        } catch (failure: VncNativeFailure) {
            throw failure
        } catch (_: Exception) {
            throw VncNativeFailure("spkiPinningRequired")
        }

        private fun reverseBits(value: Byte): Byte {
            var input = value.toInt() and 0xff
            var result = 0
            repeat(8) { result = result shl 1 or (input and 1); input = input ushr 1 }
            return result.toByte()
        }
    }
}
