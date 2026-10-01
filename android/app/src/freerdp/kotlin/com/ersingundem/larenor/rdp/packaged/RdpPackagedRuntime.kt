package com.ersingundem.larenor.rdp.packaged

import android.content.Context
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import android.util.Base64
import android.view.KeyEvent
import com.ersingundem.larenor.rdp.RdpAuthenticatedOutputGate
import com.ersingundem.larenor.rdp.RdpClipboardMode
import com.ersingundem.larenor.rdp.RdpFreeRdpIdentity
import com.ersingundem.larenor.rdp.RdpFreeRdpPackage
import com.ersingundem.larenor.rdp.RdpFrameDeliveryGate
import com.ersingundem.larenor.rdp.RdpJniInput
import com.ersingundem.larenor.rdp.RdpJniOperation
import com.ersingundem.larenor.rdp.RdpJniRuntime
import com.ersingundem.larenor.rdp.RdpJniCertificateProbe
import com.ersingundem.larenor.rdp.RdpNativeDisplay
import com.ersingundem.larenor.rdp.RdpNativeFailure
import com.ersingundem.larenor.rdp.RdpNativeFrame
import com.ersingundem.larenor.rdp.RdpNativeNegotiated
import com.ersingundem.larenor.rdp.RdpNativeRequest
import com.freerdp.freerdpcore.application.GlobalApp
import com.freerdp.freerdpcore.application.SessionState
import com.freerdp.freerdpcore.services.LibFreeRDP
import java.io.ByteArrayInputStream
import java.lang.reflect.Modifier
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.security.cert.CertificateFactory
import java.util.Collections
import java.util.HashMap
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/** Compiled only when the exact receipted FreeRDP AAR is present. */
class RdpPackagedRuntime(context: Context) : RdpJniRuntime {
    private val appContext = context.applicationContext

    init {
        FreeRdpRegistry.install()
        requireExactSymbols()
    }

    override fun identity() = RdpFreeRdpIdentity(
        version = LibFreeRDP.getVersion(),
        sourceCommit = RdpFreeRdpPackage.SOURCE_COMMIT,
        sourceSha256 = RdpFreeRdpPackage.SOURCE_SHA256,
        abi = Build.SUPPORTED_ABIS.firstOrNull { it in RdpFreeRdpPackage.SUPPORTED_ABIS }.orEmpty(),
        jniSchema = 1,
        enabledChannels = emptySet(),
    )

    override fun capabilities(): Map<String, Any?> = RdpFreeRdpPackage.capabilities()

    override fun inspect(host: String, port: Int, username: String): RdpJniCertificateProbe {
        val probe = FreeRdpProbe(appContext, host, port, username)
        return try {
            probe.run()
        } finally {
            probe.close()
        }
    }

    override fun create(
        request: RdpNativeRequest,
        plan: RdpNativeNegotiated,
        listener: RdpJniOperation.Listener,
    ): RdpJniOperation = FreeRdpOperation(appContext, request, plan, listener)

    private fun requireExactSymbols() {
        if (LibFreeRDP.getVersion() != RdpFreeRdpPackage.VERSION) unavailable()
        val required = mapOf(
            "newInstance" to 1,
            "freeInstance" to 1,
            "connect" to 1,
            "disconnect" to 1,
            "cancelConnection" to 1,
            "setConnectionInfo" to 3,
            "updateGraphics" to 6,
            "sendCursorEvent" to 4,
            "sendKeyEvent" to 3,
            "sendUnicodeKeyEvent" to 3,
            "sendClipboardData" to 2,
            "sendMonitorLayout" to 3,
        )
        val publicStatic = LibFreeRDP::class.java.declaredMethods.filter {
            Modifier.isPublic(it.modifiers) && Modifier.isStatic(it.modifiers)
        }
        if (required.any { (name, arity) -> publicStatic.none { it.name == name && it.parameterCount == arity } }) {
            unavailable()
        }
    }
}

private object FreeRdpRegistry : LibFreeRDP.EventListener {
    private val installed = AtomicBoolean(false)
    private val operations = ConcurrentHashMap<Long, FreeRdpConnection>()
    private val cleanup = Executors.newCachedThreadPool { runnable ->
        Thread(runnable, "larenor-rdp-cleanup").apply { isDaemon = true }
    }

    fun install() {
        if (installed.compareAndSet(false, true)) {
            val field = GlobalApp::class.java.getDeclaredField("sessionMap")
            field.isAccessible = true
            if (field.get(null) == null) {
                field.set(null, Collections.synchronizedMap(HashMap<Long, SessionState>()))
            }
            LibFreeRDP.setEventListener(this)
        }
    }

