package com.ersingundem.larenor.rdp.packaged

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import java.util.Base64
import com.ersingundem.larenor.rdp.RdpAuthenticatedOutputGate
import com.ersingundem.larenor.rdp.RdpClipboardMode
import com.ersingundem.larenor.rdp.RdpFreeRdpIdentity
import com.ersingundem.larenor.rdp.RdpFreeRdpPackage
import com.ersingundem.larenor.rdp.RdpFrameDeliveryGate
import com.ersingundem.larenor.rdp.RdpJniInput
import com.ersingundem.larenor.rdp.RdpJniOperation
import com.ersingundem.larenor.rdp.RdpJniRuntime
import com.ersingundem.larenor.rdp.RdpJniSecurity
import com.ersingundem.larenor.rdp.RdpJniCertificateProbe
import com.ersingundem.larenor.rdp.RdpJniCertificateProbeOperation
import com.ersingundem.larenor.rdp.RdpJniGatewayEndpoint
import com.ersingundem.larenor.rdp.RdpNativeDisplay
import com.ersingundem.larenor.rdp.RdpNativeFailure
import com.ersingundem.larenor.rdp.RdpNativeFrame
import com.ersingundem.larenor.rdp.RdpNativeFileTransferEndpoint
import com.ersingundem.larenor.rdp.RdpKeyboardLayout
import com.ersingundem.larenor.rdp.RdpMicrophoneCaptureObservation
import com.ersingundem.larenor.rdp.RdpNativeNegotiated
import com.ersingundem.larenor.rdp.RdpNativeRequest
import com.ersingundem.larenor.rdp.RdpNativeGateway
import com.ersingundem.larenor.rdp.RdpRemoteAudioObservation
import com.ersingundem.larenor.rdp.RdpRemoteAudioState
import com.freerdp.freerdpcore.application.GlobalApp
import com.freerdp.freerdpcore.application.SessionState
import com.freerdp.freerdpcore.services.LibFreeRDP
import java.io.ByteArrayInputStream
import java.lang.ref.WeakReference
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
    private val activity = WeakReference(context as? Activity)
    private val openDiagnostics = RdpPackagedOpenDiagnosticSlot()

    init {
        FreeRdpRegistry.install()
        requireExactSymbols()
    }

    override fun identity() = RdpFreeRdpIdentity(
        version = LibFreeRDP.getVersion(),
        sourceCommit = RdpFreeRdpPackage.SOURCE_COMMIT,
        sourceSha256 = RdpFreeRdpPackage.SOURCE_SHA256,
        abi = Build.SUPPORTED_ABIS.firstOrNull { it in RdpFreeRdpPackage.SUPPORTED_ABIS }.orEmpty(),
        jniSchema = 5,
        enabledChannels = emptySet(),
    )

    override fun capabilities(): Map<String, Any?> = RdpFreeRdpPackage.compiledCapabilities()

    override fun inspect(host: String, port: Int, username: String): RdpJniCertificateProbe {
        val probe = FreeRdpProbe(appContext, host, port, username)
        return try {
            probe.run()
        } finally {
            probe.close()
        }
    }

    override fun inspectGateway(
        targetHost: String,
        targetPort: Int,
        targetUsername: String,
        gateway: RdpJniGatewayEndpoint,
    ): RdpJniCertificateProbeOperation = FreeRdpGatewayProbe(
        appContext, targetHost, targetPort, targetUsername, gateway,
    )

    override fun inspectTargetThroughGateway(
        targetHost: String,
        targetPort: Int,
        targetUsername: String,
        targetDomain: String,
        gateway: RdpNativeGateway,
        gatewayPassword: CharArray,
    ): RdpJniCertificateProbeOperation = FreeRdpTargetThroughGatewayProbe(
        appContext, targetHost, targetPort, targetUsername, targetDomain,
        gateway, gatewayPassword,
    )

    override fun create(
        request: RdpNativeRequest,
        plan: RdpNativeNegotiated,
        listener: RdpJniOperation.Listener,
    ): RdpJniOperation {
        if (request.files) throw RdpNativeFailure("channelUnavailable")
        return create(request, plan, listener, null)
    }

    override fun create(
        request: RdpNativeRequest,
        plan: RdpNativeNegotiated,
        listener: RdpJniOperation.Listener,
        fileTransfer: RdpNativeFileTransferEndpoint?,
    ): RdpJniOperation {
        if (request.files != (fileTransfer != null) ||
            fileTransfer != null && (
                fileTransfer.sessionRequestId != request.requestId ||
                    fileTransfer.sessionRevision != request.sessionRevision ||
                    fileTransfer.transferId != request.fileTransferId
                )
        ) throw RdpNativeFailure("channelUnavailable")
        if (request.microphone && !microphoneAuthorized()) {
            throw RdpNativeFailure("microphonePermissionRequired")
        }
        val diagnostic = openDiagnostics.begin(request.requestId)
        return try {
            FreeRdpOperation(
                appContext, request, plan, listener, diagnostic,
                microphoneAuthorized = ::microphoneAuthorized,
                fileTransfer = fileTransfer,
            )
        } catch (failure: LinkageError) {
            diagnostic.candidateCreateFailure()
            throw failure
        } catch (failure: Exception) {
            diagnostic.candidateCreateFailure()
            throw failure
        }
    }

    /**
     * Consumes one failed open observation from this exact runtime instance.
     * Active and successful operations are never observable here.
     */
    internal fun consumeFailedOpenDiagnostic(
        requestId: String,
    ): RdpPackagedOpenDiagnosticSnapshot? = openDiagnostics.consumeFailed(requestId)

    private fun microphoneAuthorized(): Boolean {
        return packagedMicrophoneAuthority(activity.get())
    }

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
            "isUnicodeInputSupported" to 1,
            "sendRelativeCursorEvent" to 4,
            "isRelativeMouseInputSupported" to 1,
            "sendClipboardData" to 2,
            "sendMonitorLayout" to 5,
            "configureGateway" to 3,
            "configureFileTransfer" to 2,
            "freeInstanceDrained" to 2,
        )
        val publicStatic = LibFreeRDP::class.java.declaredMethods.filter {
            Modifier.isPublic(it.modifiers) && Modifier.isStatic(it.modifiers)
        }
        if (required.any { (name, arity) -> publicStatic.none { it.name == name && it.parameterCount == arity } }) {
            unavailable()
        }
        if (GlobalApp::class.java.methods.none {
                it.name == "freeSessionDrained" && it.parameterCount == 2 &&
                    it.returnType == java.lang.Boolean.TYPE
            }) unavailable()
        if (LibFreeRDP.REMOTE_AUDIO_DEVICE_OPENED != 1 ||
            LibFreeRDP.REMOTE_AUDIO_BUFFER_ACCEPTED != 2 ||
            LibFreeRDP.REMOTE_AUDIO_BUFFER_COMPLETED != 3 ||
            LibFreeRDP.REMOTE_AUDIO_DEVICE_CLOSED != 4 ||
            LibFreeRDP.REMOTE_AUDIO_FAILED != 5) {
            unavailable()
        }
        if (LibFreeRDP.MICROPHONE_DEVICE_OPENED != 1 ||
            LibFreeRDP.MICROPHONE_BUFFER_CAPTURED != 2 ||
            LibFreeRDP.MICROPHONE_BUFFER_ACCEPTED != 3 ||
            LibFreeRDP.MICROPHONE_DEVICE_CLOSED != 4 ||
            LibFreeRDP.MICROPHONE_FAILED != 5) {
            unavailable()
        }
        val x509 = LibFreeRDP.UIEventListener::class.java.methods.filter {
            it.name == "OnVerifyX509Certificate"
        }
        if (x509.size != 1 || x509.single().parameterTypes.toList() != listOf(
                ByteArray::class.java,
                String::class.java,
                java.lang.Long.TYPE,
                java.lang.Long.TYPE,
            ) || x509.single().returnType != Integer.TYPE) {
            unavailable()
        }
    }
}

