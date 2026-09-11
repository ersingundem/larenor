package com.ersingundem.larenor.vnc

internal enum class VncDirectTcpPhase {
    RESOLVING,
    CONNECTING,
    REVALIDATING,
    READY,
    CANCELLED,
    TIMED_OUT,
    FAILED,
}

/** Immutable numeric address value. No hostname resolution occurs here. */
internal class VncIpAddress private constructor(private val bytes: ByteArray) : Comparable<VncIpAddress> {
    val allowedForDirectVnc: Boolean
        get() = when (bytes.size) {
            4 -> allowedIpv4(bytes)
            16 -> allowedIpv6(bytes)
            else -> false
        }

    override fun compareTo(other: VncIpAddress): Int {
        if (bytes.size != other.bytes.size) return bytes.size.compareTo(other.bytes.size)
        for (index in bytes.indices) {
            val comparison = (bytes[index].toInt() and 0xff).compareTo(other.bytes[index].toInt() and 0xff)
            if (comparison != 0) return comparison
        }
        return 0
    }

    override fun equals(other: Any?) = other is VncIpAddress && bytes.contentEquals(other.bytes)
    override fun hashCode() = bytes.contentHashCode()
    override fun toString() = "VncIpAddress(<redacted>)"

    companion object {
        fun take(value: ByteArray): VncIpAddress {
            if (value.size != 4 && value.size != 16) throw VncNativeFailure("invalidRequest")
            return VncIpAddress(value.copyOf())
        }

        fun parseLiteral(host: String): VncIpAddress? {
            if (':' in host) return parseIpv6(host)
            val parts = host.split('.')
            if (parts.size != 4 || parts.any { it.isEmpty() || it.any { character -> !character.isDigit() } }) {
                return null
            }
            val values = parts.map { it.toIntOrNull() ?: return null }
            if (values.any { it !in 0..255 }) return null
            return take(ByteArray(4) { values[it].toByte() })
        }

        private fun parseIpv6(host: String): VncIpAddress? {
            if (!Regex("[0-9a-fA-F:]{2,45}").matches(host) || host.count { it == ':' } < 2 || ":::" in host) {
                return null
            }
            val doubleIndex = host.indexOf("::")
            if (doubleIndex >= 0 && host.indexOf("::", doubleIndex + 2) >= 0) return null
            fun groups(text: String): List<Int>? {
                if (text.isEmpty()) return emptyList()
                val pieces = text.split(':')
                if (pieces.any { it.isEmpty() || it.length > 4 }) return null
                return pieces.map { it.toIntOrNull(16) ?: return null }
            }
            val values = if (doubleIndex >= 0) {
                val left = groups(host.substring(0, doubleIndex)) ?: return null
                val right = groups(host.substring(doubleIndex + 2)) ?: return null
                val missing = 8 - left.size - right.size
                if (missing < 1) return null
                left + List(missing) { 0 } + right
            } else {
                groups(host)?.takeIf { it.size == 8 } ?: return null
            }
            if (values.size != 8) return null
            return take(ByteArray(16).also { result ->
                values.forEachIndexed { index, value ->
                    result[index * 2] = (value ushr 8).toByte()
                    result[index * 2 + 1] = value.toByte()
                }
            })
        }

        private fun allowedIpv4(value: ByteArray): Boolean {
            val first = value[0].toInt() and 0xff
            val second = value[1].toInt() and 0xff
            if (first == 0 || first == 127 || first >= 224) return false
            if (first == 169 && second == 254) return false
            return true
        }

        private fun allowedIpv6(value: ByteArray): Boolean {
            val allZero = value.all { it == 0.toByte() }
            val loopback = value.dropLast(1).all { it == 0.toByte() } && value.last() == 1.toByte()
            val first = value[0].toInt() and 0xff
            val second = value[1].toInt() and 0xff
            val linkLocal = first == 0xfe && second and 0xc0 == 0x80
            val multicast = first == 0xff
            val mappedIpv4 = value.take(10).all { it == 0.toByte() } &&
                value[10] == 0xff.toByte() && value[11] == 0xff.toByte()
            if (mappedIpv4) return allowedIpv4(value.copyOfRange(12, 16))
            return !allZero && !loopback && !linkLocal && !multicast
        }
    }
}

internal interface VncDnsLookup {
    interface Listener {
        fun onResolved(addresses: List<VncIpAddress>)
        fun onFailure()
    }

    fun attach(listener: Listener)
    fun start(): Boolean
    fun cancel()
    fun detach()
}

internal interface VncDnsResolver {
    fun create(host: String, deadlineAtMillis: Long): VncDnsLookup
}

internal data class VncDirectTcpTarget(
    val address: VncIpAddress,
    val port: Int,
    /** Always false: this raw VNC path never consumes proxy or environment configuration. */
    val proxyAllowed: Boolean = false,
)