    fun attach(instance: Long, operation: FreeRdpConnection) {
        if (operations.putIfAbsent(instance, operation) != null) unavailable()
    }
    fun detach(instance: Long) { operations.remove(instance) }
    fun release(instance: Long) {
        detach(instance)
        runCatching { LibFreeRDP.cancelConnection(instance) }
        cleanup.execute { runCatching { GlobalApp.freeSession(instance) } }
    }
    override fun OnPreConnect(instance: Long) = Unit
    override fun OnConnectionSuccess(instance: Long) { operations[instance]?.connected() }
    override fun OnConnectionFailure(instance: Long) { operations[instance]?.failed() }
    override fun OnDisconnecting(instance: Long) = Unit
    override fun OnDisconnected(instance: Long) { operations[instance]?.disconnected() }
}

private interface FreeRdpConnection {
    fun connected()
    fun failed()
    fun disconnected()
}

private abstract class BaseConnection(
    protected val context: Context,
    protected val host: String,
    protected val port: Int,
    protected val username: String,
) : LibFreeRDP.UIEventListener, FreeRdpConnection, AutoCloseable {
    protected val terminal = AtomicBoolean(false)
    private val closed = AtomicBoolean(false)
    protected val finished = CountDownLatch(1)
    protected var session: SessionState? = null
    protected var instance = 0L

    protected fun create(uri: Uri) {
        val made = GlobalApp.createSession(uri, context)
        session = made
        instance = made.instance
        made.uiEventListener = this
        FreeRdpRegistry.attach(instance, this)
        if (!LibFreeRDP.setConnectionInfo(context, instance, uri)) {
            close()
            unavailable()
        }
    }

    protected fun connect() {
        if (session == null || instance == 0L || !LibFreeRDP.connect(instance)) unavailable()
    }

    protected fun await(seconds: Long): Boolean =
        finished.await(seconds, TimeUnit.SECONDS) && !terminal.get()

    override open fun close() {
        if (!closed.compareAndSet(false, true)) return
        terminal.set(true)
        val value = instance
        if (value != 0L) {
            FreeRdpRegistry.release(value)
        }
        session?.uiEventListener = null
        session = null
        finished.countDown()
    }

    override fun connected() { finished.countDown() }
    override open fun failed() { terminal.set(true); finished.countDown() }
    override open fun disconnected() { terminal.set(true); finished.countDown() }
    override open fun OnSettingsChanged(width: Int, height: Int, bpp: Int) = Unit
    override fun OnGatewayAuthenticate(username: StringBuilder, domain: StringBuilder, password: StringBuilder) = false
    override fun OnExperimentalFeature(feature: Int) = false
    override open fun OnGraphicsUpdate(x: Int, y: Int, width: Int, height: Int) = Unit
    override open fun OnGraphicsResize(width: Int, height: Int, bpp: Int) = Unit
    override fun OnRemoteClipboardChanged(data: String?) = Unit
    override fun OnRemoteClipboardImageChanged(data: ByteArray?) = Unit
    override fun OnPointerSet(pixels: IntArray?, width: Int, height: Int, hotX: Int, hotY: Int) = Unit
    override fun OnPointerSetNull() = Unit
    override fun OnPointerSetDefault() = Unit
    override fun OnRailWindowUpdate(windowId: Long, width: Int, height: Int, pixels: IntArray?) = Unit
    override fun OnRailWindowMove(windowId: Long, x: Int, y: Int, w: Int, h: Int) = Unit
    override fun OnRailWindowHide(windowId: Long) = Unit
    override fun OnRailWindowDestroy(windowId: Long) = Unit
    override fun OnRailSessionEnd() = Unit
    override fun OnRailMonitoredDesktop(windowIds: LongArray?, activeWindowId: Long) = Unit

    protected fun baseUri(width: Int, height: Int, clipboard: Boolean): Uri {
        return packagedConnectionUri(host, port, username, width, height, clipboard)
    }

    protected fun pinFromPem(fingerprint: String, flags: Long): String? {
        if (flags and LibFreeRDP.VERIFY_CERT_FLAG_FP_IS_PEM == 0L || fingerprint.length > 64 * 1024) return null
        return try {
            val cert = CertificateFactory.getInstance("X.509")
                .generateCertificate(ByteArrayInputStream(fingerprint.toByteArray(StandardCharsets.US_ASCII)))
            "SHA256:" + Base64.encodeToString(
                MessageDigest.getInstance("SHA-256").digest(cert.publicKey.encoded),
                Base64.NO_WRAP or Base64.NO_PADDING,
            )
        } catch (_: Exception) { null }
    }
}