internal class RdpPackagedSessionOwnership(
    private val drainTimeoutNanos: Long = TimeUnit.SECONDS.toNanos(
        NATIVE_DRAIN_AWAIT_SECONDS,
    ),
    private val clock: () -> Long = System::nanoTime,
) {
    enum class State { AVAILABLE, ACTIVE, DRAINING, UNKNOWN }

    init {
        require(drainTimeoutNanos > 0)
    }

    private var state = State.AVAILABLE
    private var owner = 0L
    private var nextOwner = 1L
    private var drainStartedNanos = 0L

    @Synchronized fun reserve(): Long? {
        if (state != State.AVAILABLE || nextOwner == Long.MAX_VALUE) return null
        val token = nextOwner++
        owner = token
        state = State.ACTIVE
        return token
    }

    @Synchronized fun abandon(token: Long): Boolean {
        if (state != State.ACTIVE || owner != token) return false
        owner = 0L
        state = State.AVAILABLE
        drainStartedNanos = 0L
        return true
    }

    @Synchronized fun beginDrain(token: Long): Boolean {
        if (state != State.ACTIVE || owner != token) return false
        state = State.DRAINING
        drainStartedNanos = clock()
        return true
    }

    @Synchronized fun confirmDrained(token: Long, confirmed: () -> Unit): Boolean {
        if (state != State.DRAINING || owner != token) return false
        if (clock() - drainStartedNanos >= drainTimeoutNanos) {
            state = State.UNKNOWN
            return false
        }
        confirmed()
        owner = 0L
        state = State.AVAILABLE
        drainStartedNanos = 0L
        return true
    }

    @Synchronized fun unknown(token: Long): Boolean {
        if (state != State.DRAINING || owner != token) return false
        state = State.UNKNOWN
        return true
    }

    @Synchronized fun snapshot(): State = state
}

private object FreeRdpRegistry : LibFreeRDP.EventListener {
    private val installed = AtomicBoolean(false)
    private val operations = ConcurrentHashMap<Long, FreeRdpConnection>()
    private val ownership = RdpPackagedSessionOwnership()
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
    fun reserve(): Long = ownership.reserve() ?: unavailable()
    fun abandon(token: Long) { ownership.abandon(token) }
    fun detach(instance: Long) { operations.remove(instance) }
    fun expire(instance: Long, owner: Long) {
        if (ownership.unknown(owner)) operations[instance]?.drainUnknown()
    }
    fun release(instance: Long, owner: Long) {
        if (!ownership.beginDrain(owner)) return
        runCatching { LibFreeRDP.cancelConnection(instance) }
        cleanup.execute {
            val operation = operations[instance]
            val drained = try {
                GlobalApp.freeSessionDrained(instance, NATIVE_DRAIN_TIMEOUT_MS)
            } catch (_: Exception) {
                false
            } catch (_: LinkageError) {
                false
            }
            if (drained) {
                val timely = ownership.confirmDrained(owner) {
                    operation?.drained()
                    detach(instance)
                }
                if (!timely) operation?.drainUnknown()
            } else {
                // Keep the complete operation/session/context graph retained.
                // A late native callback must never observe a freed parent.
                ownership.unknown(owner)
                operation?.drainUnknown()
            }
        }
    }
    override fun OnPreConnect(instance: Long) = Unit
    override fun OnConnectionSuccess(instance: Long) { operations[instance]?.connected() }
    override fun OnDisplayControlReady(instance: Long) { operations[instance]?.displayControlReady(instance) }
    override fun OnRemoteAudioPlayback(
        instance: Long,
        deviceOpen: Boolean,
        acceptedCount: Long,
        completedCount: Long,
        fixedState: Int,
    ) {
        operations[instance]?.remoteAudioPlayback(
            instance, deviceOpen, acceptedCount, completedCount, fixedState,
        )
    }
    override fun OnMicrophoneCapture(
        instance: Long,
        deviceOpen: Boolean,
        capturedCount: Long,
        acceptedCount: Long,
        fixedState: Int,
    ) {
        operations[instance]?.microphoneCapture(
            instance, deviceOpen, capturedCount, acceptedCount, fixedState,
        )
    }
    override fun OnConnectionFailure(instance: Long) { operations[instance]?.failed() }
    override fun OnDisconnecting(instance: Long) = Unit
    override fun OnDisconnected(instance: Long) { operations[instance]?.disconnected() }
}

private interface FreeRdpConnection {
    fun connected()
    fun displayControlReady(instance: Long) = Unit
    fun remoteAudioPlayback(
        instance: Long,
        deviceOpen: Boolean,
        acceptedCount: Long,
        completedCount: Long,
        fixedState: Int,
    ) = Unit
    fun microphoneCapture(
        instance: Long,
        deviceOpen: Boolean,
        capturedCount: Long,
        acceptedCount: Long,
        fixedState: Int,
    ) = Unit
    fun failed()
    fun disconnected()
    fun drained() = Unit
    fun drainUnknown() = Unit
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
    private val nativeDrainFinished = CountDownLatch(1)
    @Volatile private var nativeDrainConfirmed = false
    protected var session: SessionState? = null
    protected var instance = 0L
    private var nativeOwner = 0L

    protected fun create(
        uri: Uri,
        gatewayHost: String? = null,
        gatewayPort: Int? = null,
        fileTransferRoot: String? = null,
    ) {
        val owner = FreeRdpRegistry.reserve()
        nativeOwner = owner
        try {
            val made = GlobalApp.createSession(uri, context)
            session = made
            instance = made.instance
            made.uiEventListener = this
            FreeRdpRegistry.attach(instance, this)
            if (!LibFreeRDP.setConnectionInfo(context, instance, uri)) {
                connectionInfoRejected()
                close()
                unavailable()
            }
            if ((gatewayHost == null) != (gatewayPort == null) ||
                gatewayHost != null && !LibFreeRDP.configureGateway(
                    instance, gatewayHost, requireNotNull(gatewayPort),
                )) {
                connectionInfoRejected()
                close()
                unavailable()
            }
            if (fileTransferRoot != null && !LibFreeRDP.configureFileTransfer(
                    instance, fileTransferRoot,
                )
            ) {
                connectionInfoRejected()
                close()
                unavailable()
            }
            connectionInfoParsed()
        } catch (failure: LinkageError) {
            failedCreate(owner)
            throw failure
        } catch (failure: Exception) {
            failedCreate(owner)
            throw failure
        }
    }

    private fun failedCreate(owner: Long) {
        if (instance == 0L) {
            FreeRdpRegistry.abandon(owner)
            nativeOwner = 0L
        } else {
            close()
        }
    }

