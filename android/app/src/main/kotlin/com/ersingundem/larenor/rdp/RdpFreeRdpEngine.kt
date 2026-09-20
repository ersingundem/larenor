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
    val SUPPORTED_ABIS = setOf("arm64-v8a", "x86_64")

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
    fun inspect(host: String, port: Int, username: String): RdpJniSecurity =
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
    var phase = RdpJniPhase.CONNECTING
        private set
    var failureCode: String? = null
        private set
    var pendingFrame: RdpNativeFrame? = null
        private set
    private var lastInputSequence = 0L
    private var lastFrameSequence = 0L
    private var terminal = false

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
        if (terminal) return
        if (phase != RdpJniPhase.CONNECTING) {
            terminate(RdpJniPhase.FAILED, "staleSession")
            return
        }
        when {
            evidence.minimumTlsProtocol !in setOf("TLSv1.2", "TLSv1.3") ->
                terminate(RdpJniPhase.FAILED, "tlsRequired")
            evidence.certificateFingerprint != request.certificateFingerprint ->
                terminate(RdpJniPhase.FAILED, "certificatePinningRequired")
            request.requiresNla && !evidence.nla ->
                terminate(RdpJniPhase.FAILED, "nlaUnavailable")
            else -> {
                phase = RdpJniPhase.ACTIVE
                observer.onSecurity()
            }
        }
    }

    override fun onFrame(frame: RdpNativeFrame) {
        if (terminal) {
            frame.close()
            return
        }
        if (phase != RdpJniPhase.ACTIVE || pendingFrame != null) {
            frame.close()
            terminate(RdpJniPhase.FAILED, "frameBackpressure")
            return
        }
        val display = request.display
        if (frame.width > capabilities.maxWidth || frame.height > capabilities.maxHeight ||
            frame.dpi > capabilities.maxDpi || frame.sequence != lastFrameSequence + 1 ||
            frame.width.toLong() * frame.height > 33_554_432L ||
            !display.dynamicResize && (frame.width != display.width || frame.height != display.height)) {
            frame.close()
            terminate(RdpJniPhase.FAILED, "framebufferUnavailable")
            return
        }
        pendingFrame = frame
        lastFrameSequence = frame.sequence
        phase = RdpJniPhase.AWAITING_FRAME_ACK
        observer.onFrame()
    }

    fun acknowledgeFrame(sequence: Long): Boolean {
        val frame = pendingFrame
        if (terminal || phase != RdpJniPhase.AWAITING_FRAME_ACK || frame?.sequence != sequence) {
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
        frame.close()
        pendingFrame = null
        if (!accepted) {
            terminate(RdpJniPhase.FAILED, "connectionFailed")
            return false
        }
        phase = RdpJniPhase.ACTIVE
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
        return true
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
        !terminal && phase in setOf(RdpJniPhase.ACTIVE, RdpJniPhase.AWAITING_FRAME_ACK) &&
            sequence == lastInputSequence + 1

    override fun onDisconnected() {
        if (!terminal) terminate(RdpJniPhase.FAILED, "connectionFailed")
    }

    override fun close() {
        terminate(RdpJniPhase.CANCELLED, null)
    }

    private fun terminate(next: RdpJniPhase, code: String?) {
        if (terminal) return
        terminal = true
        failureCode = code
        phase = next
        pendingFrame?.close()
        pendingFrame = null
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
