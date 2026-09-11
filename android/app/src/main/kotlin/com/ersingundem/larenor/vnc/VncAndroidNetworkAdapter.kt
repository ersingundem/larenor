package com.ersingundem.larenor.vnc

import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.channels.SocketChannel
import java.security.MessageDigest
import java.util.Base64
import java.util.concurrent.ExecutorService
import java.util.concurrent.Future
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import javax.net.ssl.SSLParameters
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory

internal enum class VncAndroidNetworkScope { PRODUCTION, OWNED_LOOPBACK_FIXTURE }

internal enum class VncAndroidNetworkPhase {
    IDLE,
    RUNNING,
    READY,
    CANCELLED,
    TIMED_OUT,
    FAILED,
}

internal enum class VncAndroidNetworkFailure {
    TARGET_REJECTED,
    DNS_FAILED,
    DNS_REBINDING,
    CONNECT_FAILED,
    TLS_FAILED,
    TIMED_OUT,
}

internal interface VncAndroidDnsBackend {
    fun resolve(host: String): List<VncIpAddress>
}

/** System DNS implementation; it is available only through explicit dependency injection. */
internal class VncSystemDnsBackend : VncAndroidDnsBackend {
    override fun resolve(host: String): List<VncIpAddress> =
        InetAddress.getAllByName(host).map { VncIpAddress.take(it.address) }
}

internal interface VncAndroidTcpConnection : AutoCloseable {
    val socket: Socket
    val peerAddress: VncIpAddress
}

internal interface VncSocketChannelFactory {
    fun connect(address: VncIpAddress, port: Int, timeoutMillis: Int): VncAndroidTcpConnection
}

/** Direct numeric-address connector. No URL, proxy selector, or environment input is used. */
internal class VncSystemSocketChannelFactory : VncSocketChannelFactory {
    override fun connect(
        address: VncIpAddress,
        port: Int,
        timeoutMillis: Int,
    ): VncAndroidTcpConnection {
        if (port !in 1..65535 || timeoutMillis !in 1..MAX_TIMEOUT_MILLIS) {
            throw VncNativeFailure("invalidRequest")
        }
        val channel = SocketChannel.open()
        try {
            channel.configureBlocking(true)
            val numericAddress = InetAddress.getByAddress(address.encodedCopy())
            channel.socket().connect(InetSocketAddress(numericAddress, port), timeoutMillis)
            val peer = (channel.remoteAddress as? InetSocketAddress)?.address
                ?: throw VncNativeFailure("connectionFailed")
            return SystemTcpConnection(channel, VncIpAddress.take(peer.address))
        } catch (failure: VncNativeFailure) {
            try { channel.close() } catch (_: Exception) { /* terminal */ }
            throw failure
        } catch (_: Exception) {
            try { channel.close() } catch (_: Exception) { /* terminal */ }
            throw VncNativeFailure("connectionFailed")
        }
    }

    private class SystemTcpConnection(
        private val channel: SocketChannel,
        override val peerAddress: VncIpAddress,
    ) : VncAndroidTcpConnection {
        override val socket: Socket get() = channel.socket()
        override fun close() {
            try { channel.close() } catch (_: Exception) { /* terminal */ }
        }
    }

    companion object { private const val MAX_TIMEOUT_MILLIS = 30_000 }
}

internal interface VncSslSocket : AutoCloseable {
    var enabledProtocols: Array<String>
    var parameters: SSLParameters
    var readTimeoutMillis: Int
    val peerHost: String
    val protocol: String
    val cipherSuite: String
    val peerSpki: ByteArray
    fun startHandshake()
}

internal interface VncSslSocketFactory {
    fun create(socket: Socket, host: String, port: Int, autoClose: Boolean): VncSslSocket
}

/** SSLSocket wrapper; the caller must explicitly inject the chosen trust-configured factory. */
internal class VncSystemSslSocketFactory(
    private val factory: SSLSocketFactory,
) : VncSslSocketFactory {
    override fun create(socket: Socket, host: String, port: Int, autoClose: Boolean): VncSslSocket {
        val ssl = factory.createSocket(socket, host, port, autoClose) as? SSLSocket
            ?: throw VncNativeFailure("tlsRequired")
        return SystemSslSocket(ssl)
    }

    private class SystemSslSocket(private val socket: SSLSocket) : VncSslSocket {
        override var enabledProtocols: Array<String>
            get() = socket.enabledProtocols
            set(value) { socket.enabledProtocols = value }
        override var parameters: SSLParameters
            get() = socket.sslParameters
            set(value) { socket.sslParameters = value }
        override var readTimeoutMillis: Int
            get() = socket.soTimeout
            set(value) { socket.soTimeout = value }
        override val peerHost: String get() = socket.session.peerHost
        override val protocol: String get() = socket.session.protocol
        override val cipherSuite: String get() = socket.session.cipherSuite
        override val peerSpki: ByteArray
            get() = socket.session.peerCertificates.firstOrNull()?.publicKey?.encoded?.copyOf()
                ?: ByteArray(0)
        override fun startHandshake() = socket.startHandshake()
        override fun close() = socket.close()
    }
}