private class FreeRdpProbe(
    context: Context,
    host: String,
    port: Int,
    username: String,
) : BaseConnection(context, host, port, username) {
    @Volatile private var evidence: RdpJniCertificateProbe? = null
    private val failure = AtomicReference<RdpProbeOutcome?>(null)

    fun run(): RdpJniCertificateProbe {
        create(baseUri(640, 480, false))
        connect()
        if (!finished.await(20, TimeUnit.SECONDS)) {
            probeFailure(RdpProbeOutcome.TIMEOUT)
        }
        evidence?.let { return it }
        probeFailure(
            failure.get() ?: RdpProbeOutcome.CERTIFICATE_CALLBACK_MISSING_PEM,
        )
    }

    override fun OnAuthenticate(username: StringBuilder, domain: StringBuilder, password: StringBuilder) = false
    override fun OnVerifiyCertificateEx(
        host: String, port: Long, commonName: String, subject: String, issuer: String,
        fingerprint: String, flags: Long,
    ): Int {
        if (host != this.host || port != this.port.toLong()) {
            failProbe(RdpProbeOutcome.CERTIFICATE_PARSE_FAILED)
            return 0
        }
        if (flags and LibFreeRDP.VERIFY_CERT_FLAG_FP_IS_PEM == 0L) {
            failProbe(RdpProbeOutcome.CERTIFICATE_CALLBACK_MISSING_PEM)
            return 0
        }
        val pin = pinFromPem(fingerprint, flags)
        if (pin == null) {
            failProbe(RdpProbeOutcome.CERTIFICATE_PARSE_FAILED)
            return 0
        }
        // The callback is deliberately rejected below, before credentials or
        // a live session. These values describe the enforced client policy.
        evidence = RdpJniCertificateProbe(RdpFreeRdpPackage.TLS_PROTOCOL, true, pin)
        finished.countDown()
        return 0
    }
    override fun OnVerifyChangedCertificateEx(
        host: String, port: Long, commonName: String, subject: String, issuer: String,
        fingerprint: String, oldSubject: String, oldIssuer: String, oldFingerprint: String, flags: Long,
    ) = OnVerifiyCertificateEx(host, port, commonName, subject, issuer, fingerprint, flags)

    override fun failed() {
        failProbe(RdpProbeOutcome.CONNECTION_FAILURE_BEFORE_CERTIFICATE)
        super.failed()
    }

    override fun disconnected() {
        failProbe(RdpProbeOutcome.CONNECTION_FAILURE_BEFORE_CERTIFICATE)
        super.disconnected()
    }

    private fun failProbe(outcome: RdpProbeOutcome) {
        if (evidence == null) failure.compareAndSet(null, outcome)
        finished.countDown()
    }
}

private enum class RdpProbeOutcome(
    val wireValue: String,
) {
    TIMEOUT("timeout"),
    CONNECTION_FAILURE_BEFORE_CERTIFICATE("connectionFailureBeforeCertificate"),
    CERTIFICATE_CALLBACK_MISSING_PEM("certificateCallbackMissingPem"),
    CERTIFICATE_PARSE_FAILED("certificateParseFailed"),
}

/**
 * Private cause consumed only by the bounded hosted-acceptance diagnostic.
 *
 * The public bridge still catches the enclosing [RdpNativeFailure] and returns
 * only its existing safe code. No host, certificate, exception message or
 * platform stack is added to the production response.
 */
private class RdpProbeDiagnostic(
    private val outcome: RdpProbeOutcome,
) : RuntimeException(null, null, false, false) {
    override fun toString() = "RdpProbeOutcome(${outcome.wireValue})"
}

private fun probeFailure(outcome: RdpProbeOutcome): Nothing {
    val public = RdpNativeFailure("engineUnavailable")
    public.initCause(RdpProbeDiagnostic(outcome))
    throw public
}