    protected fun connect() {
        if (session == null || instance == 0L || !LibFreeRDP.connect(instance)) {
            connectRejected()
            unavailable()
        }
        connectAccepted()
    }

    protected open fun connectionInfoParsed() = Unit
    protected open fun connectionInfoRejected() = Unit
    protected open fun connectAccepted() = Unit
    protected open fun connectRejected() = Unit

    protected fun await(seconds: Long): Boolean =
        finished.await(seconds, TimeUnit.SECONDS) && !terminal.get()

    override open fun close() {
        if (!closed.compareAndSet(false, true)) return
        terminal.set(true)
        val value = instance
        val owner = nativeOwner
        if (value != 0L && owner != 0L) {
            FreeRdpRegistry.release(value, owner)
        } else if (owner != 0L) {
            FreeRdpRegistry.abandon(owner)
            nativeDrainConfirmed = true
            nativeDrainFinished.countDown()
        } else {
            nativeDrainConfirmed = true
            nativeDrainFinished.countDown()
        }
        finished.countDown()
    }

    override fun drained() {
        session?.uiEventListener = null
        session = null
        nativeDrainConfirmed = true
        nativeDrainFinished.countDown()
    }

    override fun drainUnknown() {
        // Deliberately retain session and listener references. The public
        // operation is already terminal, but native cleanup is unconfirmed.
        nativeDrainFinished.countDown()
    }

