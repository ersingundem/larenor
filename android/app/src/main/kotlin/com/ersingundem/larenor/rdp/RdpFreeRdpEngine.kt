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
    const val ENGINE_REVISION = "freerdp-3.31.1-63b948ca-display-pointer-audio-v3"
    // FreeRDP enforce pins min and max; the reported protocol is therefore exact.
    internal const val TLS_OPTIONS = "seclevel:2,enforce:1.2"
    internal const val TLS_PROTOCOL = "TLSv1.2"
    val SUPPORTED_ABIS = setOf("arm64-v8a", "x86_64")

    internal fun capabilities(): Map<String, Any?> = mapOf(
        "schemaVersion" to 3,
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
            "desktopScaleFactorMin" to 100,
            "desktopScaleFactorMax" to 500,
            "deviceScaleFactors" to listOf(100, 140, 180),
        ),
        // Per-session open still requires the authenticated server-side
        // Unicode input flag before exposing text input to Dart.
        "input" to mapOf(
            "absolutePointer" to true,
            "relativePointerNegotiation" to true,
            "verticalWheel" to true,
            "keyboard" to true,
            "ime" to true,
        ),
        // No remote clipboard callback is exposed to the Client yet.
        "channels" to mapOf(
            "clipboardModes" to listOf("disabled", "clientToRemote"),
            "audio" to true,
            "files" to false,
        ),
    )


    fun verify(identity: RdpFreeRdpIdentity): Boolean =
        identity.version == VERSION &&
            identity.sourceCommit == SOURCE_COMMIT &&
            identity.sourceSha256 == SOURCE_SHA256 &&
            identity.abi in SUPPORTED_ABIS &&
            identity.jniSchema == 3 &&
            identity.enabledChannels.isEmpty()
}

enum class RdpJniPhase { CONNECTING, ACTIVE, AWAITING_FRAME_ACK, CANCELLED, FAILED }
enum class RdpJniChannel { CLIPBOARD, AUDIO, FILES }

enum class RdpRemoteAudioState { PENDING, DEVICE_OPEN, PLAYING, CLOSED, FAILED }

data class RdpRemoteAudioObservation(
    val state: RdpRemoteAudioState,
    val deviceOpen: Boolean,
    val acceptedCount: Long,
    val completedCount: Long,
) {
    init {
        if (acceptedCount !in 0..RdpFreeRdpSession.MAX_REVISION ||
            completedCount !in 0..acceptedCount ||
            deviceOpen != (state == RdpRemoteAudioState.DEVICE_OPEN ||
                state == RdpRemoteAudioState.PLAYING) ||
            state == RdpRemoteAudioState.PENDING &&
            (acceptedCount != 0L || completedCount != 0L) ||
            state == RdpRemoteAudioState.PLAYING && acceptedCount == 0L) {
            failRdp("channelUnavailable")
        }
    }

    internal fun toChannel(requestId: String): Map<String, Any> = mapOf(
        "schemaVersion" to 3,
        "requestId" to requestId,
        "state" to when (state) {
            RdpRemoteAudioState.PENDING -> "pending"
            RdpRemoteAudioState.DEVICE_OPEN -> "deviceOpen"
            RdpRemoteAudioState.PLAYING -> "playing"
            RdpRemoteAudioState.CLOSED -> "closed"
            RdpRemoteAudioState.FAILED -> "failed"
        },
        "deviceOpen" to deviceOpen,
        "acceptedCount" to acceptedCount,
        "completedCount" to completedCount,
    )

    companion object {
        val PENDING = RdpRemoteAudioObservation(
            RdpRemoteAudioState.PENDING, false, 0, 0,
        )
    }
}

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
    data class AbsolutePointer(
        val width: Int,
        val height: Int,
        val x: Double,
        val y: Double,
        val buttons: Int,
    ) : RdpJniInput
    data class RelativePointer(val deltaX: Int, val deltaY: Int, val buttons: Int) : RdpJniInput
    data class VerticalWheel(val delta: Int) : RdpJniInput
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
    val pixels: ByteBuffer,
) : AutoCloseable {
    internal var displayLayoutRevision: Long = 0
        private set
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

    internal fun bindDisplayLayoutRevision(revision: Long) {
        if (displayLayoutRevision != 0L || revision !in 1..MAX_REVISION) {
            failRdp("framebufferUnavailable")
        }
        displayLayoutRevision = revision
    }

    companion object {
        const val MAX_FRAME_BYTES = 64 * 1024 * 1024
        const val MAX_PIXELS = 16_777_216L

        fun take(
            sequence: Long,
            width: Int,
            height: Int,
            stride: Int,
            pixels: ByteBuffer,
        ): RdpNativeFrame {
            val expected = stride.toLong() * height
            if (sequence <= 0 || width !in 640..8192 || height !in 480..8192 ||
                stride != width * 4 || expected !in 1..MAX_FRAME_BYTES.toLong() ||
                !pixels.isDirect || pixels.isReadOnly || pixels.position() != 0 || pixels.remaining().toLong() != expected) {
                runCatching {
                    val wipe = pixels.duplicate()
                    wipe.clear()
                    while (wipe.hasRemaining()) wipe.put(0)
                }
                failRdp("framebufferUnavailable")
            }
            return RdpNativeFrame(sequence, width, height, stride, pixels)
        }

        private const val MAX_REVISION = 9_007_199_254_740_991L
    }
}

