package com.ersingundem.larenor.rdp

import java.nio.ByteBuffer
import java.nio.charset.StandardCharsets

data class RdpFreeRdpIdentity(
    val version: String,
    val sourceCommit: String,
    val sourceSha256: String,
    val abi: String,
    val jniSchema: Int,
    /** Channels enabled without an explicit per-session request. Must stay empty. */
    val enabledChannels: Set<String>,
)

/** Immutable review boundary for the FreeRDP source consumed by the Android package job. */
object RdpFreeRdpPackage {
    const val VERSION = "3.31.1"
    const val SOURCE_COMMIT = "63b948ca5cb94307fd5444ee6e73927a41ccdab4"
    const val SOURCE_SHA256 = "4a2629026896cb4e26fb8ed2d6ca6aa4ab89ca95528dfbae2550c2f6bc866991"
    const val ENGINE_REVISION = "freerdp-3.31.1-63b948ca"
    // FreeRDP enforce pins min and max; the reported protocol is therefore exact.
    internal const val TLS_OPTIONS = "seclevel:2,enforce:1.2"
    internal const val TLS_PROTOCOL = "TLSv1.2"
    val SUPPORTED_ABIS = setOf("arm64-v8a", "x86_64")

    internal fun capabilities(): Map<String, Any?> = mapOf(
        "schemaVersion" to 1,
        "availability" to "available",
        "engineRevision" to RdpFreeRdpPackage.ENGINE_REVISION,
        "security" to mapOf(
            "tls" to true,
            "certificatePinning" to true,
            "nla" to true,
            // A separate gateway SPKI is not yet represented by the Client contract.
            "rdGateway" to false,
        ),
        "display" to mapOf(
            "dynamicResolution" to true,
            "externalDisplay" to true,
            "maxWidth" to 8192,
            "maxHeight" to 8192,
            "maxDpi" to 640,
        ),
        // Unicode local setting alone does not prove the server input flag.
        "input" to mapOf("pointer" to true, "keyboard" to true, "ime" to false),
        // No remote clipboard callback is exposed to the Client yet.
        "channels" to mapOf(
            "clipboardModes" to listOf("disabled", "clientToRemote"),
            "audio" to false,
            "files" to false,
        ),
    )


    fun verify(identity: RdpFreeRdpIdentity): Boolean =
        identity.version == VERSION &&
            identity.sourceCommit == SOURCE_COMMIT &&
            identity.sourceSha256 == SOURCE_SHA256 &&
            identity.abi in SUPPORTED_ABIS &&
            identity.jniSchema == 1 &&
            identity.enabledChannels.isEmpty()
}

enum class RdpJniPhase { CONNECTING, ACTIVE, AWAITING_FRAME_ACK, CANCELLED, FAILED }
enum class RdpJniChannel { CLIPBOARD, AUDIO, FILES }

data class RdpJniSecurity(
    val minimumTlsProtocol: String,
    val nla: Boolean,
    val certificateFingerprint: String,
)

/** An aborted certificate probe records policy and a presented pin, never login success. */
data class RdpJniCertificateProbe(
    val minimumTlsPolicy: String,
    val clientRequiresNla: Boolean,
    val certificateFingerprint: String,
)

/** A certificate match alone never authorizes input or framebuffer publication. */
internal class RdpAuthenticatedOutputGate(private val expectedPin: String) {
    private var pin: String? = null
    private var authenticated = false
    private var delivered = false
    private var closed = false

    @Synchronized fun certificate(candidate: String?): Boolean {
        if (closed) return false
        if (authenticated || candidate != expectedPin) {
            close()
            return false
        }
        pin = candidate
        return true
    }

    /** Called only by the native successful-connection callback after NLA. */
    @Synchronized fun connectionSucceeded(): RdpJniSecurity? {
        if (closed || authenticated || pin == null) return null
        authenticated = true
        return RdpJniSecurity(RdpFreeRdpPackage.TLS_PROTOCOL, true, requireNotNull(pin))
    }

    @Synchronized fun securityDelivered(): Boolean {
        if (closed || !authenticated || delivered) return false
        delivered = true
        return true
    }

    @Synchronized fun canDeliverFrames(): Boolean = !closed && authenticated && delivered

    @Synchronized fun close() {
        closed = true
        pin = null
    }
}

sealed interface RdpJniInput {
    data class Pointer(val x: Double, val y: Double, val buttons: Int) : RdpJniInput
    data class Key(val physicalKey: Long, val down: Boolean) : RdpJniInput
    class Ime internal constructor(internal val utf8: ByteArray) : RdpJniInput {
        override fun toString() = "Ime(<redacted>)"
    }
    class Channel internal constructor(
        val kind: RdpJniChannel,
        internal val payload: ByteArray,
    ) : RdpJniInput {
        override fun toString() = "Channel($kind,<redacted>)"
    }
}