internal interface VncAndroidTlsConnection : AutoCloseable {
    val peerAddress: VncIpAddress
    fun takePeerEvidence(): VncTlsPeerEvidence
}

internal interface VncAndroidTlsHandshaker {
    fun upgrade(
        tcp: VncAndroidTcpConnection,
        serverName: String,
        port: Int,
        expectedSpkiFingerprint: String,
        timeoutMillis: Int,
    ): VncAndroidTlsConnection
}

internal class VncSystemTlsHandshaker(
    private val factory: VncSslSocketFactory,
) : VncAndroidTlsHandshaker {
    override fun upgrade(
        tcp: VncAndroidTcpConnection,
        serverName: String,
        port: Int,
        expectedSpkiFingerprint: String,
        timeoutMillis: Int,
    ): VncAndroidTlsConnection {
        if (timeoutMillis !in 1..MAX_TIMEOUT_MILLIS) throw VncNativeFailure("timedOut")
        val ssl = try {
            factory.create(tcp.socket, serverName, port, autoClose = false)
        } catch (_: Exception) {
            tcp.close()
            throw VncNativeFailure("tlsRequired")
        }
        try {
            ssl.enabledProtocols = arrayOf("TLSv1.3")
            ssl.parameters = ssl.parameters.apply { endpointIdentificationAlgorithm = "HTTPS" }
            ssl.readTimeoutMillis = timeoutMillis
            ssl.startHandshake()
            val spki = ssl.peerSpki
            try {
                if (ssl.protocol != "TLSv1.3" || ssl.peerHost.lowercase() != serverName.lowercase() ||
                    ssl.cipherSuite !in ALLOWED_CIPHERS || spki.isEmpty() || spki.size > MAX_SPKI_BYTES
                ) throw VncNativeFailure("tlsRequired")
                val expected = decodePin(expectedSpkiFingerprint)
                val actual = MessageDigest.getInstance("SHA-256").digest(spki)
                try {
                    if (!MessageDigest.isEqual(expected, actual)) {
                        throw VncNativeFailure("spkiPinningRequired")
                    }
                    return SystemTlsConnection(
                        tcp,
                        ssl,
                        VncTlsPeerEvidence.take(
                            protocol = ssl.protocol,
                            cipherSuite = ssl.cipherSuite,
                            certificateChainValid = true,
                            hostnameVerified = true,
                            spkiSha256 = actual.copyOf(),
                        ),
                    )
                } finally {
                    expected.fill(0)
                    actual.fill(0)
                }
            } finally {
                spki.fill(0)
            }
        } catch (failure: VncNativeFailure) {
            safeClose(ssl)
            tcp.close()
            throw failure
        } catch (_: Exception) {
            safeClose(ssl)
            tcp.close()
            throw VncNativeFailure("tlsRequired")
        }
    }

    private fun decodePin(value: String): ByteArray {
        if (!value.startsWith("SHA256:")) throw VncNativeFailure("spkiPinningRequired")
        val decoded = try { Base64.getDecoder().decode(value.removePrefix("SHA256:") + "=") }
        catch (_: Exception) { throw VncNativeFailure("spkiPinningRequired") }
        if (decoded.size != 32) {
            decoded.fill(0)
            throw VncNativeFailure("spkiPinningRequired")
        }
        return decoded
    }

    private fun safeClose(value: AutoCloseable) {
        try { value.close() } catch (_: Exception) { /* terminal */ }
    }

    private class SystemTlsConnection(
        private val tcp: VncAndroidTcpConnection,
        private val ssl: VncSslSocket,
        private var evidence: VncTlsPeerEvidence?,
    ) : VncAndroidTlsConnection {
        private var closed = false
        override val peerAddress = tcp.peerAddress
        override fun takePeerEvidence(): VncTlsPeerEvidence {
            if (closed) throw VncNativeFailure("staleSession")
            return evidence?.also { evidence = null } ?: throw VncNativeFailure("staleSession")
        }
        override fun close() {
            if (closed) return
            closed = true
            evidence?.close()
            evidence = null
            try { ssl.close() } catch (_: Exception) { /* terminal */ }
            tcp.close()
        }
    }

    companion object {
        private const val MAX_TIMEOUT_MILLIS = 30_000
        private const val MAX_SPKI_BYTES = 16_384
        private val ALLOWED_CIPHERS = setOf(
            "TLS_AES_128_GCM_SHA256",
            "TLS_AES_256_GCM_SHA384",
            "TLS_CHACHA20_POLY1305_SHA256",
        )
    }
}