    protected fun closeAndAwaitNativeDrain(): Boolean {
        close()
        if (!nativeDrainFinished.await(NATIVE_DRAIN_AWAIT_SECONDS, TimeUnit.SECONDS)) {
            FreeRdpRegistry.expire(instance, nativeOwner)
            return false
        }
        return nativeDrainConfirmed
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

    protected fun pinFromX509Certificate(pem: ByteArray): String? {
        return packagedSpkiPinFromX509Pem(pem)
    }

    protected fun directPeer(host: String, port: Long, flags: Long): Boolean =
        packagedDirectPeerCertificate(this.host, this.port, host, port, flags)
}

private class FreeRdpGatewayProbe(
    context: Context,
    host: String,
    port: Int,
    username: String,
    private val gateway: RdpJniGatewayEndpoint,
) : BaseConnection(context, host, port, username), RdpJniCertificateProbeOperation {
    @Volatile private var evidence: RdpJniCertificateProbe? = null

    override fun run(): RdpJniCertificateProbe {
        create(baseUri(640, 480, false), gateway.host, gateway.port)
        connect()
        if (!finished.await(20, TimeUnit.SECONDS)) close()
        return evidence ?: probeFailure(RdpProbeOutcome.CONNECTION_FAILURE_BEFORE_CERTIFICATE)
    }

    override fun closeAndAwaitDrain(): Boolean = closeAndAwaitNativeDrain()

    override fun OnAuthenticate(
        username: StringBuilder,
        domain: StringBuilder,
        password: StringBuilder,
    ) = false

    override fun OnVerifyX509Certificate(
        pem: ByteArray,
        host: String,
        port: Long,
        flags: Long,
    ): Int {
        if (terminal.get() || !packagedPeerCertificate(
                gateway.host, gateway.port, host, port, flags, gateway = true,
            )) return 0
        val pin = pinFromX509Certificate(pem) ?: return 0
        evidence = RdpJniCertificateProbe(RdpFreeRdpPackage.TLS_PROTOCOL, true, pin)
        finished.countDown()
        // Enrollment is intentionally aborted before gateway authentication.
        return 0
    }

    override fun OnVerifiyCertificateEx(
        host: String, port: Long, commonName: String, subject: String, issuer: String,
        fingerprint: String, flags: Long,
    ) = 0

    override fun OnVerifyChangedCertificateEx(
        host: String, port: Long, commonName: String, subject: String, issuer: String,
        fingerprint: String, oldSubject: String, oldIssuer: String,
        oldFingerprint: String, flags: Long,
    ) = 0
}

private class FreeRdpTargetThroughGatewayProbe(
    context: Context,
    host: String,
    port: Int,
    username: String,
    @Suppress("unused") private val targetDomain: String,
    private val gateway: RdpNativeGateway,
    gatewayPassword: CharArray,
) : BaseConnection(context, host, port, username), RdpJniCertificateProbeOperation {
    private var gatewaySecret: CharArray? = gatewayPassword.copyOf()
    @Volatile private var gatewayPinned = false
    @Volatile private var evidence: RdpJniCertificateProbe? = null

    init {
        gatewayPassword.fill('\u0000')
    }

    override fun run(): RdpJniCertificateProbe {
        try {
            create(baseUri(640, 480, false), gateway.host, gateway.port)
            connect()
            if (!finished.await(20, TimeUnit.SECONDS)) close()
            return evidence ?: probeFailure(RdpProbeOutcome.CONNECTION_FAILURE_BEFORE_CERTIFICATE)
        } finally {
            gatewaySecret?.fill('\u0000')
            gatewaySecret = null
        }
    }

    override fun closeAndAwaitDrain(): Boolean = closeAndAwaitNativeDrain()

    override fun OnGatewayAuthenticate(
        username: StringBuilder,
        domain: StringBuilder,
        password: StringBuilder,
    ): Boolean {
        if (terminal.get() || !gatewayPinned) return false
        val secret = gatewaySecret ?: return false
        username.setLength(0); username.append(gateway.username)
        domain.setLength(0); domain.append(gateway.domain)
        password.setLength(0); password.append(secret)
        return true
    }

    override fun OnAuthenticate(
        username: StringBuilder,
        domain: StringBuilder,
        password: StringBuilder,
    ) = false

    override fun OnVerifyX509Certificate(
        pem: ByteArray,
        host: String,
        port: Long,
        flags: Long,
    ): Int {
        if (terminal.get()) return 0
        val isGateway = flags and CERTIFICATE_KIND_GATEWAY != 0L
        if (isGateway) {
            if (!packagedPeerCertificate(
                    gateway.host, gateway.port, host, port, flags, gateway = true,
                )) return 0
            val pin = pinFromX509Certificate(pem) ?: return 0
            if (pin != gateway.certificateFingerprint) return 0
            gatewayPinned = true
            return 1
        }
        if (!gatewayPinned || !packagedPeerCertificate(
                this.host, this.port, host, port, flags, gateway = false,
            )) return 0
        val pin = pinFromX509Certificate(pem) ?: return 0
        evidence = RdpJniCertificateProbe(RdpFreeRdpPackage.TLS_PROTOCOL, true, pin)
        finished.countDown()
        // Target enrollment stops before target credentials/NLA.
        return 0
    }

    override fun OnVerifiyCertificateEx(
        host: String, port: Long, commonName: String, subject: String, issuer: String,
        fingerprint: String, flags: Long,
    ) = 0

    override fun OnVerifyChangedCertificateEx(
        host: String, port: Long, commonName: String, subject: String, issuer: String,
        fingerprint: String, oldSubject: String, oldIssuer: String,
        oldFingerprint: String, flags: Long,
    ) = 0

    override fun close() {
        gatewaySecret?.fill('\u0000')
        gatewaySecret = null
        super.close()
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
    override fun OnVerifyX509Certificate(
        pem: ByteArray,
        host: String,
        port: Long,
        flags: Long,
    ): Int {
        if (terminal.get()) return 0
        if (!directPeer(host, port, flags)) {
            failProbe(RdpProbeOutcome.CERTIFICATE_PARSE_FAILED)
            return 0
        }
        val pin = pinFromX509Certificate(pem)
        if (pin == null) {
            failProbe(RdpProbeOutcome.CERTIFICATE_PARSE_FAILED)
            return 0
        }
        evidence = RdpJniCertificateProbe(RdpFreeRdpPackage.TLS_PROTOCOL, true, pin)
        finished.countDown()
        return 0
    }
    override fun OnVerifiyCertificateEx(
        host: String, port: Long, commonName: String, subject: String, issuer: String,
        fingerprint: String, flags: Long,
    ): Int {
        failProbe(RdpProbeOutcome.CERTIFICATE_CALLBACK_MISSING_PEM)
        return 0
    }
    override fun OnVerifyChangedCertificateEx(
        host: String, port: Long, commonName: String, subject: String, issuer: String,
        fingerprint: String, oldSubject: String, oldIssuer: String, oldFingerprint: String, flags: Long,
    ): Int {
        failProbe(RdpProbeOutcome.CERTIFICATE_CALLBACK_MISSING_PEM)
        return 0
    }

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

internal enum class RdpPackagedOpenTerminalKind(
    val wireValue: String,
) {
    NONE("none"),
    CANDIDATE_CREATE_FAILURE("candidateCreateFailure"),
    LOCAL_SETUP_REJECTED("localSetupRejected"),
    CONNECTION_FAILURE_CALLBACK("connectionFailureCallback"),
    DISCONNECTED_CALLBACK("disconnectedCallback"),
    RETIRED("retired"),
    TIMEOUT("timeout"),
}

/**
 * Failure-only, finite observations from one exact packaged open operation.
 *
 * These values are causal boundary observations, not inferred failure causes.
 * The request ID, native instance, host, credentials and exception details are
 * intentionally absent.
 */
internal data class RdpPackagedOpenDiagnosticSnapshot(
    val connectionInfoParsed: Boolean,
    val connectAccepted: Boolean,
    val certificateAccepted: Boolean,
    val authenticatedConnectionSucceeded: Boolean,
    val displayCapsObserved: Boolean,
    val initialLayoutAccepted: Boolean,
    val securityPublished: Boolean,
    val terminal: RdpPackagedOpenTerminalKind,
    val timeout: Boolean,
)

internal class RdpPackagedOpenDiagnosticSlot {
    private var current: RdpPackagedOpenDiagnosticRecorder? = null

    @Synchronized fun begin(requestId: String): RdpPackagedOpenDiagnosticRecorder {
        return RdpPackagedOpenDiagnosticRecorder(this, requestId).also { current = it }
    }

    @Synchronized fun consumeFailed(
        requestId: String,
    ): RdpPackagedOpenDiagnosticSnapshot? {
        val operation = current ?: return null
        if (!operation.matches(requestId)) return null
        val snapshot = operation.failedSnapshot() ?: return null
        if (current === operation) current = null
        return snapshot
    }

    @Synchronized internal fun succeeded(operation: RdpPackagedOpenDiagnosticRecorder) {
        // Successful start is the diagnostic linearization point. A close or
        // callback racing after that point belongs to the live session rather
        // than to a failed open, so it must not leave a consumable open record.
        if (current === operation) current = null
    }
}

internal class RdpPackagedOpenDiagnosticRecorder(
    private val owner: RdpPackagedOpenDiagnosticSlot,
    private val requestId: String,
) {
    private var connectionInfoParsed = false
    private var connectAccepted = false
    private var certificateAccepted = false
    private var authenticatedConnectionSucceeded = false
    private var displayCapsObserved = false
    private var initialLayoutAccepted = false
    private var securityPublished = false
    private var terminal = RdpPackagedOpenTerminalKind.NONE
    private var timeout = false

    @Synchronized fun connectionInfoParsed() = observe { connectionInfoParsed = true }
    @Synchronized fun connectAccepted() = observe { connectAccepted = true }
    @Synchronized fun certificateAccepted() = observe { certificateAccepted = true }
    @Synchronized fun authenticatedConnectionSucceeded() = observe {
        authenticatedConnectionSucceeded = true
    }
    @Synchronized fun displayCapsObserved() = observe { displayCapsObserved = true }
    @Synchronized fun initialLayoutAccepted() = observe { initialLayoutAccepted = true }
    @Synchronized fun securityPublished() = observe { securityPublished = true }

    @Synchronized fun candidateCreateFailure() = finish(
        RdpPackagedOpenTerminalKind.CANDIDATE_CREATE_FAILURE,
    )
    @Synchronized fun localSetupRejected() = finish(
        RdpPackagedOpenTerminalKind.LOCAL_SETUP_REJECTED,
    )
    @Synchronized fun connectionFailureCallback() = finish(
        RdpPackagedOpenTerminalKind.CONNECTION_FAILURE_CALLBACK,
    )
    @Synchronized fun disconnectedCallback() = finish(
        RdpPackagedOpenTerminalKind.DISCONNECTED_CALLBACK,
    )
    @Synchronized fun retired() = finish(RdpPackagedOpenTerminalKind.RETIRED)
    @Synchronized fun timeout() = finish(RdpPackagedOpenTerminalKind.TIMEOUT, true)

    fun succeeded() = owner.succeeded(this)

    @Synchronized internal fun matches(candidate: String): Boolean = requestId == candidate

    @Synchronized internal fun failedSnapshot(): RdpPackagedOpenDiagnosticSnapshot? {
        if (terminal == RdpPackagedOpenTerminalKind.NONE) return null
        return RdpPackagedOpenDiagnosticSnapshot(
            connectionInfoParsed = connectionInfoParsed,
            connectAccepted = connectAccepted,
            certificateAccepted = certificateAccepted,
            authenticatedConnectionSucceeded = authenticatedConnectionSucceeded,
            displayCapsObserved = displayCapsObserved,
            initialLayoutAccepted = initialLayoutAccepted,
            securityPublished = securityPublished,
            terminal = terminal,
            timeout = timeout,
        )
    }

    private inline fun observe(block: () -> Unit) {
        if (terminal == RdpPackagedOpenTerminalKind.NONE) block()
    }

    private fun finish(kind: RdpPackagedOpenTerminalKind, timedOut: Boolean = false) {
        if (terminal != RdpPackagedOpenTerminalKind.NONE) return
        terminal = kind
        timeout = timedOut
    }
}

internal class RdpInitialDisplayGate(private val expectedInstance: Long) {
    data class Dispatch internal constructor(
        internal val id: Long,
        internal val security: RdpJniSecurity,
    )

    sealed interface Completion {
        data class Ready(val security: RdpJniSecurity) : Completion
        data object Failed : Completion
        data object Retired : Completion
    }

    private var security: RdpJniSecurity? = null
    private var peerCapsObserved = false
    private var dispatching = false
    private var terminal = false
    private var nextDispatchId = 1L
    private var activeDispatchId: Long? = null

    @Synchronized fun authenticated(value: RdpJniSecurity): Dispatch? {
        if (terminal || security != null) return null
        security = value
        return reserveIfReady()
    }

    @Synchronized fun peerCaps(instance: Long): Dispatch? {
        if (terminal || instance != expectedInstance || peerCapsObserved) return null
        peerCapsObserved = true
        return reserveIfReady()
    }

    @Synchronized fun complete(dispatch: Dispatch, applied: Boolean): Completion {
        if (activeDispatchId != dispatch.id || !dispatching) return Completion.Retired
        activeDispatchId = null
        dispatching = false
        if (terminal) return Completion.Retired
        if (!applied) {
            terminal = true
            security = null
            return Completion.Failed
        }
        terminal = true
        security = null
        return Completion.Ready(dispatch.security)
    }

    @Synchronized fun retire() {
        terminal = true
        security = null
        activeDispatchId = null
    }

    @Synchronized private fun reserveIfReady(): Dispatch? {
        val evidence = security ?: return null
        if (!peerCapsObserved || dispatching || terminal) return null
        val id = nextDispatchId++
        dispatching = true
        activeDispatchId = id
        return Dispatch(id, evidence)
    }
}

internal class RdpRemoteAudioGate(
    private val expectedInstance: Long,
    private val requested: Boolean,
) {
    sealed interface Update {
        data class Accepted(val observation: RdpRemoteAudioObservation) : Update
        data object Invalid : Update
        data object Ignored : Update
    }

    private var retired = false
    private var latest = RdpRemoteAudioObservation.PENDING

    @Synchronized fun observe(
        instance: Long,
        deviceOpen: Boolean,
        acceptedCount: Long,
        completedCount: Long,
        fixedState: Int,
    ): Update {
        if (!requested || instance != expectedInstance) return Update.Ignored
        val state = when (fixedState) {
            LibFreeRDP.REMOTE_AUDIO_DEVICE_OPENED -> RdpRemoteAudioState.DEVICE_OPEN
            LibFreeRDP.REMOTE_AUDIO_BUFFER_ACCEPTED,
            LibFreeRDP.REMOTE_AUDIO_BUFFER_COMPLETED -> RdpRemoteAudioState.PLAYING
            LibFreeRDP.REMOTE_AUDIO_DEVICE_CLOSED -> RdpRemoteAudioState.CLOSED
            LibFreeRDP.REMOTE_AUDIO_FAILED -> RdpRemoteAudioState.FAILED
            else -> return Update.Invalid
        }
        val observation = try {
            RdpRemoteAudioObservation(state, deviceOpen, acceptedCount, completedCount)
        } catch (_: RdpNativeFailure) {
            return Update.Invalid
        }
        // Saturated JS-safe counters can legitimately publish another callback
        // with the same bounded snapshot. It carries no new evidence.
        if (observation == latest) return Update.Ignored
        val causalCounter = when (fixedState) {
            LibFreeRDP.REMOTE_AUDIO_BUFFER_ACCEPTED -> acceptedCount > latest.acceptedCount
            LibFreeRDP.REMOTE_AUDIO_BUFFER_COMPLETED -> completedCount > latest.completedCount
            else -> true
        }
        if (!causalCounter) return Update.Invalid
        if (retired) {
            if (state == RdpRemoteAudioState.CLOSED &&
                acceptedCount >= latest.acceptedCount &&
                completedCount >= latest.completedCount) {
                latest = observation
            }
            return Update.Ignored
        }
        if (acceptedCount < latest.acceptedCount || completedCount < latest.completedCount) {
            return Update.Invalid
        }
        latest = observation
        return Update.Accepted(observation)
    }

    @Synchronized fun retire() {
        retired = true
    }

    @Synchronized fun retainedForTest(): RdpRemoteAudioObservation = latest
}

private class FreeRdpOperation(
    context: Context,
    private val request: RdpNativeRequest,
    private val plan: RdpNativeNegotiated,
    private var listener: RdpJniOperation.Listener?,
    private val openDiagnostic: RdpPackagedOpenDiagnosticRecorder,
    private val microphoneAuthorized: () -> Boolean,
    private val fileTransfer: RdpNativeFileTransferEndpoint?,
) : BaseConnection(context, request.targetHost, request.targetPort, request.username), RdpJniOperation {
    @Volatile
    override var unicodeInputSupported = false
        private set
    @Volatile
    override var relativePointerSupported = false
        private set
    private var password: CharArray? = null
    private var gatewayPassword: CharArray? = null
    private var bitmap: Bitmap? = null
    private val securityGate = RdpPackagedGatewaySecurityGate(
        request.targetHost,
        request.targetPort,
        request.certificateFingerprint,
        request.gateway,
    )
    private var graphicsUpdated = false
    private val securityPublished = CountDownLatch(1)
    private var lastButtons = 0
    private val frameDelivery = RdpFrameDeliveryGate()
    @Volatile private var initialDisplayGate: RdpInitialDisplayGate? = null
    @Volatile private var remoteAudioGate: RdpRemoteAudioGate? = null
    @Volatile private var microphoneGate: RdpPackagedMicrophoneGate? = null
    private val audioDelivery = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "larenor-rdp-audio").apply { isDaemon = true }
    }
    private val microphoneDelivery = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "larenor-rdp-microphone").apply { isDaemon = true }
    }
    private val microphoneDeliveryScheduled = AtomicBoolean(false)
    private val microphoneDeliveryFailed = AtomicBoolean(false)
    private val pendingMicrophoneObservation =
        AtomicReference<RdpMicrophoneCaptureObservation?>(null)

    override fun start(password: CharArray, gatewayPassword: CharArray?): Boolean {
        if (request.microphone && !microphoneAuthorized()) {
            openDiagnostic.localSetupRejected()
            return false
        }
        this.password = password.copyOf()
        this.gatewayPassword = gatewayPassword?.copyOf()
        return try {
            create(packagedConnectionUri(
                request.targetHost,
                request.targetPort,
                request.username,
                request.display.width,
                request.display.height,
                plan.clipboardMode != RdpClipboardMode.DISABLED,
                request.keyboardLayout,
                request.display.desktopScaleFactor,
                request.display.deviceScaleFactor,
                request.audio,
                request.microphone,
            ), request.gateway?.host, request.gateway?.port, fileTransfer?.canonicalRoot)
            initialDisplayGate = RdpInitialDisplayGate(instance)
            remoteAudioGate = RdpRemoteAudioGate(instance, request.audio)
            microphoneGate = RdpPackagedMicrophoneGate(instance, request.microphone)
            connect()
            val connected = finished.await(45, TimeUnit.SECONDS)
            if (!connected && !terminal.get()) openDiagnostic.timeout()
            val published = connected && !terminal.get() &&
                securityPublished.await(5, TimeUnit.SECONDS)
            if (connected && !published && !terminal.get()) openDiagnostic.timeout()
            val accepted = connected && published && !terminal.get() &&
                securityGate.canDeliverFrames()
            if (accepted) openDiagnostic.succeeded()
            else if (!terminal.get()) openDiagnostic.localSetupRejected()
            accepted
        } catch (failure: Exception) {
            openDiagnostic.localSetupRejected()
            throw failure
        } finally {
            this.password?.fill('\u0000'); this.password = null
            this.gatewayPassword?.fill('\u0000'); this.gatewayPassword = null
        }
    }

    override fun connectionInfoParsed() = openDiagnostic.connectionInfoParsed()
    override fun connectionInfoRejected() = openDiagnostic.localSetupRejected()
    override fun connectAccepted() = openDiagnostic.connectAccepted()
    override fun connectRejected() = openDiagnostic.localSetupRejected()

    override fun OnAuthenticate(username: StringBuilder, domain: StringBuilder, password: StringBuilder): Boolean {
        if (request.microphone && !microphoneAuthorized() ||
            !securityGate.canProvideTargetCredentials()) return false
        val secret = this.password ?: return false
        username.setLength(0); username.append(request.username)
        domain.setLength(0); domain.append(request.domain)
        password.setLength(0); password.append(secret)
        return true
    }

    override fun OnGatewayAuthenticate(
        username: StringBuilder,
        domain: StringBuilder,
        password: StringBuilder,
    ): Boolean {
        if (terminal.get() || request.microphone && !microphoneAuthorized() ||
            !securityGate.canProvideGatewayCredentials()) return false
        val configured = request.gateway ?: return false
        val secret = this.gatewayPassword ?: return false
        username.setLength(0); username.append(configured.username)
        domain.setLength(0); domain.append(configured.domain)
        password.setLength(0); password.append(secret)
        return true
    }

    override fun OnVerifyX509Certificate(
        pem: ByteArray,
        host: String,
        port: Long,
        flags: Long,
    ): Int {
        if (terminal.get() || request.microphone && !microphoneAuthorized()) return 0
        val pin = pinFromX509Certificate(pem) ?: return 0
        // This callback precedes CredSSP authentication. Keep only the accepted
        // pin here; OnConnectionSuccess is the authority for a live session.
        return if (securityGate.certificate(host, port, flags, pin)) {
            openDiagnostic.certificateAccepted()
            1
        } else {
            0
        }
    }

    override fun OnVerifiyCertificateEx(
        host: String, port: Long, commonName: String, subject: String, issuer: String,
        fingerprint: String, flags: Long,
    ): Int {
        return 0
    }

    override fun OnVerifyChangedCertificateEx(
        host: String, port: Long, commonName: String, subject: String, issuer: String,
        fingerprint: String, oldSubject: String, oldIssuer: String, oldFingerprint: String, flags: Long,
    ) = 0

    override fun connected() {
        if (terminal.get()) return
        if (request.microphone && !microphoneAuthorized()) {
            failLocally()
            return
        }
        val evidence = securityGate.connectionSucceeded() ?: return
        openDiagnostic.authenticatedConnectionSucceeded()
        val unicode = runCatching {
            LibFreeRDP.isUnicodeInputSupported(instance)
        }.getOrDefault(false)
        val relative = runCatching {
            LibFreeRDP.isRelativeMouseInputSupported(instance)
        }.getOrDefault(false)
        if (terminal.get()) return
        unicodeInputSupported = unicode
        relativePointerSupported = relative
        applyInitialDisplay(initialDisplayGate?.authenticated(evidence))
    }

    override fun displayControlReady(instance: Long) {
        if (request.microphone && !microphoneAuthorized()) {
            failLocally()
            return
        }
        if (!terminal.get() && instance == this.instance) openDiagnostic.displayCapsObserved()
        applyInitialDisplay(initialDisplayGate?.peerCaps(instance))
    }

    override fun remoteAudioPlayback(
        instance: Long,
        deviceOpen: Boolean,
        acceptedCount: Long,
        completedCount: Long,
        fixedState: Int,
    ) {
        when (val update = remoteAudioGate?.observe(
            instance, deviceOpen, acceptedCount, completedCount, fixedState,
        ) ?: RdpRemoteAudioGate.Update.Ignored) {
            RdpRemoteAudioGate.Update.Ignored -> Unit
            RdpRemoteAudioGate.Update.Invalid -> dispatchAudioFailure()
            is RdpRemoteAudioGate.Update.Accepted -> dispatchAudio(update.observation)
        }
    }

    override fun microphoneCapture(
        instance: Long,
        deviceOpen: Boolean,
        capturedCount: Long,
        acceptedCount: Long,
        fixedState: Int,
    ) {
        if (request.microphone && !microphoneAuthorized()) {
            dispatchMicrophoneFailure()
            return
        }
        when (val update = microphoneGate?.observe(
            instance, deviceOpen, capturedCount, acceptedCount, fixedState,
        ) ?: RdpPackagedMicrophoneGate.Update.Ignored) {
            RdpPackagedMicrophoneGate.Update.Ignored -> Unit
            RdpPackagedMicrophoneGate.Update.Invalid -> dispatchMicrophoneFailure()
            is RdpPackagedMicrophoneGate.Update.Accepted ->
                dispatchMicrophone(update.observation)
        }
    }

    private fun dispatchAudio(observation: RdpRemoteAudioObservation) {
        runCatching {
            audioDelivery.execute {
                if (!terminal.get()) listener?.onRemoteAudio(observation)
            }
        }
    }

    private fun dispatchAudioFailure() {
        runCatching {
            audioDelivery.execute {
                if (!terminal.get()) failLocally()
            }
        }
    }

    private fun dispatchMicrophone(observation: RdpMicrophoneCaptureObservation) {
        pendingMicrophoneObservation.set(observation)
        scheduleMicrophoneDelivery()
    }

    private fun dispatchMicrophoneFailure() {
        microphoneDeliveryFailed.set(true)
        scheduleMicrophoneDelivery()
    }

    private fun scheduleMicrophoneDelivery() {
        if (!microphoneDeliveryScheduled.compareAndSet(false, true)) return
        try {
            microphoneDelivery.execute {
                try {
                    while (!terminal.get()) {
                        if (microphoneDeliveryFailed.getAndSet(false)) {
                            failLocally()
                            break
                        }
                        val observation = pendingMicrophoneObservation.getAndSet(null) ?: break
                        listener?.onMicrophoneCapture(observation)
                    }
                } finally {
                    microphoneDeliveryScheduled.set(false)
                    if (!terminal.get() &&
                        (microphoneDeliveryFailed.get() || pendingMicrophoneObservation.get() != null)) {
                        scheduleMicrophoneDelivery()
                    }
                }
            }
        } catch (_: RuntimeException) {
            microphoneDeliveryScheduled.set(false)
        }
    }

    private fun applyInitialDisplay(dispatch: RdpInitialDisplayGate.Dispatch?) {
        dispatch ?: return
        val gate = initialDisplayGate ?: return
        val applied = !terminal.get() && runCatching {
            LibFreeRDP.sendMonitorLayout(
                instance,
                request.display.width,
                request.display.height,
                request.display.desktopScaleFactor,
                request.display.deviceScaleFactor,
            )
        }.getOrDefault(false)
        if (applied) openDiagnostic.initialLayoutAccepted()
        when (val completion = gate.complete(dispatch, applied)) {
            RdpInitialDisplayGate.Completion.Failed -> {
                failLocally()
                return
            }
            RdpInitialDisplayGate.Completion.Retired -> return
            is RdpInitialDisplayGate.Completion.Ready -> publishInitialDisplay(completion.security)
        }
    }

    @Synchronized private fun publishInitialDisplay(evidence: RdpJniSecurity) {
        if (terminal.get()) return
        if (request.microphone && !microphoneAuthorized()) {
            failLocally()
            return
        }
        val consumer = listener ?: return
        consumer.onSecurity(evidence)
        // The consumer may retire the operation while handling security.
        if (!terminal.get() && securityGate.securityDelivered()) {
            openDiagnostic.securityPublished()
            securityPublished.countDown()
            if (graphicsUpdated) bitmap?.let { emitFrame(it) }
        }
        super.connected()
    }

    override fun OnSettingsChanged(width: Int, height: Int, bpp: Int) = resizeBitmap(width, height)
    override fun OnGraphicsResize(width: Int, height: Int, bpp: Int) = resizeBitmap(width, height)

    @Synchronized private fun resizeBitmap(width: Int, height: Int) {
        if (width !in 640..8192 || height !in 480..8192 ||
            width.toLong() * height > RdpNativeFrame.MAX_PIXELS) {
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
            sequence, surface.width, surface.height, surface.rowBytes, buffer,
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
        is RdpJniInput.AbsolutePointer -> absolutePointer(event)
        is RdpJniInput.RelativePointer -> relativePointer(event)
        is RdpJniInput.VerticalWheel -> verticalWheel(event)
        is RdpJniInput.Key -> LibFreeRDP.sendKeyEvent(
            instance,
            usbKeyboardVirtualKey(event.physicalKey) ?: return false,
            event.down,
        )
        is RdpJniInput.Ime -> unicode(event)
        is RdpJniInput.Channel -> when (event.kind) {
            com.ersingundem.larenor.rdp.RdpJniChannel.CLIPBOARD -> clipboard(event)
            else -> false
        }
    }

    private fun absolutePointer(event: RdpJniInput.AbsolutePointer): Boolean {
        val events = absolutePointerWireEvents(event, lastButtons)
        for (wire in events) {
            if (!LibFreeRDP.sendCursorEvent(instance, wire.x, wire.y, wire.flags)) return false
        }
        lastButtons = event.buttons
        return true
    }

    private fun relativePointer(event: RdpJniInput.RelativePointer): Boolean {
        if (!relativePointerSupported) return false
        val events = relativePointerWireEvents(event, lastButtons)
        if (events.isEmpty()) return false
        for (wire in events) {
            if (!LibFreeRDP.sendRelativeCursorEvent(instance, wire.x, wire.y, wire.flags)) return false
        }
        lastButtons = event.buttons
        return true
    }

    private fun verticalWheel(event: RdpJniInput.VerticalWheel): Boolean {
        return LibFreeRDP.sendCursorEvent(instance, 0, 0, verticalWheelFlags(event.delta))
    }

    private fun clipboard(event: RdpJniInput.Channel): Boolean {
        if (plan.clipboardMode == RdpClipboardMode.DISABLED) return false
        return try {
            val decoder = StandardCharsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT)
            LibFreeRDP.sendClipboardData(instance, decoder.decode(ByteBuffer.wrap(event.payload)).toString())
        } catch (_: Exception) { false }
    }

    private fun unicode(event: RdpJniInput.Ime): Boolean {
        if (!unicodeInputSupported) return false
        val value = try {
            val decoder = StandardCharsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
            decoder.decode(ByteBuffer.wrap(event.utf8)).toString()
        } catch (_: Exception) {
            return false
        }
        val units = strictUtf16Units(value)
        if (units.isEmpty()) return false
        for (unit in units) {
            if (!LibFreeRDP.sendUnicodeKeyEvent(instance, unit, true) ||
                !LibFreeRDP.sendUnicodeKeyEvent(instance, unit, false)) return false
        }
        return true
    }

    override fun resize(sequence: Long, display: RdpNativeDisplay): Boolean =
        LibFreeRDP.sendMonitorLayout(
            instance, display.width, display.height,
            display.desktopScaleFactor, display.deviceScaleFactor,
        )

    override fun detach() { listener = null }
    override fun disconnected() {
        openDiagnostic.disconnectedCallback()
        super.disconnected()
        listener?.onDisconnected()
    }
    override fun failed() {
        openDiagnostic.connectionFailureCallback()
        super.failed()
        listener?.onDisconnected()
    }
    private fun failLocally() {
        // Audio and initial-display validation are local setup boundaries.
        // Record that finite fact before using the common terminal path; the
        // recorder's first-terminal rule prevents the shared failed() action
        // from relabeling it as a JNI connection-failure callback.
        openDiagnostic.localSetupRejected()
        failed()
    }
    @Synchronized override fun close() {
        openDiagnostic.retired()
        initialDisplayGate?.retire()
        remoteAudioGate?.retire()
        microphoneGate?.retire()
        securityGate.close()
        frameDelivery.close()
        listener = null
        audioDelivery.shutdownNow()
        microphoneDelivery.shutdownNow()
        pendingMicrophoneObservation.set(null)
        bitmap?.recycle(); bitmap = null
        password?.fill('\u0000'); gatewayPassword?.fill('\u0000')
        super.close()
    }

    override fun closeAndAwaitDrain(): Boolean = closeAndAwaitNativeDrain()

}

