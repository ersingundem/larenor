package com.ersingundem.larenor.vnc

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class VncDirectTcpSessionTest {
    @Test
    fun domainUsesOneDirectConnectAndExactPostConnectDnsRevalidation() {
        var now = 1_000L
        val resolver = Resolver()
        val connector = Connector()
        val session = VncDirectTcpSession(
            request = request("desktop.home.arpa", 5901),
            resolver = resolver,
            connector = connector,
            deadlineMillis = 12_000,
            nowMillis = { now },
        )
        assertEquals(VncDirectTcpPhase.RESOLVING, session.phase)
        assertEquals(listOf("desktop.home.arpa"), resolver.hosts)
        assertEquals(listOf(13_000L), resolver.deadlines)

        val first = address(192, 168, 10, 8)
        val second = address(192, 168, 10, 9)
        resolver.latest.resolved(listOf(second, first))
        assertEquals(VncDirectTcpPhase.CONNECTING, session.phase)
        assertEquals(1, connector.targets.size)
        assertEquals(first, connector.targets.single().address)
        assertEquals(5901, connector.targets.single().port)
        assertFalse(connector.targets.single().proxyAllowed)

        val connection = Connection(first)
        connector.latest.connected(connection)
        assertEquals(VncDirectTcpPhase.REVALIDATING, session.phase)
        assertEquals(2, resolver.hosts.size)
        resolver.latest.resolved(listOf(first, second))

        assertEquals(VncDirectTcpPhase.READY, session.phase)
        assertNull(session.failureCode)
        assertEquals(0, connection.closes)
        assertEquals(1, connector.targets.size)
        assertFalse(VncDirectTcpSession.productionAvailable)
    }

    @Test
    fun dnsRebindingAndPeerDriftFailClosedAndCloseTheConnection() {
        val resolver = Resolver()
        val connector = Connector()
        val session = VncDirectTcpSession(request("desktop.home.arpa"), resolver, connector, 5_000) { 0L }
        val pinned = address(10, 0, 0, 8)
        resolver.latest.resolved(listOf(pinned))
        val connection = Connection(pinned)
        connector.latest.connected(connection)
        resolver.latest.resolved(listOf(address(10, 0, 0, 9)))
        assertEquals(VncDirectTcpPhase.FAILED, session.phase)
        assertEquals("connectionFailed", session.failureCode)
        assertEquals(1, connection.closes)
        assertEquals(1, connector.targets.size)

        val peerResolver = Resolver()
        val peerConnector = Connector()
        val peerSession = VncDirectTcpSession(request("server.home.arpa"), peerResolver, peerConnector, 5_000) { 0L }
        peerResolver.latest.resolved(listOf(pinned))
        val drifted = Connection(address(10, 0, 0, 10))
        peerConnector.latest.connected(drifted)
        assertEquals(VncDirectTcpPhase.FAILED, peerSession.phase)
        assertEquals(1, drifted.closes)
        assertEquals(1, peerResolver.hosts.size)
    }

    @Test
    fun loopbackLinkLocalUnspecifiedAndMulticastNeverReachTheConnector() {
        for (host in listOf("127.0.0.1", "169.254.10.2", "0.0.0.0", "224.0.0.1", "::1", "fe80::1")) {
            val resolver = Resolver()
            val connector = Connector()
            val session = VncDirectTcpSession(request(host), resolver, connector, 5_000) { 0L }
            assertEquals(VncDirectTcpPhase.FAILED, session.phase)
            assertEquals("invalidRequest", session.failureCode)
            assertTrue(resolver.hosts.isEmpty())
            assertTrue(connector.targets.isEmpty())
        }

        val resolver = Resolver()
        val connector = Connector()
        val session = VncDirectTcpSession(request("mixed.home.arpa"), resolver, connector, 5_000) { 0L }
        resolver.latest.resolved(listOf(address(192, 168, 1, 5), address(127, 0, 0, 1)))
        assertEquals(VncDirectTcpPhase.FAILED, session.phase)
        assertEquals("connectionFailed", session.failureCode)
        assertTrue(connector.targets.isEmpty())
    }

    @Test
    fun literalIpSkipsDnsAndRequiresTheExactConnectedPeer() {
        val resolver = Resolver()
        val connector = Connector()
        val session = VncDirectTcpSession(request("192.168.50.4"), resolver, connector, 5_000) { 0L }
        assertTrue(resolver.hosts.isEmpty())
        assertEquals(1, connector.targets.size)
        connector.latest.connected(Connection(address(192, 168, 50, 4)))
        assertEquals(VncDirectTcpPhase.READY, session.phase)
        assertEquals(1, connector.targets.size)
    }

    @Test
    fun deadlineBackgroundAndExplicitCloseCancelOnceAndDiscardLateCallbacks() {
        val invalid = runCatching {
            VncDirectTcpSession(request("192.168.1.8"), Resolver(), Connector(), 30_001) { 0L }
        }.exceptionOrNull() as VncNativeFailure
        assertEquals("invalidRequest", invalid.code)

        var now = 100L
        val resolver = Resolver()
        val connector = Connector()
        val session = VncDirectTcpSession(request("desktop.home.arpa"), resolver, connector, 2_000) { now }
        now = 2_101L
        session.checkDeadline()
        session.close()
        assertEquals(VncDirectTcpPhase.TIMED_OUT, session.phase)
        assertEquals("timedOut", session.failureCode)
        assertEquals(1, resolver.operations.single().cancels)
        assertEquals(1, resolver.operations.single().detaches)
        resolver.operations.single().resolved(listOf(address(192, 168, 1, 8)))
        assertTrue(connector.targets.isEmpty())

        val literalConnector = Connector()
        val background = VncDirectTcpSession(
            request("192.168.1.8"), Resolver(), literalConnector, 2_000,
        ) { 100L }
        background.setForeground(false)
        assertEquals(VncDirectTcpPhase.CANCELLED, background.phase)
        assertEquals(1, literalConnector.operations.single().cancels)
        assertEquals(1, literalConnector.operations.single().detaches)
        val late = Connection(address(192, 168, 1, 8))
        literalConnector.operations.single().connected(late)
        assertEquals(1, late.closes)
    }

    @Test
    fun lookupOrConnectFailureIsTerminalWithoutRetryOrSecondAddressAttempt() {
        val resolver = Resolver()
        val connector = Connector()
        val session = VncDirectTcpSession(request("desktop.home.arpa"), resolver, connector, 5_000) { 0L }
        resolver.latest.resolved(listOf(address(10, 0, 0, 8), address(10, 0, 0, 9)))
        connector.latest.failed()
        connector.latest.failed()
        assertEquals(VncDirectTcpPhase.FAILED, session.phase)
        assertEquals("connectionFailed", session.failureCode)
        assertEquals(1, connector.targets.size)
        assertEquals(1, connector.operations.single().cancels)

        val failedResolver = Resolver()
        val noConnector = Connector()
        val lookup = VncDirectTcpSession(request("missing.home.arpa"), failedResolver, noConnector, 5_000) { 0L }
        failedResolver.latest.failed()
        assertEquals(VncDirectTcpPhase.FAILED, lookup.phase)
        assertTrue(noConnector.targets.isEmpty())
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

    private fun address(a: Int, b: Int, c: Int, d: Int) =
        VncIpAddress.take(byteArrayOf(a.toByte(), b.toByte(), c.toByte(), d.toByte()))

    private class Resolver : VncDnsResolver {
        val hosts = mutableListOf<String>()
        val deadlines = mutableListOf<Long>()
        val operations = mutableListOf<DnsOperation>()
        val latest get() = operations.last()
        override fun create(host: String, deadlineAtMillis: Long): VncDnsLookup {
            hosts += host
            deadlines += deadlineAtMillis
            return DnsOperation().also { operations += it }
        }
    }

    private class DnsOperation : VncDnsLookup {
        private var listener: VncDnsLookup.Listener? = null
        var starts = 0
        var cancels = 0
        var detaches = 0
        override fun attach(listener: VncDnsLookup.Listener) { this.listener = listener }
        override fun start(): Boolean { starts++; return true }
        override fun cancel() { cancels++ }
        override fun detach() { detaches++; listener = null }
        fun resolved(addresses: List<VncIpAddress>) { listener?.onResolved(addresses) }
        fun failed() { listener?.onFailure() }
    }

    private class Connector : VncDirectTcpConnector {
        val targets = mutableListOf<VncDirectTcpTarget>()
        val operations = mutableListOf<ConnectOperation>()
        val latest get() = operations.last()
        override fun create(target: VncDirectTcpTarget, deadlineAtMillis: Long): VncTcpConnect {
            targets += target
            return ConnectOperation().also { operations += it }
        }
    }

    private class ConnectOperation : VncTcpConnect {
        private var listener: VncTcpConnect.Listener? = null
        var starts = 0
        var cancels = 0
        var detaches = 0
        override fun attach(listener: VncTcpConnect.Listener) { this.listener = listener }
        override fun start(): Boolean { starts++; return true }
        override fun cancel() { cancels++ }
        override fun detach() { detaches++; listener = null }
        fun connected(connection: VncDirectTcpConnection) {
            listener?.onConnected(connection) ?: connection.close()
        }
        fun failed() { listener?.onFailure() }
    }

    private class Connection(override val peerAddress: VncIpAddress) : VncDirectTcpConnection {
        var closes = 0
        override fun close() { closes++ }
    }
}