internal interface VncAndroidNetworkOperation : AutoCloseable {
    interface Listener {
        fun onReady(connection: VncAndroidTlsConnection)
        fun onFailure(failure: VncAndroidNetworkFailure)
    }

    val phase: VncAndroidNetworkPhase
    fun start(): Boolean
    fun cancel()
    fun detach()
    fun setForeground(foreground: Boolean)
    override fun close() = cancel()
}

internal class VncAndroidNetworkAdapter(
    private val resolver: VncAndroidDnsBackend,
    private val channelFactory: VncSocketChannelFactory,
    private val tlsHandshaker: VncAndroidTlsHandshaker,
    private val executor: ExecutorService,
    private val scheduler: ScheduledExecutorService,
) {
    fun create(
        request: VncNativeRequest,
        deadlineMillis: Long,
        scope: VncAndroidNetworkScope,
        listener: VncAndroidNetworkOperation.Listener,
    ): VncAndroidNetworkOperation {
        if (deadlineMillis !in 1..MAX_DEADLINE_MILLIS) throw VncNativeFailure("invalidRequest")
        return Operation(request, deadlineMillis, scope, listener)
    }

    private inner class Operation(
        private val request: VncNativeRequest,
        private val deadlineMillis: Long,
        private val scope: VncAndroidNetworkScope,
        listener: VncAndroidNetworkOperation.Listener,
    ) : VncAndroidNetworkOperation {
        @Volatile override var phase = VncAndroidNetworkPhase.IDLE
            private set
        @Volatile private var listener: VncAndroidNetworkOperation.Listener? = listener
        @Volatile private var tcp: VncAndroidTcpConnection? = null
        @Volatile private var tls: VncAndroidTlsConnection? = null
        @Volatile private var task: Future<*>? = null
        @Volatile private var timeout: ScheduledFuture<*>? = null
        private val terminal = AtomicBoolean(false)
        private val started = AtomicBoolean(false)
        private var deadlineNanos = 0L

        override fun start(): Boolean {
            if (!started.compareAndSet(false, true) || terminal.get()) return false
            phase = VncAndroidNetworkPhase.RUNNING
            val durationNanos = TimeUnit.MILLISECONDS.toNanos(deadlineMillis)
            val now = System.nanoTime()
            deadlineNanos = if (now > Long.MAX_VALUE - durationNanos) Long.MAX_VALUE else now + durationNanos
            timeout = scheduler.schedule(
                { terminate(VncAndroidNetworkPhase.TIMED_OUT, VncAndroidNetworkFailure.TIMED_OUT) },
                deadlineMillis,
                TimeUnit.MILLISECONDS,
            )
            task = executor.submit { runPipeline() }
            return true
        }

        override fun cancel() {
            terminate(VncAndroidNetworkPhase.CANCELLED, null)
        }

        override fun detach() {
            listener = null
        }

        override fun setForeground(foreground: Boolean) {
            if (!foreground) cancel()
        }

        private fun runPipeline() {
            var stageFailure = VncAndroidNetworkFailure.DNS_FAILED
            try {
                val literal = VncIpAddress.parseLiteral(request.directTargetHost)
                val first = if (literal != null) {
                    validateAddresses(listOf(literal))
                } else {
                    resolve()
                }
                ensureRunning()
                val selected = first.first()
                stageFailure = VncAndroidNetworkFailure.CONNECT_FAILED
                val connected = channelFactory.connect(selected, request.directTargetPort, remainingMillis())
                if (!isRunning()) {
                    connected.close()
                    return
                }
                tcp = connected
                if (connected.peerAddress != selected || connected.peerAddress !in first) {
                    throw NetworkRejected(VncAndroidNetworkFailure.DNS_REBINDING)
                }
                if (literal == null) {
                    val post = resolve()
                    if (post != first || connected.peerAddress !in post) {
                        throw NetworkRejected(VncAndroidNetworkFailure.DNS_REBINDING)
                    }
                }
                ensureRunning()
                stageFailure = VncAndroidNetworkFailure.TLS_FAILED
                val secured = tlsHandshaker.upgrade(
                    tcp = connected,
                    serverName = request.directTargetHost,
                    port = request.directTargetPort,
                    expectedSpkiFingerprint = request.directSpkiFingerprint,
                    timeoutMillis = remainingMillis(),
                )
                tcp = null
                if (!isRunning()) {
                    secured.close()
                    return
                }
                tls = secured
                complete(secured)
            } catch (failure: NetworkRejected) {
                terminate(VncAndroidNetworkPhase.FAILED, failure.failure)
            } catch (failure: VncNativeFailure) {
                val mapped = when (failure.code) {
                    "timedOut" -> VncAndroidNetworkFailure.TIMED_OUT
                    "tlsRequired", "spkiPinningRequired" -> VncAndroidNetworkFailure.TLS_FAILED
                    else -> VncAndroidNetworkFailure.CONNECT_FAILED
                }
                terminate(
                    if (mapped == VncAndroidNetworkFailure.TIMED_OUT) VncAndroidNetworkPhase.TIMED_OUT
                    else VncAndroidNetworkPhase.FAILED,
                    mapped,
                )
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
                if (!terminal.get()) terminate(VncAndroidNetworkPhase.FAILED, stageFailure)
            } catch (_: Exception) {
                if (!terminal.get()) terminate(VncAndroidNetworkPhase.FAILED, stageFailure)
            }
        }

        private fun resolve(): List<VncIpAddress> {
            ensureRunning()
            val answer = try { resolver.resolve(request.directTargetHost) }
            catch (interrupted: InterruptedException) { throw interrupted }
            catch (_: Exception) { throw NetworkRejected(VncAndroidNetworkFailure.DNS_FAILED) }
            ensureRunning()
            return validateAddresses(answer)
        }

        private fun validateAddresses(value: List<VncIpAddress>): List<VncIpAddress> {
            if (value.isEmpty() || value.size > MAX_DNS_ADDRESSES || value.toSet().size != value.size) {
                throw NetworkRejected(VncAndroidNetworkFailure.DNS_FAILED)
            }
            val allowed = when (scope) {
                VncAndroidNetworkScope.PRODUCTION -> value.all { it.allowedForDirectVnc }
                VncAndroidNetworkScope.OWNED_LOOPBACK_FIXTURE -> value.all { it.isLoopback }
            }
            if (!allowed) throw NetworkRejected(VncAndroidNetworkFailure.TARGET_REJECTED)
            return value.sorted()
        }

        private fun remainingMillis(): Int {
            ensureRunning()
            val remaining = deadlineNanos - System.nanoTime()
            if (remaining <= 0) throw VncNativeFailure("timedOut")
            return TimeUnit.NANOSECONDS.toMillis(remaining).coerceAtLeast(1).coerceAtMost(30_000).toInt()
        }

        private fun ensureRunning() {
            if (!isRunning()) throw InterruptedException()
            if (System.nanoTime() >= deadlineNanos) throw VncNativeFailure("timedOut")
        }

        private fun isRunning() = phase == VncAndroidNetworkPhase.RUNNING && !terminal.get()

        private fun complete(connection: VncAndroidTlsConnection) {
            if (!terminal.compareAndSet(false, true)) {
                connection.close()
                return
            }
            phase = VncAndroidNetworkPhase.READY
            timeout?.cancel(false)
            timeout = null
            tls = null
            val receiver = listener
            listener = null
            if (receiver == null) {
                connection.close()
                return
            }
            try {
                receiver.onReady(connection)
            } catch (_: Exception) {
                connection.close()
            }
        }

        private fun terminate(next: VncAndroidNetworkPhase, failure: VncAndroidNetworkFailure?) {
            if (!terminal.compareAndSet(false, true)) return
            phase = next
            timeout?.cancel(false)
            timeout = null
            task?.cancel(true)
            task = null
            val activeTls = tls
            tls = null
            val activeTcp = tcp
            tcp = null
            try { activeTls?.close() } catch (_: Exception) { /* terminal */ }
            try { activeTcp?.close() } catch (_: Exception) { /* terminal */ }
            val receiver = listener
            listener = null
            if (failure != null && receiver != null) {
                try { receiver.onFailure(failure) } catch (_: Exception) { /* terminal */ }
            }
        }
    }

    private class NetworkRejected(val failure: VncAndroidNetworkFailure) : RuntimeException()

    companion object {
        const val productionAvailable = false
        private const val MAX_DEADLINE_MILLIS = 30_000L
        private const val MAX_DNS_ADDRESSES = 8
    }
}