internal data class RdpPointerWireEvent(val x: Int, val y: Int, val flags: Int)

internal fun absolutePointerWireEvents(
    event: RdpJniInput.AbsolutePointer,
    previousButtons: Int,
): List<RdpPointerWireEvent> {
    val x = (event.x * (event.width - 1)).toInt()
    val y = (event.y * (event.height - 1)).toInt()
    return buildList {
        add(RdpPointerWireEvent(x, y, PTR_MOVE))
        addButtonTransitions(previousButtons, event.buttons, x, y)
    }
}

internal fun relativePointerWireEvents(
    event: RdpJniInput.RelativePointer,
    previousButtons: Int,
): List<RdpPointerWireEvent> = buildList {
    if (event.deltaX != 0 || event.deltaY != 0) {
        add(RdpPointerWireEvent(event.deltaX, event.deltaY, PTR_MOVE))
    }
    addButtonTransitions(previousButtons, event.buttons, 0, 0)
}

private fun MutableList<RdpPointerWireEvent>.addButtonTransitions(
    previousButtons: Int,
    buttons: Int,
    x: Int,
    y: Int,
) {
    val changed = previousButtons xor buttons
    for ((bit, flag) in POINTER_BUTTON_FLAGS) {
        if (changed and bit != 0) {
            add(RdpPointerWireEvent(x, y, flag or if (buttons and bit != 0) PTR_DOWN else 0))
        }
    }
}