interface RdpJniOperation {
    interface Listener {
        fun onSecurity(evidence: RdpJniSecurity)
        fun onRemoteAudio(observation: RdpRemoteAudioObservation) = Unit
        fun onFrame(frame: RdpNativeFrame)
        fun onDisconnected()
    }

    /** Authenticated peer fact, sampled by the packaged operation after connect. */
    val unicodeInputSupported: Boolean get() = false
    /** Authenticated wire eligibility sampled only after connection success. */
    val relativePointerSupported: Boolean get() = false
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
    override fun onRemoteAudio(observation: RdpRemoteAudioObservation) {
        target?.onRemoteAudio(observation)
    }
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
    private data class DisplayLayout(
        val width: Int,
        val height: Int,
        val revision: Long,
    )
    data class DisplayedGeometry internal constructor(
        val frameSequence: Long,
        val width: Int,
        val height: Int,
        val displayLayoutRevision: Long,
    )
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
    @Volatile
    var unicodeInputSupported = false
        private set
    @Volatile
    var relativePointerSupported = false
        private set
    private var lastInputSequence = 0L
    private var lastFrameSequence = 0L
    private var currentLayout = DisplayLayout(request.display.width, request.display.height, 1)
    private var acknowledgedGeometry: DisplayedGeometry? = null
    private var remoteAudioObservation = RdpRemoteAudioObservation.PENDING
    private var terminal = false
    private var acknowledging = false
    private var effectInFlight = false

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
        unicodeInputSupported = capabilities.ime && operation.unicodeInputSupported
        relativePointerSupported = capabilities.relativePointerNegotiation &&
            operation.relativePointerSupported
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

    override fun onRemoteAudio(observation: RdpRemoteAudioObservation) {
        val invalid = synchronized(stateLock) {
            if (terminal || !plan.audio) return
            val previous = remoteAudioObservation
            if (observation == previous) return
            val validState = when (previous.state) {
                RdpRemoteAudioState.PENDING -> observation.state in setOf(
                    RdpRemoteAudioState.DEVICE_OPEN, RdpRemoteAudioState.FAILED,
                )
                RdpRemoteAudioState.DEVICE_OPEN -> observation.state in setOf(
                    RdpRemoteAudioState.PLAYING, RdpRemoteAudioState.CLOSED,
                    RdpRemoteAudioState.FAILED,
                )
                RdpRemoteAudioState.PLAYING -> observation.state in setOf(
                    RdpRemoteAudioState.PLAYING, RdpRemoteAudioState.CLOSED,
                    RdpRemoteAudioState.FAILED,
                )
                RdpRemoteAudioState.CLOSED -> observation.state in setOf(
                    RdpRemoteAudioState.DEVICE_OPEN, RdpRemoteAudioState.FAILED,
                )
                RdpRemoteAudioState.FAILED -> false
            }
            if (!validState || observation.acceptedCount < previous.acceptedCount ||
                observation.completedCount < previous.completedCount ||
                observation.state == RdpRemoteAudioState.PENDING) {
                true
            } else {
                remoteAudioObservation = observation
                false
            }
        }
        if (invalid || observation.state == RdpRemoteAudioState.FAILED) {
            terminate(RdpJniPhase.FAILED, "channelUnavailable")
        }
    }

