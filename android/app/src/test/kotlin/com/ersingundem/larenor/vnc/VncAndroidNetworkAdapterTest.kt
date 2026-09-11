package com.ersingundem.larenor.vnc

import java.net.ServerSocket
import java.net.Socket
import java.util.Base64
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLParameters
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class VncAndroidNetworkAdapterTest {
    @Test
    fun ownedLoopbackFixtureUsesRealSocketChannelOneConnectAndTwoDnsReads() {
        val server = ServerSocket(0, 1, java.net.InetAddress.getLoopbackAddress())
        val accepted = CountDownLatch(1)
        val acceptExecutor = Executors.newSingleThreadExecutor()
        acceptExecutor.execute {
            server.accept().use { accepted.countDown() }
        }
        val executor = Executors.newSingleThreadExecutor()
        val scheduler = Executors.newSingleThreadScheduledExecutor()
        try {
            val resolver = RecordingResolver(listOf(loopback()), listOf(loopback()))
            val tls = RecordingTlsHandshaker()
            val listener = Listener()
            val operation = VncAndroidNetworkAdapter(
                resolver = resolver,
                channelFactory = VncSystemSocketChannelFactory(),
                tlsHandshaker = tls,
                executor = executor,
                scheduler = scheduler,
            ).create(
                request = request("fixture.test", server.localPort),
                deadlineMillis = 5_000,
                scope = VncAndroidNetworkScope.OWNED_LOOPBACK_FIXTURE,
                listener = listener,
            )

            assertTrue(operation.start())
            assertTrue(listener.terminal.await(5, TimeUnit.SECONDS))
            assertTrue(accepted.await(5, TimeUnit.SECONDS))
            assertEquals(VncAndroidNetworkPhase.READY, operation.phase)
            assertNull(listener.failure)
            assertEquals(listOf("fixture.test", "fixture.test"), resolver.hosts)
            assertEquals(1, tls.calls)
            assertEquals("fixture.test", tls.host)
            assertEquals(server.localPort, tls.port)
            assertFalse(VncAndroidNetworkAdapter.productionAvailable)
            listener.connection?.close()
        } finally {
            server.close()
            acceptExecutor.shutdownNow()
            executor.shutdownNow()
            scheduler.shutdownNow()
        }
    }

    @Test
    fun systemTlsHandshakerRequiresTls13HostnameAndExactSpki() {
        val spki = "fixture-public-key".encodeToByteArray()
        val pin = "SHA256:" + Base64.getEncoder().withoutPadding().encodeToString(
            java.security.MessageDigest.getInstance("SHA-256").digest(spki),
        )
        val handle = TlsHandle(peerHost = "fixture.test", peerSpki = spki)
        val factory = TlsFactory(handle)
        val tcp = TcpConnection(Socket(), loopback())
        val result = VncSystemTlsHandshaker(factory).upgrade(
            tcp = tcp,
            serverName = "fixture.test",
            port = 5900,
            expectedSpkiFingerprint = pin,
            timeoutMillis = 4_000,
        )

        assertEquals(listOf("TLSv1.3"), handle.enabledProtocols.toList())
        assertEquals("HTTPS", handle.parameters.endpointIdentificationAlgorithm)
        assertEquals(4_000, handle.readTimeoutMillis)
        assertEquals(1, handle.handshakes)
        assertEquals("fixture.test", factory.host)
        assertEquals(5900, factory.port)
        assertEquals(false, factory.autoClose)
        result.takePeerEvidence().close()
        result.close()
        assertEquals(1, handle.closes)
        assertEquals(1, tcp.closes)

        val changed = TlsHandle(peerHost = "fixture.test", peerSpki = "changed".encodeToByteArray())
        val rejected = runCatching {
            VncSystemTlsHandshaker(TlsFactory(changed)).upgrade(
                TcpConnection(Socket(), loopback()), "fixture.test", 5900, pin, 4_000,
            )
        }.exceptionOrNull() as VncNativeFailure
        assertEquals("spkiPinningRequired", rejected.code)
        assertEquals(1, changed.closes)
    }

    @Test
    fun hostnameProtocolCipherAndPeerEvidenceFailuresCloseWithoutResult() {
        val pin = pin("key".encodeToByteArray())
        val cases = listOf(
            TlsHandle(peerHost = "other.test", peerSpki = "key".encodeToByteArray()),
            TlsHandle(peerHost = "fixture.test", protocol = "TLSv1.2", peerSpki = "key".encodeToByteArray()),
            TlsHandle(peerHost = "fixture.test", cipherSuite = "TLS_RSA_WITH_AES_128_CBC_SHA", peerSpki = "key".encodeToByteArray()),
            TlsHandle(peerHost = "fixture.test", peerSpki = ByteArray(0)),
        )
        for (handle in cases) {
            val failure = runCatching {
                VncSystemTlsHandshaker(TlsFactory(handle)).upgrade(
                    TcpConnection(Socket(), loopback()), "fixture.test", 5900, pin, 4_000,
                )
            }.exceptionOrNull() as VncNativeFailure
            assertEquals("tlsRequired", failure.code)
            assertEquals(1, handle.closes)
        }
    }

    @Test
    fun rebindingAndProductionLoopbackPolicyFailBeforeTls() {
        val executor = Executors.newSingleThreadExecutor()
        val scheduler = Executors.newSingleThreadScheduledExecutor()
        try {
            val tls = RecordingTlsHandshaker()
            val rebinding = Listener()
            val operation = VncAndroidNetworkAdapter(
                RecordingResolver(listOf(loopback()), listOf(address(127, 0, 0, 2))),
                FakeChannelFactory(), tls, executor, scheduler,
            ).create(
                request("fixture.test"), 5_000,
                VncAndroidNetworkScope.OWNED_LOOPBACK_FIXTURE, rebinding,
            )
            operation.start()
            assertTrue(rebinding.terminal.await(5, TimeUnit.SECONDS))
            assertEquals(VncAndroidNetworkPhase.FAILED, operation.phase)
            assertEquals(VncAndroidNetworkFailure.DNS_REBINDING, rebinding.failure)
            assertEquals(0, tls.calls)

            val production = Listener()
            val denied = VncAndroidNetworkAdapter(
                RecordingResolver(listOf(loopback())), FakeChannelFactory(), tls, executor, scheduler,
            ).create(request("fixture.test"), 5_000, VncAndroidNetworkScope.PRODUCTION, production)
            denied.start()
            assertTrue(production.terminal.await(5, TimeUnit.SECONDS))
            assertEquals(VncAndroidNetworkFailure.TARGET_REJECTED, production.failure)
            assertEquals(0, tls.calls)
        } finally {
            executor.shutdownNow()
            scheduler.shutdownNow()
        }
    }

    @Test
    fun cancellationAndTotalDeadlineAreTerminalAndNeverRetry() {
        val release = CountDownLatch(1)
        val executor = Executors.newSingleThreadExecutor()
        val scheduler = Executors.newSingleThreadScheduledExecutor()
        try {
            val resolver = object : VncAndroidDnsBackend {
                var calls = 0
                override fun resolve(host: String): List<VncIpAddress> {
                    calls++
                    release.await()
                    return listOf(loopback())
                }
            }
            val listener = Listener()
            val operation = VncAndroidNetworkAdapter(
                resolver, FakeChannelFactory(), RecordingTlsHandshaker(), executor, scheduler,
            ).create(request("fixture.test"), 100, VncAndroidNetworkScope.OWNED_LOOPBACK_FIXTURE, listener)
            assertTrue(operation.start())
            assertTrue(listener.terminal.await(2, TimeUnit.SECONDS))
            assertEquals(VncAndroidNetworkPhase.TIMED_OUT, operation.phase)
            assertEquals(VncAndroidNetworkFailure.TIMED_OUT, listener.failure)
            release.countDown()
            Thread.sleep(50)
            assertEquals(1, resolver.calls)
            assertFalse(operation.start())

            val cancelListener = Listener()
            val cancelResolver = RecordingResolver(listOf(loopback()))
            val cancelled = VncAndroidNetworkAdapter(
                cancelResolver, FakeChannelFactory(), RecordingTlsHandshaker(), executor, scheduler,
            ).create(request("fixture.test"), 5_000, VncAndroidNetworkScope.OWNED_LOOPBACK_FIXTURE, cancelListener)
            cancelled.cancel()
            assertEquals(VncAndroidNetworkPhase.CANCELLED, cancelled.phase)
            assertFalse(cancelled.start())
            assertTrue(cancelResolver.hosts.isEmpty())
        } finally {
            release.countDown()
            executor.shutdownNow()
            scheduler.shutdownNow()
        }
    }

    private fun request(host: String, port: Int = 5900) = VncNativeRequest.parse(mapOf<String, Any?>(
        "schemaVersion" to 1,
        "requestId" to "11111111-1111-4111-8111-111111111111",
        "targetHost" to host,
        "targetPort" to port,
        "security" to mapOf(
            "type" to "vencryptTlsVncAuth",
            "spkiFingerprint" to "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            "requiresPassword" to true,
        ),
        "display" to mapOf(
            "width" to 1280, "height" to 800, "dpi" to 180,
            "externalDisplay" to false, "dynamicResolution" to true,
        ),
        "framebuffer" to mapOf("encoding" to "raw", "pixelFormat" to "trueColor32"),
        "input" to mapOf("pointer" to true, "keyboard" to true, "clipboard" to false),
    ))

    private fun loopback() = address(127, 0, 0, 1)
    private fun address(a: Int, b: Int, c: Int, d: Int) =
        VncIpAddress.take(byteArrayOf(a.toByte(), b.toByte(), c.toByte(), d.toByte()))
    private fun pin(spki: ByteArray) = "SHA256:" + Base64.getEncoder().withoutPadding().encodeToString(
        java.security.MessageDigest.getInstance("SHA-256").digest(spki),
    )

    private class RecordingResolver(private vararg val answers: List<VncIpAddress>) : VncAndroidDnsBackend {
        val hosts = mutableListOf<String>()
        override fun resolve(host: String): List<VncIpAddress> {
            hosts += host
            return answers[(hosts.size - 1).coerceAtMost(answers.lastIndex)]
        }
    }

    private class Listener : VncAndroidNetworkOperation.Listener {
        val terminal = CountDownLatch(1)
        var connection: VncAndroidTlsConnection? = null
        var failure: VncAndroidNetworkFailure? = null
        override fun onReady(connection: VncAndroidTlsConnection) {
            this.connection = connection
            terminal.countDown()
        }
        override fun onFailure(failure: VncAndroidNetworkFailure) {
            this.failure = failure
            terminal.countDown()
        }
    }

    private class FakeChannelFactory : VncSocketChannelFactory {
        var calls = 0
        override fun connect(address: VncIpAddress, port: Int, timeoutMillis: Int): VncAndroidTcpConnection {
            calls++
            return TcpConnection(Socket(), address)
        }
    }

    private class TcpConnection(
        override val socket: Socket,
        override val peerAddress: VncIpAddress,
    ) : VncAndroidTcpConnection {
        var closes = 0
        override fun close() { closes++; socket.close() }
    }

    private class RecordingTlsHandshaker : VncAndroidTlsHandshaker {
        var calls = 0
        var host: String? = null
        var port: Int? = null
        override fun upgrade(
            tcp: VncAndroidTcpConnection,
            serverName: String,
            port: Int,
            expectedSpkiFingerprint: String,
            timeoutMillis: Int,
        ): VncAndroidTlsConnection {
            calls++
            host = serverName
            this.port = port
            return object : VncAndroidTlsConnection {
                private var evidence: VncTlsPeerEvidence? = VncTlsPeerEvidence.take(
                    "TLSv1.3", "TLS_AES_128_GCM_SHA256", true, true, ByteArray(32),
                )
                override val peerAddress = tcp.peerAddress
                override fun takePeerEvidence(): VncTlsPeerEvidence =
                    evidence?.also { evidence = null } ?: throw VncNativeFailure("staleSession")
                override fun close() { evidence?.close(); evidence = null; tcp.close() }
            }
        }
    }

    private class TlsFactory(private val handle: TlsHandle) : VncSslSocketFactory {
        var host: String? = null
        var port: Int? = null
        var autoClose: Boolean? = null
        override fun create(socket: Socket, host: String, port: Int, autoClose: Boolean): VncSslSocket {
            this.host = host
            this.port = port
            this.autoClose = autoClose
            return handle
        }
    }

    private class TlsHandle(
        override val peerHost: String,
        override val protocol: String = "TLSv1.3",
        override val cipherSuite: String = "TLS_AES_128_GCM_SHA256",
        override val peerSpki: ByteArray,
    ) : VncSslSocket {
        override var enabledProtocols: Array<String> = emptyArray()
        override var parameters: SSLParameters = SSLParameters()
        override var readTimeoutMillis: Int = 0
        var handshakes = 0
        var closes = 0
        override fun startHandshake() { handshakes++ }
        override fun close() { closes++ }
    }
}