internal fun verticalWheelFlags(delta: Int): Int = when (delta) {
    120 -> PTR_WHEEL or 0x78
    -120 -> PTR_WHEEL or PTR_WHEEL_NEGATIVE or 0x88
    else -> throw IllegalArgumentException("unsupported wheel delta")
}

private const val PTR_DOWN = 0x8000
private const val PTR_MOVE = 0x0800
private const val PTR_BUTTON1 = 0x1000
private const val PTR_BUTTON2 = 0x2000
private const val PTR_BUTTON3 = 0x4000
private const val PTR_WHEEL = 0x0200
private const val PTR_WHEEL_NEGATIVE = 0x0100
private const val MAX_X509_PEM_BYTES = 64 * 1024
private const val X509_PEM_BEGIN = "-----BEGIN CERTIFICATE-----"
private const val X509_PEM_END = "-----END CERTIFICATE-----"
private const val CERTIFICATE_KIND_GATEWAY = 0x20L
private const val NATIVE_DRAIN_TIMEOUT_MS = 5_000
private const val NATIVE_DRAIN_AWAIT_SECONDS = 6L
private val POINTER_BUTTON_FLAGS = listOf(
    1 to PTR_BUTTON1,
    2 to PTR_BUTTON3,
    4 to PTR_BUTTON2,
)