class RdpNativeFrame private constructor(
    val sequence: Long,
    val width: Int,
    val height: Int,
    val stride: Int,
    val dpi: Int,
    val pixels: ByteBuffer,
) : AutoCloseable {
    var closed = false
        private set

    override fun close() {
        if (closed) return
        closed = true
        val writable = pixels.duplicate()
        writable.clear()
        while (writable.hasRemaining()) writable.put(0)
    }

    override fun toString() = "RdpNativeFrame(sequence=$sequence,${width}x$height,<redacted>)"

    companion object {
        const val MAX_FRAME_BYTES = 64 * 1024 * 1024

        fun take(
            sequence: Long,
            width: Int,
            height: Int,
            stride: Int,
            dpi: Int,
            pixels: ByteBuffer,
        ): RdpNativeFrame {
            val expected = stride.toLong() * height
            if (sequence <= 0 || width !in 640..8192 || height !in 480..8192 ||
                dpi !in 72..640 || stride != width * 4 || expected !in 1..MAX_FRAME_BYTES.toLong() ||
                !pixels.isDirect || pixels.isReadOnly || pixels.position() != 0 || pixels.remaining().toLong() != expected) {
                runCatching {
                    val wipe = pixels.duplicate()
                    wipe.clear()
                    while (wipe.hasRemaining()) wipe.put(0)
                }
                failRdp("framebufferUnavailable")
            }
            return RdpNativeFrame(sequence, width, height, stride, dpi, pixels)
        }
    }
}

interface RdpJniOperation {
    interface Listener {
        fun onSecurity(evidence: RdpJniSecurity)
        fun onFrame(frame: RdpNativeFrame)
        fun onDisconnected()
    }

    /** Must synchronously copy the mutable credentials into native-owned memory. */
    fun start(password: CharArray, gatewayPassword: CharArray?): Boolean
    fun input(sequence: Long, event: RdpJniInput): Boolean
    fun resize(sequence: Long, display: RdpNativeDisplay): Boolean
    fun acknowledgeFrame(sequence: Long): Boolean
    /** Called only after the contract has returned to ACTIVE following an ack. */
    fun resumeFrames(): Boolean = true
    fun close()
    fun detach()
}

interface RdpJniRuntime {
    fun identity(): RdpFreeRdpIdentity
    fun capabilities(): Map<String, Any?>
    fun inspect(host: String, port: Int, username: String): RdpJniCertificateProbe =
        failRdp("engineUnavailable")
    fun create(
        request: RdpNativeRequest,
        plan: RdpNativeNegotiated,
        listener: RdpJniOperation.Listener,
    ): RdpJniOperation
}

private class RdpJniListenerProxy : RdpJniOperation.Listener {
    var target: RdpJniOperation.Listener? = null
    override fun onSecurity(evidence: RdpJniSecurity) { target?.onSecurity(evidence) }
    override fun onFrame(frame: RdpNativeFrame) { target?.onFrame(frame) ?: frame.close() }
    override fun onDisconnected() { target?.onDisconnected() }
}

class RdpFreeRdpBackend(private val runtime: RdpJniRuntime?) : RdpNativeBackend {
    private val verifiedCapabilities: RdpNativeCapabilities? by lazy {
        val candidate = runtime
        if (candidate == null) {
            null
        } else try {
            if (!RdpFreeRdpPackage.verify(candidate.identity())) {
                null
            } else RdpNativeCapabilities.parse(candidate.capabilities()).takeIf {
                    it.engineRevision == RdpFreeRdpPackage.ENGINE_REVISION
                }
        } catch (_: LinkageError) {
            null
        } catch (_: Exception) {
            null
        }
    }

    override fun capabilities(): RdpNativeCapabilities =
        verifiedCapabilities ?: UnavailableRdpNativeBackend().capabilities()

    override fun open(
        request: RdpNativeRequest,
        negotiated: RdpNativeNegotiated,
        secrets: RdpNativeSecrets,
        observer: RdpNativeSessionObserver,
    ): RdpNativeSession {
        val candidate = runtime ?: failRdp("engineUnavailable")
        val capabilities = verifiedCapabilities ?: failRdp("engineUnavailable")
        if (negotiated.engineRevision != RdpFreeRdpPackage.ENGINE_REVISION) {
            failRdp("engineUnavailable")
        }
        val proxy = RdpJniListenerProxy()
        val operation = try {
            candidate.create(request, negotiated, proxy)
        } catch (_: LinkageError) {
            failRdp("engineUnavailable")
        } catch (_: Exception) {
            failRdp("connectionFailed")
        }
        val session = RdpFreeRdpSession(request, negotiated, capabilities, operation, observer)
        proxy.target = session
        try {
            session.start(secrets)
        } catch (failure: Exception) {
            session.close()
            throw failure
        }
        return session
    }
}