private class FreeRdpOperation(
    context: Context,
    private val request: RdpNativeRequest,
    private val plan: RdpNativeNegotiated,
    private var listener: RdpJniOperation.Listener?,
) : BaseConnection(context, request.targetHost, request.targetPort, request.username), RdpJniOperation {
    private var password: CharArray? = null
    private var gatewayPassword: CharArray? = null
    private var bitmap: Bitmap? = null
    private val securityGate = RdpAuthenticatedOutputGate(request.certificateFingerprint)
    private var graphicsUpdated = false
    private val securityPublished = CountDownLatch(1)
    private var lastButtons = 0
    private val frameDelivery = RdpFrameDeliveryGate()

    override fun start(password: CharArray, gatewayPassword: CharArray?): Boolean {
        if (request.gateway != null) return false
        this.password = password.copyOf()
        this.gatewayPassword = gatewayPassword?.copyOf()
        return try {
            create(baseUri(request.display.width, request.display.height, plan.clipboardMode != RdpClipboardMode.DISABLED))
            connect()
            await(45) && securityPublished.await(5, TimeUnit.SECONDS) &&
                !terminal.get() && securityGate.canDeliverFrames()
        } finally {
            this.password?.fill('\u0000'); this.password = null
            this.gatewayPassword?.fill('\u0000'); this.gatewayPassword = null
        }
    }

    override fun OnAuthenticate(username: StringBuilder, domain: StringBuilder, password: StringBuilder): Boolean {
        val secret = this.password ?: return false
        username.setLength(0); username.append(request.username)
        domain.setLength(0); domain.append(request.domain)
        password.setLength(0); password.append(secret)
        return true
    }

    override fun OnVerifiyCertificateEx(
        host: String, port: Long, commonName: String, subject: String, issuer: String,
        fingerprint: String, flags: Long,
    ): Int {
        if (host != request.targetHost || port != request.targetPort.toLong()) return 0
        val pin = pinFromPem(fingerprint, flags) ?: return 0
        // This callback precedes CredSSP authentication. Keep only the accepted
        // pin here; OnConnectionSuccess is the authority for a live session.
        return if (securityGate.certificate(pin)) 1 else 0
    }

    override fun OnVerifyChangedCertificateEx(
        host: String, port: Long, commonName: String, subject: String, issuer: String,
        fingerprint: String, oldSubject: String, oldIssuer: String, oldFingerprint: String, flags: Long,
    ) = OnVerifiyCertificateEx(host, port, commonName, subject, issuer, fingerprint, flags)

    @Synchronized override fun connected() {
        if (terminal.get()) return
        val evidence = securityGate.connectionSucceeded() ?: return
        val consumer = listener ?: return
        consumer.onSecurity(evidence)
        // The consumer may retire the operation while handling security.
        if (!terminal.get() && securityGate.securityDelivered()) {
            securityPublished.countDown()
            if (graphicsUpdated) bitmap?.let { emitFrame(it) }
        }
        super.connected()
    }

    override fun OnSettingsChanged(width: Int, height: Int, bpp: Int) = resizeBitmap(width, height)
    override fun OnGraphicsResize(width: Int, height: Int, bpp: Int) = resizeBitmap(width, height)

    @Synchronized private fun resizeBitmap(width: Int, height: Int) {
        if (width !in 640..8192 || height !in 480..8192 || width.toLong() * height > 33_554_432L) {
            close(); return
        }
        bitmap?.recycle()
        graphicsUpdated = false
        bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
    }

    @Synchronized override fun OnGraphicsUpdate(x: Int, y: Int, width: Int, height: Int) {
        val surface = bitmap ?: return
        if (terminal.get()) return
        if (!LibFreeRDP.updateGraphics(instance, surface, x, y, width, height)) { close(); return }
        graphicsUpdated = true
        emitFrame(surface)
    }

    @Synchronized private fun emitFrame(surface: Bitmap) {
        if (terminal.get() || !securityGate.canDeliverFrames()) return
        val sequence = frameDelivery.offer() ?: return
        val bytes = surface.rowBytes.toLong() * surface.height
        if (bytes !in 1..RdpNativeFrame.MAX_FRAME_BYTES.toLong()) { close(); return }
        val buffer = ByteBuffer.allocateDirect(bytes.toInt())
        surface.copyPixelsToBuffer(buffer)
        buffer.flip()
        listener?.onFrame(RdpNativeFrame.take(
            sequence, surface.width, surface.height, surface.rowBytes,
            request.display.dpi, buffer,
        ))
    }

    @Synchronized override fun acknowledgeFrame(sequence: Long): Boolean =
        !terminal.get() && frameDelivery.acknowledge(sequence)

    @Synchronized override fun resumeFrames(): Boolean {
        if (terminal.get()) return false
        return when (frameDelivery.resume()) {
            RdpFrameDeliveryGate.Resume.REJECTED -> false
            RdpFrameDeliveryGate.Resume.IDLE -> true
            RdpFrameDeliveryGate.Resume.FRAME_REQUIRED -> {
                val surface = bitmap ?: return false
                emitFrame(surface)
                !terminal.get()
            }
        }
    }

    override fun input(sequence: Long, event: RdpJniInput): Boolean = when (event) {
        is RdpJniInput.Pointer -> pointer(event)
        is RdpJniInput.Key -> LibFreeRDP.sendKeyEvent(instance, hidToAndroid(event.physicalKey) ?: return false, event.down)
        is RdpJniInput.Ime -> false
        is RdpJniInput.Channel -> when (event.kind) {
            com.ersingundem.larenor.rdp.RdpJniChannel.CLIPBOARD -> clipboard(event)
            else -> false
        }
    }

    private fun pointer(event: RdpJniInput.Pointer): Boolean {
        val surface = bitmap ?: return false
        val x = (event.x * (surface.width - 1)).toInt()
        val y = (event.y * (surface.height - 1)).toInt()
        if (!LibFreeRDP.sendCursorEvent(instance, x, y, PTR_MOVE)) return false
        val changed = lastButtons xor event.buttons
        for ((bit, flag) in listOf(1 to PTR_BUTTON1, 2 to PTR_BUTTON3, 4 to PTR_BUTTON2)) {
            if (changed and bit != 0) {
                val down = event.buttons and bit != 0
                if (!LibFreeRDP.sendCursorEvent(instance, x, y, flag or if (down) PTR_DOWN else 0)) return false
            }
        }
        lastButtons = event.buttons
        return true
    }

    private fun clipboard(event: RdpJniInput.Channel): Boolean {
        if (plan.clipboardMode == RdpClipboardMode.DISABLED) return false
        return try {
            val decoder = StandardCharsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT)
            LibFreeRDP.sendClipboardData(instance, decoder.decode(ByteBuffer.wrap(event.payload)).toString())
        } catch (_: Exception) { false }
    }

    override fun resize(sequence: Long, display: RdpNativeDisplay): Boolean =
        LibFreeRDP.sendMonitorLayout(instance, display.width, display.height)

    override fun detach() { listener = null }
    override fun disconnected() {
        super.disconnected()
        listener?.onDisconnected()
    }
    override fun failed() {
        super.failed()
        listener?.onDisconnected()
    }
    @Synchronized override fun close() {
        securityGate.close()
        frameDelivery.close()
        listener = null
        bitmap?.recycle(); bitmap = null
        password?.fill('\u0000'); gatewayPassword?.fill('\u0000')
        super.close()
    }

    companion object {
        private const val PTR_DOWN = 0x8000
        private const val PTR_MOVE = 0x0800
        private const val PTR_BUTTON1 = 0x1000
        private const val PTR_BUTTON2 = 0x2000
        private const val PTR_BUTTON3 = 0x4000

        private fun hidToAndroid(value: Long): Int? {
            val usage = (value and 0xffff).toInt()
            return when (usage) {
                in 0x04..0x1d -> KeyEvent.KEYCODE_A + usage - 0x04
                in 0x1e..0x26 -> KeyEvent.KEYCODE_1 + usage - 0x1e
                0x27 -> KeyEvent.KEYCODE_0
                0x28 -> KeyEvent.KEYCODE_ENTER
                0x29 -> KeyEvent.KEYCODE_ESCAPE
                0x2a -> KeyEvent.KEYCODE_DEL
                0x2b -> KeyEvent.KEYCODE_TAB
                0x2c -> KeyEvent.KEYCODE_SPACE
                0x4f -> KeyEvent.KEYCODE_DPAD_RIGHT
                0x50 -> KeyEvent.KEYCODE_DPAD_LEFT
                0x51 -> KeyEvent.KEYCODE_DPAD_DOWN
                0x52 -> KeyEvent.KEYCODE_DPAD_UP
                else -> null
            }
        }
    }
}

private fun unavailable(): Nothing = throw RdpNativeFailure("engineUnavailable")

/**
 * Exact URI surface consumed by FreeRDP's pinned Android URI converter.
 *
 * Redirection channels that default to disabled are deliberately omitted.
 * In the pinned command-line table drive and USB require values, camera is not
 * an option, and sound/microphone/printer/smartcard are optional-value options
 * rather than booleans. Encoding them as `key=-` would therefore not mean
 * "disabled" and can either fail parsing or enable a channel.
 */
internal fun packagedConnectionUri(
    host: String,
    port: Int,
    username: String,
    width: Int,
    height: Int,
    clipboard: Boolean,
): Uri {
    val authority = if (host.contains(':')) "[$host]:$port" else "$host:$port"
    return Uri.Builder().scheme("freerdp").encodedAuthority(authority).appendPath("connect")
        .appendQueryParameter("u", username)
        .appendQueryParameter("sec", "nla")
        .appendQueryParameter("tls", RdpFreeRdpPackage.TLS_OPTIONS)
        .appendQueryParameter("size", "${width}x$height")
        .appendQueryParameter("dynamic-resolution", "+")
        .appendQueryParameter("clipboard", if (clipboard) "+" else "-")
        .build()
}