internal fun usbKeyboardVirtualKey(value: Long): Int? {
    if ((value ushr 16).toInt() != 0x07) return null
    val usage = (value and 0xffff).toInt()
    return when (usage) {
        in 0x04..0x1d -> 0x41 + usage - 0x04
        in 0x1e..0x26 -> 0x31 + usage - 0x1e
        0x27 -> 0x30
        0x28 -> 0x0d; 0x29 -> 0x1b; 0x2a -> 0x08; 0x2b -> 0x09; 0x2c -> 0x20
        0x2d -> 0xbd; 0x2e -> 0xbb; 0x2f -> 0xdb; 0x30 -> 0xdd
        0x31 -> 0xdc; 0x32 -> 0xe2; 0x33 -> 0xba; 0x34 -> 0xde
        0x35 -> 0xc0; 0x36 -> 0xbc; 0x37 -> 0xbe; 0x38 -> 0xbf
        0x39 -> 0x14
        in 0x3a..0x45 -> 0x70 + usage - 0x3a
        0x46 -> 0x2c; 0x47 -> 0x91; 0x48 -> 0x13; 0x49 -> 0x2d
        0x4a -> 0x24; 0x4b -> 0x21; 0x4c -> 0x2e; 0x4d -> 0x23
        0x4e -> 0x22; 0x4f -> 0x27; 0x50 -> 0x25; 0x51 -> 0x28; 0x52 -> 0x26
        0x53 -> 0x90; 0x54 -> 0x6f; 0x55 -> 0x6a; 0x56 -> 0x6d; 0x57 -> 0x6b
        0x58 -> 0x0d
        in 0x59..0x61 -> 0x61 + usage - 0x59
        0x62 -> 0x60; 0x63 -> 0x6e; 0x64 -> 0xe2; 0x65 -> 0x5d
        0x67 -> 0xbb
        in 0x68..0x73 -> 0x7c + usage - 0x68
        0xe0 -> 0xa2; 0xe1 -> 0xa0; 0xe2 -> 0xa4; 0xe3 -> 0x5b
        0xe4 -> 0xa3; 0xe5 -> 0xa1; 0xe6 -> 0xa5; 0xe7 -> 0x5c
        else -> null
    }
}