internal interface VncDirectTcpConnection : AutoCloseable {
    val peerAddress: VncIpAddress
}

internal interface VncTcpConnect {
    interface Listener {
        fun onConnected(connection: VncDirectTcpConnection)
        fun onFailure()
    }

    fun attach(listener: Listener)
    fun start(): Boolean
    fun cancel()
    fun detach()
}

internal interface VncDirectTcpConnector {
    fun create(target: VncDirectTcpTarget, deadlineAtMillis: Long): VncTcpConnect
}

/**
 * DNS and direct TCP state machine for a future Android transport. It performs
 * one deterministic connect attempt and re-resolves domains before exposing a
 * ready connection. No credential or RFB byte crosses this boundary.
 */
internal class VncDirectTcpSession(
    request: VncNativeRequest,
    private val resolver: VncDnsResolver,
    private val connector: VncDirectTcpConnector,
    deadlineMillis: Long,
    private val nowMillis: () -> Long = { System.currentTimeMillis() },
) : AutoCloseable {
    var phase = VncDirectTcpPhase.RESOLVING
        private set
    var failureCode: String? = null
        private set

    private val host = request.directTargetHost
    private val port = request.directTargetPort
    private val deadlineAt: Long
    private var generation = 0L
    private var dns: VncDnsLookup? = null
    private var connect: VncTcpConnect? = null
    private var connection: VncDirectTcpConnection? = null
    private var pinnedAddresses: List<VncIpAddress>? = null
    private var chosenAddress: VncIpAddress? = null
    private var armedGeneration: Long? = null
    private var terminated = false

    init {
        if (deadlineMillis !in 1..MAX_DEADLINE_MILLIS) throw VncNativeFailure("invalidRequest")
        val startedAt = nowMillis()
        if (startedAt < 0 || startedAt > Long.MAX_VALUE - deadlineMillis) {
            throw VncNativeFailure("invalidRequest")
        }
        deadlineAt = startedAt + deadlineMillis
        val literal = VncIpAddress.parseLiteral(host)
        if (literal != null) {
            if (!literal.allowedForDirectVnc) {
                terminate(VncDirectTcpPhase.FAILED, "invalidRequest")
            } else {
                pinnedAddresses = listOf(literal)
                startConnect(literal)
            }
        } else {
            startLookup(revalidation = false)
        }
    }

    fun checkDeadline() {
        if (!terminated && phase != VncDirectTcpPhase.READY && deadlineExceeded()) {
            terminate(VncDirectTcpPhase.TIMED_OUT, "timedOut")
        }
    }

    fun setForeground(foreground: Boolean) {
        if (!foreground) terminate(VncDirectTcpPhase.CANCELLED, null)
    }

    override fun close() {
        terminate(VncDirectTcpPhase.CANCELLED, null)
    }

    private fun startLookup(revalidation: Boolean) {
        if (terminated) return
        phase = if (revalidation) VncDirectTcpPhase.REVALIDATING else VncDirectTcpPhase.RESOLVING
        val expectedPhase = phase
        val token = ++generation
        try {
            val operation = resolver.create(host, deadlineAt)
            dns = operation
            operation.attach(object : VncDnsLookup.Listener {
                override fun onResolved(addresses: List<VncIpAddress>) {
                    resolved(token, expectedPhase, addresses)
                }

                override fun onFailure() {
                    lookupFailed(token, expectedPhase)
                }
            })
            if (!terminated) {
                armedGeneration = token
                if (!operation.start()) terminate(VncDirectTcpPhase.FAILED, "connectionFailed")
            }
        } catch (_: Exception) {
            terminate(VncDirectTcpPhase.FAILED, "connectionFailed")
        }
    }

    private fun resolved(token: Long, expectedPhase: VncDirectTcpPhase, addresses: List<VncIpAddress>) {
        if (terminated || token != generation || phase != expectedPhase) return
        if (armedGeneration != token) {
            terminate(VncDirectTcpPhase.FAILED, "staleSession")
            return
        }
        if (deadlineExceeded()) {
            terminate(VncDirectTcpPhase.TIMED_OUT, "timedOut")
            return
        }
        finishDns()
        val normalized = normalize(addresses) ?: run {
            terminate(VncDirectTcpPhase.FAILED, "connectionFailed")
            return
        }
        if (expectedPhase == VncDirectTcpPhase.RESOLVING) {
            pinnedAddresses = normalized
            startConnect(normalized.first())
        } else {
            val pinned = pinnedAddresses
            val peer = connection?.peerAddress
            if (pinned == null || peer == null || normalized != pinned || peer !in pinned) {
                terminate(VncDirectTcpPhase.FAILED, "connectionFailed")
            } else {
                phase = VncDirectTcpPhase.READY
            }
        }
    }

    private fun lookupFailed(token: Long, expectedPhase: VncDirectTcpPhase) {
        if (terminated || token != generation || phase != expectedPhase) return
        if (armedGeneration != token) {
            terminate(VncDirectTcpPhase.FAILED, "staleSession")
            return
        }
        val timedOut = deadlineExceeded()
        terminate(
            if (timedOut) VncDirectTcpPhase.TIMED_OUT else VncDirectTcpPhase.FAILED,
            if (timedOut) "timedOut" else "connectionFailed",
        )
    }

    private fun startConnect(address: VncIpAddress) {
        if (terminated) return
        phase = VncDirectTcpPhase.CONNECTING
        chosenAddress = address
        val token = ++generation
        try {
            val operation = connector.create(VncDirectTcpTarget(address, port), deadlineAt)
            connect = operation
            operation.attach(object : VncTcpConnect.Listener {
                override fun onConnected(connection: VncDirectTcpConnection) {
                    connected(token, connection)
                }

                override fun onFailure() {
                    connectFailed(token)
                }
            })
            if (!terminated) {
                armedGeneration = token
                if (!operation.start()) terminate(VncDirectTcpPhase.FAILED, "connectionFailed")
            }
        } catch (_: Exception) {
            terminate(VncDirectTcpPhase.FAILED, "connectionFailed")
        }
    }

    private fun connected(token: Long, accepted: VncDirectTcpConnection) {
        if (terminated || token != generation || phase != VncDirectTcpPhase.CONNECTING) {
            safeClose(accepted)
            return
        }
        if (armedGeneration != token) {
            safeClose(accepted)
            terminate(VncDirectTcpPhase.FAILED, "staleSession")
            return
        }
        if (deadlineExceeded()) {
            safeClose(accepted)
            terminate(VncDirectTcpPhase.TIMED_OUT, "timedOut")
            return
        }
        finishConnect()
        if (accepted.peerAddress != chosenAddress || accepted.peerAddress !in pinnedAddresses.orEmpty()) {
            safeClose(accepted)
            terminate(VncDirectTcpPhase.FAILED, "connectionFailed")
            return
        }
        connection = accepted
        if (VncIpAddress.parseLiteral(host) != null) {
            phase = VncDirectTcpPhase.READY
        } else {
            startLookup(revalidation = true)
        }
    }

    private fun connectFailed(token: Long) {
        if (terminated || token != generation || phase != VncDirectTcpPhase.CONNECTING) return
        if (armedGeneration != token) {
            terminate(VncDirectTcpPhase.FAILED, "staleSession")
            return
        }
        val timedOut = deadlineExceeded()
        terminate(
            if (timedOut) VncDirectTcpPhase.TIMED_OUT else VncDirectTcpPhase.FAILED,
            if (timedOut) "timedOut" else "connectionFailed",
        )
    }

    private fun normalize(addresses: List<VncIpAddress>): List<VncIpAddress>? {
        if (addresses.isEmpty() || addresses.size > MAX_DNS_ADDRESSES ||
            addresses.toSet().size != addresses.size || addresses.any { !it.allowedForDirectVnc }
        ) return null
        return addresses.sorted()
    }

    private fun deadlineExceeded() = nowMillis() > deadlineAt

    private fun finishDns() {
        val operation = dns
        dns = null
        armedGeneration = null
        try {
            operation?.detach()
        } catch (_: Exception) {
            // A completed operation is never restarted.
        }
    }

    private fun finishConnect() {
        val operation = connect
        connect = null
        armedGeneration = null
        try {
            operation?.detach()
        } catch (_: Exception) {
            // A completed operation is never restarted.
        }
    }

    private fun terminate(next: VncDirectTcpPhase, code: String?) {
        if (terminated) return
        terminated = true
        armedGeneration = null
        phase = next
        failureCode = code
        val activeDns = dns
        dns = null
        val activeConnect = connect
        connect = null
        val activeConnection = connection
        connection = null
        try { activeDns?.detach() } catch (_: Exception) {
            // Terminal cleanup is best effort and never retried.
        }
        try { activeDns?.cancel() } catch (_: Exception) {
            // Terminal cleanup is best effort and never retried.
        }
        try { activeConnect?.detach() } catch (_: Exception) {
            // Terminal cleanup is best effort and never retried.
        }
        try { activeConnect?.cancel() } catch (_: Exception) {
            // Terminal cleanup is best effort and never retried.
        }
        safeClose(activeConnection)
    }

    private fun safeClose(value: VncDirectTcpConnection?) {
        try {
            value?.close()
        } catch (_: Exception) {
            // Terminal cleanup is best effort and never retried.
        }
    }

    companion object {
        const val productionAvailable = false
        private const val MAX_DEADLINE_MILLIS = 30_000L
        private const val MAX_DNS_ADDRESSES = 8
    }
}