    fun audioObservation(): RdpRemoteAudioObservation = synchronized(stateLock) {
        if (!plan.audio) failRdp("channelUnavailable")
        if (phase !in setOf(RdpJniPhase.ACTIVE, RdpJniPhase.AWAITING_FRAME_ACK) &&
            remoteAudioObservation.state != RdpRemoteAudioState.FAILED) {
            failRdp("staleSession")
        }
        remoteAudioObservation
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
                    frame.sequence != lastFrameSequence + 1 ||
                    frame.width.toLong() * frame.height > RdpNativeFrame.MAX_PIXELS ||
                    !display.dynamicResize && (frame.width != display.width || frame.height != display.height) ->
                    "framebufferUnavailable"
                else -> {
                    frame.bindDisplayLayoutRevision(currentLayout.revision)
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
            if (accepted) {
                phase = RdpJniPhase.ACTIVE
                acknowledgedGeometry = if (
                    frame.displayLayoutRevision == currentLayout.revision &&
                    frame.width == currentLayout.width && frame.height == currentLayout.height
                ) {
                    DisplayedGeometry(
                        frame.sequence, frame.width, frame.height,
                        frame.displayLayoutRevision,
                    )
                } else {
                    null
                }
            }
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

    fun absolutePointer(
        sequence: Long,
        geometry: DisplayedGeometry,
        x: Double,
        y: Double,
        buttons: Int,
    ): Boolean {
        if (!x.isFinite() || !y.isFinite() || x !in 0.0..1.0 || y !in 0.0..1.0 ||
            buttons !in 0..7) {
            terminate(RdpJniPhase.FAILED, "inputUnavailable")
            return false
        }
        return input(
            sequence, geometry,
            RdpJniInput.AbsolutePointer(geometry.width, geometry.height, x, y, buttons),
            "inputUnavailable",
        )
    }

    fun relativePointer(
        sequence: Long,
        geometry: DisplayedGeometry,
        deltaX: Int,
        deltaY: Int,
        buttons: Int,
    ): Boolean {
        if (!relativePointerSupported || deltaX !in Short.MIN_VALUE..Short.MAX_VALUE ||
            deltaY !in Short.MIN_VALUE..Short.MAX_VALUE || buttons !in 0..7) {
            terminate(RdpJniPhase.FAILED, "inputUnavailable")
            return false
        }
        return input(
            sequence, geometry,
            RdpJniInput.RelativePointer(deltaX, deltaY, buttons),
            "inputUnavailable",
        )
    }

    fun verticalWheel(
        sequence: Long,
        geometry: DisplayedGeometry,
        delta: Int,
    ): Boolean {
        if (delta !in setOf(-120, 120)) {
            terminate(RdpJniPhase.FAILED, "inputUnavailable")
            return false
        }
        return input(
            sequence, geometry, RdpJniInput.VerticalWheel(delta),
            "inputUnavailable",
        )
    }

    fun key(sequence: Long, physicalKey: Long, down: Boolean): Boolean {
        // Consumer/system usages remain available to Flutter/Android. They do
        // not corrupt the RDP session and consume no ordered input sequence.
        if (!isSupportedUsbKeyboardUsage(physicalKey)) return false
        return input(sequence, null, RdpJniInput.Key(physicalKey, down), "inputUnavailable")
    }

    fun ime(sequence: Long, text: String): Boolean {
        if (!unicodeInputSupported || text.isEmpty() || text.indexOf('\u0000') >= 0) {
            terminate(RdpJniPhase.FAILED, "inputUnavailable")
            return false
        }
        val bytes = text.toByteArray(StandardCharsets.UTF_8)
        if (bytes.size > MAX_IME_BYTES) {
            bytes.fill(0)
            terminate(RdpJniPhase.FAILED, "inputUnavailable")
            return false
        }
        return input(sequence, null, RdpJniInput.Ime(bytes), "inputUnavailable", bytes)
    }

    fun channel(sequence: Long, channel: RdpJniChannel, payload: ByteArray): Boolean {
        val allowed = when (channel) {
            RdpJniChannel.CLIPBOARD -> plan.clipboardMode != RdpClipboardMode.DISABLED
            // rdpsnd and RDPDR are connection-time plugins. They are never
            // represented as arbitrary payload injection through this API.
            RdpJniChannel.AUDIO, RdpJniChannel.FILES -> false
        }
        if (!allowed || payload.isEmpty() || payload.size > MAX_CHANNEL_BYTES) {
            payload.fill(0)
            terminate(RdpJniPhase.FAILED, "channelUnavailable")
            return false
        }
        return input(sequence, null, RdpJniInput.Channel(channel, payload), "channelUnavailable", payload)
    }

    fun resize(sequence: Long, display: RdpNativeDisplay): Boolean {
        if (!capabilities.dynamicResolution ||
            display.width !in 640..capabilities.maxWidth ||
            display.width % 2 != 0 ||
            display.height !in 480..capabilities.maxHeight ||
            display.desktopScaleFactor !in capabilities.desktopScaleFactorMin..capabilities.desktopScaleFactorMax ||
            display.deviceScaleFactor !in capabilities.deviceScaleFactors ||
            display.width.toLong() * display.height > RdpNativeFrame.MAX_PIXELS ||
            display.externalDisplay && !capabilities.externalDisplay ||
            !request.display.dynamicResize ||
            display.dynamicResize != request.display.dynamicResize ||
            display.externalDisplay != request.display.externalDisplay) {
            terminate(RdpJniPhase.FAILED, "displayUnavailable")
            return false
        }
        if (!reserveEffect(sequence, geometry = null, clearGeometry = true, resize = true)) {
            terminate(RdpJniPhase.FAILED, "staleSession")
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
            finishEffect(sequence, accepted = false)
            terminate(RdpJniPhase.FAILED, "displayUnavailable")
            return false
        }
        return finishEffect(sequence, accepted = true) {
            currentLayout = DisplayLayout(display.width, display.height, currentLayout.revision + 1)
            // An ACK may complete while the resize JNI call is in flight and
            // reinstall geometry from the prior layout. Fence it again at the
            // exact layout commit boundary.
            acknowledgedGeometry = null
        }
    }

    private fun input(
        sequence: Long,
        geometry: DisplayedGeometry?,
        event: RdpJniInput,
        rejectionCode: String,
        secret: ByteArray? = null,
    ): Boolean {
        if (!reserveEffect(sequence, geometry)) {
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
            finishEffect(sequence, accepted = false)
            terminate(RdpJniPhase.FAILED, rejectionCode)
            return false
        }
        return finishEffect(sequence, accepted = true)
    }

    private fun reserveEffect(
        sequence: Long,
        geometry: DisplayedGeometry?,
        clearGeometry: Boolean = false,
        resize: Boolean = false,
    ) = synchronized(stateLock) {
        if (terminal || effectInFlight ||
            phase !in setOf(RdpJniPhase.ACTIVE, RdpJniPhase.AWAITING_FRAME_ACK) ||
            sequence != lastInputSequence + 1 ||
            geometry != null && (
                geometry != acknowledgedGeometry ||
                    geometry.displayLayoutRevision != currentLayout.revision ||
                    geometry.width != currentLayout.width ||
                    geometry.height != currentLayout.height
                ) ||
            resize && currentLayout.revision == MAX_REVISION) {
            false
        } else {
            effectInFlight = true
            if (clearGeometry) acknowledgedGeometry = null
            true
        }
    }

    private fun finishEffect(
        sequence: Long,
        accepted: Boolean,
        commit: () -> Unit = {},
    ) = synchronized(stateLock) {
        if (!effectInFlight) return@synchronized false
        effectInFlight = false
        if (terminal || !accepted) return@synchronized false
        commit()
        lastInputSequence = sequence
        true
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
            effectInFlight = false
            failureCode = code
            phase = next
            acknowledging = false
            pendingFrame?.close()
            pendingFrame = null
            acknowledgedGeometry = null
        }
        try { operation.detach() } catch (_: LinkageError) { /* terminal */ } catch (_: Exception) { /* terminal */ }
        try { operation.close() } catch (_: LinkageError) { /* terminal */ } catch (_: Exception) { /* terminal */ }
        observer.onClosed(code)
    }

    companion object {
        const val MAX_IME_BYTES = 4096
        const val MAX_CHANNEL_BYTES = 64 * 1024
        const val MAX_REVISION = 9_007_199_254_740_991L
    }
}

internal fun isSupportedUsbKeyboardUsage(value: Long): Boolean {
    if (value !in 1..0xffffffffL || (value ushr 16).toInt() != 0x07) return false
    val usage = (value and 0xffff).toInt()
    return usage in 0x04..0x65 || usage in 0x67..0x73 || usage in 0xe0..0xe7
}

private fun failRdp(code: String): Nothing = throw RdpNativeFailure(code)