internal fun strictUtf16Units(value: String): IntArray {
    if (value.isEmpty() || value.indexOf('\u0000') >= 0) return IntArray(0)
    val result = IntArray(value.length)
    var index = 0
    while (index < value.length) {
        val unit = value[index].code
        if (unit in 0xd800..0xdbff) {
            if (index + 1 >= value.length || value[index + 1].code !in 0xdc00..0xdfff) {
                return IntArray(0)
            }
            result[index] = unit
            result[index + 1] = value[index + 1].code
            index += 2
        } else {
            if (unit in 0xdc00..0xdfff) return IntArray(0)
            result[index] = unit
            index++
        }
    }
    return result
}

internal fun packagedSpkiPinFromX509Pem(pem: ByteArray): String? {
    if (pem.isEmpty() || pem.size > MAX_X509_PEM_BYTES || pem.any {
            val value = it.toInt() and 0xff
            value !in 0x20..0x7e && value !in setOf(0x09, 0x0a, 0x0d)
        }) return null
    val encoded = String(pem, StandardCharsets.US_ASCII)
    if (!encoded.startsWith(X509_PEM_BEGIN) ||
        !encoded.trimEnd().endsWith(X509_PEM_END) ||
        encoded.indexOf(X509_PEM_BEGIN, X509_PEM_BEGIN.length) >= 0 ||
        encoded.indexOf(X509_PEM_END) != encoded.lastIndexOf(X509_PEM_END)) return null
    return try {
        val input = ByteArrayInputStream(pem)
        val cert = CertificateFactory.getInstance("X.509").generateCertificate(input)
        if (input.readBytes().any { !it.toInt().toChar().isWhitespace() }) return null
        "SHA256:" + Base64.getEncoder().withoutPadding().encodeToString(
            MessageDigest.getInstance("SHA-256").digest(cert.publicKey.encoded),
        )
    } catch (_: Exception) {
        null
    }
}

internal fun packagedDirectPeerCertificate(
    expectedHost: String,
    expectedPort: Int,
    observedHost: String,
    observedPort: Long,
    flags: Long,
): Boolean = observedHost == expectedHost && observedPort == expectedPort.toLong() &&
    flags and CERTIFICATE_KIND_GATEWAY == 0L

internal fun packagedPeerCertificate(
    expectedHost: String,
    expectedPort: Int,
    observedHost: String,
    observedPort: Long,
    flags: Long,
    gateway: Boolean,
): Boolean {
    val allowed = 0x02L or 0x20L or 0x80L or 0x100L or 0x200L
    return observedHost == expectedHost && observedPort == expectedPort.toLong() &&
        flags and (0x10L or 0x40L) == 0L && flags and allowed.inv() == 0L &&
        (flags and CERTIFICATE_KIND_GATEWAY != 0L) == gateway
}

internal fun packagedMicrophoneAuthority(activity: Activity?): Boolean = activity != null &&
    !activity.isFinishing && !activity.isDestroyed && activity.hasWindowFocus() &&
    activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

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
    keyboardLayout: RdpKeyboardLayout = RdpKeyboardLayout.AUTOMATIC,
    desktopScaleFactor: Int = 100,
    deviceScaleFactor: Int = 100,
    audio: Boolean = false,
    microphone: Boolean = false,
): Uri {
    val authority = if (host.contains(':')) "[$host]:$port" else "$host:$port"
    return Uri.Builder().scheme("freerdp").encodedAuthority(authority).appendPath("connect")
        .appendQueryParameter("u", username)
        .appendQueryParameter("sec", "nla")
        .appendQueryParameter("tls", RdpFreeRdpPackage.TLS_OPTIONS)
        .appendQueryParameter("size", "${width}x$height")
        .appendQueryParameter("scale-desktop", desktopScaleFactor.toString())
        .appendQueryParameter("scale-device", deviceScaleFactor.toString())
        .appendQueryParameter("dynamic-resolution", "+")
        .appendQueryParameter("clipboard", if (clipboard) "+" else "-")
        .appendQueryParameter("audio-mode", if (audio) "0" else "2")
        .apply {
            if (audio) appendQueryParameter("sound", "sys:opensles")
            if (microphone) appendQueryParameter("microphone", "sys:opensles")
        }
        .appendQueryParameter("kbd", when (keyboardLayout) {
            RdpKeyboardLayout.AUTOMATIC -> "unicode:on"
            RdpKeyboardLayout.TURKISH_Q -> "layout:1055,unicode:on"
            RdpKeyboardLayout.US -> "layout:1033,unicode:on"
        })
        .build()
}