class RdpFreeRdpSession internal constructor(
    private val request: RdpNativeRequest,
    private val plan: RdpNativeNegotiated,
    private val capabilities: RdpNativeCapabilities,
    private val operation: RdpJniOperation,
    private val observer: RdpNativeSessionObserver = RdpNativeSessionObserver.NONE,
) : RdpNativeSession, RdpJniOperation.Listener {
    private val stateLock = Any()
    @Volatile
    var phase = RdpJniPhase.CONNECTING
        private set
    @Volatile
    var failureCode: String? = null
        private set
    @Volatile
    var pendingFrame: RdpNativeFrame? = null
        private set
    private var lastInputSequence = 0L
    private var lastFrameSequence = 0L
    private var terminal = false
    private var acknowledging = false

    internal fun start(secrets: RdpNativeSecrets) {
        val accepted = try {
            var result = false
            secrets.use { password, gateway -> result = operation.start(password, gateway) }
            result
        } catch (_: Exception) {
            false
        }
        if (!accepted) {
            terminate(RdpJniPhase.FAILED, "connectionFailed")
            failRdp("connectionFailed")
        }
    }

    override fun onSecurity(evidence: RdpJniSecurity) {
        val code = synchronized(stateLock) {
            if (terminal) return
            when {
                phase != RdpJniPhase.CONNECTING -> "staleSession"
                evidence.minimumTlsProtocol !in setOf("TLSv1.2", "TLSv1.3") -> "tlsRequired"
                evidence.certificateFingerprint != request.certificateFingerprint -> "certificatePinningRequired"
                request.requiresNla && !evidence.nla -> "nlaUnavailable"
                else -> {
                    phase = RdpJniPhase.ACTIVE
                    null
                }
            }
        }
        if (code != null) terminate(RdpJniPhase.FAILED, code) else observer.onSecurity()
    }

    override fun onFrame(frame: RdpNativeFrame) {
        val code = synchronized(stateLock) {
            if (terminal) {
                frame.close()
                return
            }
            val display = request.display
            when {
                phase != RdpJniPhase.ACTIVE || pendingFrame != null -> "frameBackpressure"
                frame.width > capabilities.maxWidth || frame.height > capabilities.maxHeight ||
                    frame.dpi > capabilities.maxDpi || frame.sequence != lastFrameSequence + 1 ||
                    frame.width.toLong() * frame.height > 33_554_432L ||
                    !display.dynamicResize && (frame.width != display.width || frame.height != display.height) ->
                    "framebufferUnavailable"
                else -> {
                    pendingFrame = frame
                    lastFrameSequence = frame.sequence
                    phase = RdpJniPhase.AWAITING_FRAME_ACK
                    null
                }
            }
        }
        if (code != null) {
            frame.close()
            terminate(RdpJniPhase.FAILED, code)
            return
        }
        observer.onFrame()
    }

    fun acknowledgeFrame(sequence: Long): Boolean {
        val frame = synchronized(stateLock) {
            if (terminal || phase != RdpJniPhase.AWAITING_FRAME_ACK ||
                pendingFrame?.sequence != sequence || acknowledging) null
            else pendingFrame.also { acknowledging = true }
        }
        if (frame == null) {
            terminate(RdpJniPhase.FAILED, "staleSession")
            return false
        }
        val accepted = try {
            operation.acknowledgeFrame(sequence)
        } catch (_: LinkageError) {
            false
        } catch (_: Exception) {
            false
        }
        synchronized(stateLock) {
            // Native ACK can race disconnect/retirement. Do not resurrect a
            // terminal session or resume its graphics after that boundary.
            if (terminal) return false
            acknowledging = false
            frame.close()
            pendingFrame = null
            if (accepted) phase = RdpJniPhase.ACTIVE
        }
        if (!accepted) {
            terminate(RdpJniPhase.FAILED, "connectionFailed")
            return false
        }
        val resumed = try {
            operation.resumeFrames()
        } catch (_: LinkageError) {
            false
        } catch (_: Exception) {
            false
        }
        if (!resumed) {
            terminate(RdpJniPhase.FAILED, "connectionFailed")
            return false
        }
        return synchronized(stateLock) { !terminal }
    }

    fun pointer(sequence: Long, x: Double, y: Double, buttons: Int): Boolean {
        if (!x.isFinite() || !y.isFinite() || x !in 0.0..1.0 || y !in 0.0..1.0 || buttons !in 0..31) {
            terminate(RdpJniPhase.FAILED, "inputUnavailable")
            return false
        }
        return input(sequence, RdpJniInput.Pointer(x, y, buttons))
    }

    fun key(sequence: Long, physicalKey: Long, down: Boolean): Boolean {
        if (physicalKey !in 1..0xffffffffL) {
            terminate(RdpJniPhase.FAILED, "inputUnavailable")
            return false
        }
        return input(sequence, RdpJniInput.Key(physicalKey, down))
    }

    fun ime(sequence: Long, text: String): Boolean {
        if (!capabilities.ime || text.isEmpty() || text.indexOf('\u0000') >= 0) {
            terminate(RdpJniPhase.FAILED, "inputUnavailable")
            return false
        }
        val bytes = text.toByteArray(StandardCharsets.UTF_8)
        if (bytes.size > MAX_IME_BYTES) {
            bytes.fill(0)
            terminate(RdpJniPhase.FAILED, "inputUnavailable")
            return false
        }
        return input(sequence, RdpJniInput.Ime(bytes), bytes)
    }

    fun channel(sequence: Long, channel: RdpJniChannel, payload: ByteArray): Boolean {
        val allowed = when (channel) {
            RdpJniChannel.CLIPBOARD -> plan.clipboardMode != RdpClipboardMode.DISABLED
            RdpJniChannel.AUDIO -> plan.audio
            RdpJniChannel.FILES -> plan.files
        }
        if (!allowed || payload.isEmpty() || payload.size > MAX_CHANNEL_BYTES) {
            payload.fill(0)
            terminate(RdpJniPhase.FAILED, "channelUnavailable")
            return false
        }
        return input(sequence, RdpJniInput.Channel(channel, payload), payload)
    }

    fun resize(sequence: Long, display: RdpNativeDisplay): Boolean {
        if (!readyForInput(sequence)) {
            terminate(RdpJniPhase.FAILED, "staleSession")
            return false
        }
        if (!capabilities.dynamicResolution ||
            display.width !in 640..capabilities.maxWidth ||
            display.height !in 480..capabilities.maxHeight ||
            display.dpi !in 72..capabilities.maxDpi ||
            display.width.toLong() * display.height > 33_554_432L ||
            display.externalDisplay && !capabilities.externalDisplay) {
            terminate(RdpJniPhase.FAILED, "displayUnavailable")
            return false
        }
        val accepted = try {
            operation.resize(sequence, display)
        } catch (_: LinkageError) {
            false
        } catch (_: Exception) {
            false
        }
        if (!accepted) {
            terminate(RdpJniPhase.FAILED, "busy")
            return false
        }
        lastInputSequence = sequence
        return true
    }

    private fun input(sequence: Long, event: RdpJniInput, secret: ByteArray? = null): Boolean {
        if (!readyForInput(sequence)) {
            secret?.fill(0)
            terminate(RdpJniPhase.FAILED, "staleSession")
            return false
        }
        val accepted = try {
            operation.input(sequence, event)
        } catch (_: LinkageError) {
            false
        } catch (_: Exception) {
            false
        } finally {
            secret?.fill(0)
        }
        if (!accepted) {
            terminate(RdpJniPhase.FAILED, "busy")
            return false
        }
        lastInputSequence = sequence
        return true
    }

    private fun readyForInput(sequence: Long) =
        synchronized(stateLock) {
            !terminal && phase in setOf(RdpJniPhase.ACTIVE, RdpJniPhase.AWAITING_FRAME_ACK) &&
                sequence == lastInputSequence + 1
        }

    override fun onDisconnected() {
        terminate(RdpJniPhase.FAILED, "connectionFailed")
    }

    override fun close() {
        terminate(RdpJniPhase.CANCELLED, null)
    }

    private fun terminate(next: RdpJniPhase, code: String?) {
        synchronized(stateLock) {
            if (terminal) return
            terminal = true
            failureCode = code
            phase = next
            acknowledging = false
            pendingFrame?.close()
            pendingFrame = null
        }
        try { operation.detach() } catch (_: LinkageError) { /* terminal */ } catch (_: Exception) { /* terminal */ }
        try { operation.close() } catch (_: LinkageError) { /* terminal */ } catch (_: Exception) { /* terminal */ }
        observer.onClosed(code)
    }

    companion object {
        const val MAX_IME_BYTES = 4096
        const val MAX_CHANNEL_BYTES = 64 * 1024
    }
}

private fun failRdp(code: String): Nothing = throw RdpNativeFailure(code)
