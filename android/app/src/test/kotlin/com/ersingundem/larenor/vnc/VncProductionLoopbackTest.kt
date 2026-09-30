package com.ersingundem.larenor.vnc

import android.app.Application
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.Inet4Address
import java.net.NetworkInterface
import java.net.ServerSocket
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.file.Files
import java.nio.file.Path
import java.security.KeyStore
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocket
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class VncProductionLoopbackTest {
    private class Messenger : BinaryMessenger {
        override fun send(channel: String, message: ByteBuffer?) = Unit
        override fun send(
            channel: String,
            message: ByteBuffer?,
            callback: BinaryMessenger.BinaryReply?,
        ) = Unit
        override fun setMessageHandler(
            channel: String,
            handler: BinaryMessenger.BinaryMessageHandler?,
        ) = Unit
    }

    private class Result : MethodChannel.Result {
        @Volatile var value: Any? = null
        @Volatile var error: String? = null
        @Volatile var completed = false
        override fun success(result: Any?) { value = result; completed = true }
        override fun error(code: String, message: String?, details: Any?) {
            error = code
            completed = true
        }
        override fun notImplemented() { error = "notImplemented"; completed = true }
    }

    private class Sink : EventChannel.EventSink {
        val values = mutableListOf<Map<*, *>>()
        @Volatile var error: String? = null
        override fun success(event: Any?) {
            @Suppress("UNCHECKED_CAST")
            values += event as Map<*, *>
        }
        override fun error(code: String, message: String?, details: Any?) { error = code }
        override fun endOfStream() = Unit
    }

    @Test
    fun productionBridgeCompletesPinnedRfbFrameInputResizeAndDisconnectAgainstOwnedHost() {
        val fixture = OwnedRfbFixture()
        val bridge = VncNativeBridge(Messenger())
        val sink = Sink()
        try {
            fixture.start()
            bridge.onListen(null, sink)
            bridge.setResumed(true)
            bridge.onMethodCall(MethodCall("activate", binding()), Result())

            val password = PASSWORD.encodeToByteArray()
            val opened = Result()
            bridge.onMethodCall(MethodCall("open", mapOf(
                "binding" to binding(),
                "request" to request(fixture),
                "expectedEngineRevision" to "android-rfb-vencrypt-1",
                "password" to password,
            )), opened)
            pumpUntil { opened.completed }
            assertNull(opened.error)
            assertTrue(password.all { it == 0.toByte() })

            pumpUntil { sink.values.isNotEmpty() }
            val frame = sink.values.single()
            assertEquals(1L, frame["sequence"])
            assertEquals(2, frame["width"])
            assertEquals(2, frame["height"])
            assertArrayEquals(EXPECTED_FRAME, frame["pixels"] as ByteArray)

            bridge.onMethodCall(MethodCall("ackFrame", mapOf(
                "binding" to binding(), "sequence" to 1L,
            )), Result())
            bridge.onMethodCall(MethodCall("input", mapOf(
                "binding" to binding(), "sequence" to 1L,
                "event" to mapOf("kind" to "pointer", "x" to 1.0, "y" to 0.0, "buttons" to 1),
            )), Result())
            bridge.onMethodCall(MethodCall("input", mapOf(
                "binding" to binding(), "sequence" to 2L,
                "event" to mapOf("kind" to "text", "text" to "Türkçe"),
            )), Result())
            bridge.onMethodCall(MethodCall("resize", mapOf(
                "binding" to binding(), "width" to 800, "height" to 600,
            )), Result())

            assertTrue(fixture.finished.await(5, TimeUnit.SECONDS))
            fixture.failure.get()?.let { throw AssertionError("Owned RFB fixture failed", it) }
            pumpUntil { sink.error != null }
            assertEquals("connectionFailed", sink.error)
            assertEquals(listOf("ack", "pointer", "text", "resize"), fixture.observed)
        } finally {
            bridge.dispose()
            fixture.close()
        }
    }

    private fun binding() = mapOf(
        "ownerId" to "22222222-2222-4222-8222-222222222222",
        "accountRevision" to 7,
        "routeRevision" to 11,
    )

    private fun request(fixture: OwnedRfbFixture) = mapOf<String, Any?>(
        "schemaVersion" to 1,
        "requestId" to "11111111-1111-4111-8111-111111111111",
        "targetHost" to fixture.address.hostAddress,
        "targetPort" to fixture.port,
        "security" to mapOf(
            "type" to "vencryptTlsVncAuth",
            "spkiFingerprint" to fixture.pin,
            "requiresPassword" to true,
        ),
        "display" to mapOf(
            "width" to 800, "height" to 600, "dpi" to 180,
            "externalDisplay" to false, "dynamicResolution" to true,
        ),
        "framebuffer" to mapOf("encoding" to "raw", "pixelFormat" to "trueColor32"),
        "input" to mapOf("pointer" to true, "keyboard" to true, "clipboard" to false),
    )

    private fun pumpUntil(condition: () -> Boolean) {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(8)
        while (!condition() && System.nanoTime() < deadline) {
            shadowOf(Looper.getMainLooper()).idle()
            Thread.sleep(10)
        }
        shadowOf(Looper.getMainLooper()).idle()
        assertTrue("Timed out waiting for production VNC bridge", condition())
    }

    private class OwnedRfbFixture : AutoCloseable {
        val address: Inet4Address = NetworkInterface.getNetworkInterfaces().toList()
            .flatMap { it.inetAddresses.toList() }
            .filterIsInstance<Inet4Address>()
            .first { !it.isAnyLocalAddress && !it.isLoopbackAddress &&
                !it.isLinkLocalAddress && !it.isMulticastAddress }
        private val storeFile = createFixtureStore()
        private val store = KeyStore.getInstance("PKCS12").apply {
            Files.newInputStream(storeFile).use { load(it, STORE_PASSWORD) }
        }
        private val server = ServerSocket(0, 1, address)
        private val executor = Executors.newSingleThreadExecutor()
        val port: Int get() = server.localPort
        val pin: String = store.getCertificate("vnc-fixture").publicKey.encoded.let { spki ->
            try {
                "SHA256:" + Base64.getEncoder().withoutPadding().encodeToString(
                    MessageDigest.getInstance("SHA-256").digest(spki),
                )
            } finally { spki.fill(0) }
        }
        val observed = mutableListOf<String>()
        val failure = AtomicReference<Throwable?>()
        val finished = CountDownLatch(1)

        fun start() {
            executor.execute {
                try { server.accept().use(::serve) }
                catch (error: Throwable) { failure.set(error) }
                finally { finished.countDown() }
            }
        }

        private fun serve(socket: Socket) {
            socket.soTimeout = 8_000
            val plainInput = DataInputStream(BufferedInputStream(socket.inputStream))
            val plainOutput = DataOutputStream(BufferedOutputStream(socket.outputStream))
            plainOutput.write(VERSION); plainOutput.flush()
            assertArrayEquals(VERSION, plainInput.readNBytes(VERSION.size))
            plainOutput.write(byteArrayOf(1, 19)); plainOutput.flush()
            assertEquals(19, plainInput.readUnsignedByte())
            plainOutput.write(byteArrayOf(0, 2)); plainOutput.flush()
            assertArrayEquals(byteArrayOf(0, 2), plainInput.readNBytes(2))
            plainOutput.writeByte(0)
            plainOutput.writeByte(1)
            plainOutput.writeInt(261)
            plainOutput.flush()
            assertEquals(261, plainInput.readInt())

            val keyManager = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm()).apply {
                init(store, STORE_PASSWORD)
            }
            val context = SSLContext.getInstance("TLSv1.3").apply {
                init(keyManager.keyManagers, null, SecureRandom())
            }
            val tls = context.socketFactory.createSocket(socket, address.hostAddress, port, true) as SSLSocket
            tls.useClientMode = false
            tls.enabledProtocols = arrayOf("TLSv1.3")
            tls.soTimeout = 8_000
            tls.startHandshake()
            DataInputStream(BufferedInputStream(tls.inputStream)).use { input ->
                DataOutputStream(BufferedOutputStream(tls.outputStream)).use { output ->
                    output.write(CHALLENGE); output.flush()
                    assertEquals(16, input.readNBytes(16).size)
                    output.writeInt(0); output.flush()
                    assertEquals(1, input.readUnsignedByte())
                    writeServerInit(output)

                    assertEquals(0, input.readUnsignedByte())
                    assertEquals(19, input.readNBytes(19).size)
                    assertEquals(2, input.readUnsignedByte())
                    assertEquals(11, input.readNBytes(11).size)
                    assertEquals(3, input.readUnsignedByte())
                    assertEquals(9, input.readNBytes(9).size)
                    writeFrame(output)

                    assertEquals(3, input.readUnsignedByte())
                    assertEquals(9, input.readNBytes(9).size)
                    observed += "ack"
                    assertEquals(5, input.readUnsignedByte())
                    assertEquals(5, input.readNBytes(5).size)
                    observed += "pointer"
                    repeat("Türkçe".codePointCount(0, "Türkçe".length) * 2) {
                        assertEquals(4, input.readUnsignedByte())
                        assertEquals(7, input.readNBytes(7).size)
                    }
                    observed += "text"
                    assertEquals(251, input.readUnsignedByte())
                    assertEquals(23, input.readNBytes(23).size)
                    observed += "resize"
                }
            }
        }

        private fun writeServerInit(output: DataOutputStream) {
            output.writeShort(2)
            output.writeShort(2)
            output.write(byteArrayOf(
                32, 24, 0, 1,
                0, 0xff.toByte(), 0, 0xff.toByte(), 0, 0xff.toByte(),
                0, 8, 16, 0, 0, 0,
            ))
            val name = "Larenor fixture".encodeToByteArray()
            output.writeInt(name.size)
            output.write(name)
            output.flush()
        }

        private fun writeFrame(output: DataOutputStream) {
            output.writeByte(0)
            output.writeByte(0)
            output.writeShort(1)
            output.writeShort(0)
            output.writeShort(0)
            output.writeShort(2)
            output.writeShort(2)
            output.writeInt(0)
            output.write(SERVER_FRAME)
            output.flush()
        }

        override fun close() {
            try { server.close() } catch (_: Exception) { /* terminal */ }
            executor.shutdownNow()
            Files.deleteIfExists(storeFile)
        }

        private fun createFixtureStore(): Path {
            val output = Files.createTempFile("larenor-vnc-fixture-", ".p12")
            Files.deleteIfExists(output)
            val keytool = Path.of(System.getProperty("java.home"), "bin", "keytool").toString()
            val process = ProcessBuilder(
                keytool,
                "-genkeypair",
                "-alias", "vnc-fixture",
                "-keyalg", "RSA",
                "-keysize", "2048",
                "-sigalg", "SHA256withRSA",
                "-validity", "2",
                "-dname", "CN=larenor-vnc-fixture",
                "-storetype", "PKCS12",
                "-keystore", output.toString(),
                "-storepass", String(STORE_PASSWORD),
                "-keypass", String(STORE_PASSWORD),
                "-noprompt",
            ).redirectErrorStream(true).start()
            val diagnostics = process.inputStream.readBytes()
            try {
                if (!process.waitFor(15, TimeUnit.SECONDS) || process.exitValue() != 0) {
                    process.destroyForcibly()
                    throw AssertionError("Unable to create bounded VNC TLS fixture")
                }
            } finally {
                diagnostics.fill(0)
            }
            return output
        }
    }

    companion object {
        private const val PASSWORD = "secret"
        private val STORE_PASSWORD = "fixture-pass".toCharArray()
        private val VERSION = "RFB 003.008\n".encodeToByteArray()
        private val CHALLENGE = ByteArray(16) { it.toByte() }
        private val SERVER_FRAME = byteArrayOf(
            1, 2, 3, 0,
            4, 5, 6, 0,
            7, 8, 9, 0,
            10, 11, 12, 0,
        )
        private val EXPECTED_FRAME = byteArrayOf(
            1, 2, 3, 0xff.toByte(),
            4, 5, 6, 0xff.toByte(),
            7, 8, 9, 0xff.toByte(),
            10, 11, 12, 0xff.toByte(),
        )
    }
}
