package com.ersingundem.larenor.rdp

import android.app.Activity
import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.nio.CharBuffer
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets
import java.util.concurrent.Executors

internal object RdpJniRuntimeLoader {
    fun load(context: Context): RdpJniRuntime? = try {
        val type = Class.forName("com.ersingundem.larenor.rdp.packaged.RdpPackagedRuntime")
        type.getConstructor(Context::class.java).newInstance(context) as RdpJniRuntime
    } catch (_: LinkageError) {
        null
    } catch (_: ReflectiveOperationException) {
        null
    } catch (_: Exception) {
        null
    }
}

class RdpNativeBridge internal constructor(
    private val activity: Activity,
    messenger: BinaryMessenger,
    runtime: RdpJniRuntime?,
    private val safGrants: RdpSafGrantBroker,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    constructor(
        activity: Activity,
        messenger: BinaryMessenger,
        runtime: RdpJniRuntime? = RdpJniRuntimeLoader.load(activity),
    ) : this(activity, messenger, runtime, RdpSafGrantBroker(activity))

    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "larenor-rdp").apply { isDaemon = true }
    }
    private val methods = MethodChannel(messenger, METHODS)
    private val events = EventChannel(messenger, EVENTS)
    private val runtime = runtime
    private val adapter = RdpNativeAdapter(RdpProductFeatureBackend(RdpFreeRdpBackend(runtime)))
    private val microphonePermission = RdpMicrophonePermissionBroker(activity, ::permissionRevoked)
    private var sink: EventChannel.EventSink? = null
    @Volatile private var resumed = false
    @Volatile private var focused = true
    @Volatile private var disposed = false
    @Volatile private var requestId: String? = null
    @Volatile private var microphonePermissionRevision = 0L
    private var networkBusy = false
    @Volatile private var session: RdpFreeRdpSession? = null
    @Volatile private var pendingProbe: RdpJniCertificateProbeOperation? = null
    private val openOwners = RdpOpenOwnerGate()
    private val safTransfers = RdpSafTransferCoordinator(
        activity = activity,
        grants = safGrants,
        foreground = ::foreground,
        clearSession = { owned -> if (session === owned) session = null },
        main = main,
    )

    init {
        methods.setMethodCallHandler(this)
        events.setStreamHandler(this)
    }

    fun setResumed(value: Boolean) {
        if (disposed) return
        resumed = value
        safGrants.setResumed(value)
        if (!value) {
            retire()
        }
    }

    fun setStopped() {
        if (disposed) return
        requestId?.let(microphonePermission::cancel)
        retire()
    }

    fun setWindowFocused(value: Boolean) {
        if (disposed) return
        focused = value
        microphonePermission.setWindowFocused(value)
        safGrants.setWindowFocused(value)
        if (!value) retire()
    }

    override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink) {
        if (disposed || arguments !is String || !UUID.matches(arguments) || sink != null) {
            eventSink.error("invalidRequest", "RDP event owner rejected", null)
            return
        }
        openOwners.invalidate()
        requestId = arguments
        sink = eventSink
    }

    override fun onCancel(arguments: Any?) {
        if (arguments == requestId) {
            microphonePermission.cancel(arguments as String)
            retire()
            sink = null
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (disposed) return error(result, "engineUnavailable")
        try {
            retireMicrophoneIfPermissionMissing()
            when (call.method) {
                "capabilities" -> {
                    if (call.arguments != null) fail("invalidRequest")
                    result.success(adapter.capabilities().toChannel())
                }
                "activate" -> {
                    requireForeground()
                    val value = owned(
                        call.arguments,
                        setOf("requestId"),
                        setOf("schemaVersion", "requestId"),
                    )
                    val id = value["requestId"] as? String ?: fail("invalidRequest")
                    if (!UUID.matches(id) || requestId != id || sink == null) fail("staleSession")
                    if (value.containsKey("schemaVersion") && value["schemaVersion"] != 6) {
                        fail("invalidRequest")
                    }
                    result.success(null)
                }
                "inspect" -> inspect(call.arguments, result)
                "inspectGateway" -> inspectGateway(call.arguments, result)
                "inspectTargetThroughGateway" -> inspectTargetThroughGateway(call.arguments, result)
                "open" -> open(call.arguments, result)
                "input" -> input(call.arguments, result)
                "resize" -> resize(call.arguments, result)
                "ackFrame" -> ack(call.arguments, result)
                "audioObservation" -> audioObservation(call.arguments, result)
                "microphoneObservation" -> microphoneObservation(call.arguments, result)
                "requestMicrophonePermission" -> requestMicrophonePermission(call.arguments, result)
                "cancelMicrophonePermission" -> cancelMicrophonePermission(call.arguments, result)
                "selectFileTransferTree" -> safGrants.select(call.arguments, result)
                "cancelFileTransferTree" -> safGrants.cancel(call.arguments, result)
                "activateFileTransferGrant" -> safGrants.activate(call.arguments, result)
                "fileTransferGrantObservation" -> safGrants.observe(call.arguments, result)
                "retireFileTransferGrant" -> safGrants.retire(call.arguments, result)
                "prepareFileTransfer" -> safTransfers.prepare(call.arguments, result)
                "fileTransferObservation" -> safTransfers.observe(call.arguments, result)
                "drainFileTransfer" -> safTransfers.drain(call.arguments, result)
                "saveReceivedFiles" -> safTransfers.save(call.arguments, result)
                "cancel" -> cancel(call.arguments, result)
                else -> result.notImplemented()
            }
        } catch (failure: RdpNativeFailure) {
            if (call.method !in setOf(
                    "capabilities", "inspect", "inspectGateway", "inspectTargetThroughGateway",
                    "audioObservation", "microphoneObservation",
                    "requestMicrophonePermission", "cancelMicrophonePermission",
                    "prepareFileTransfer", "fileTransferObservation", "drainFileTransfer",
                    "saveReceivedFiles",
                )) retire()
            error(result, failure.code)
        } catch (_: Exception) {
            if (call.method !in setOf(
                    "capabilities", "inspectGateway", "inspectTargetThroughGateway",
                    "audioObservation", "microphoneObservation",
                    "requestMicrophonePermission", "cancelMicrophonePermission",
                    "prepareFileTransfer", "fileTransferObservation", "drainFileTransfer",
                    "saveReceivedFiles",
                )) retire()
            error(result, "connectionFailed")
        }
    }

    private fun inspect(raw: Any?, result: MethodChannel.Result) {
        requireForeground()
        if (networkBusy) fail("busy")
        val value = map(raw, setOf("targetHost", "targetPort", "username"))
        val host = safeHost(value["targetHost"])
        val port = integer(value["targetPort"], 1, 65535)
        val username = safeText(value["username"], 0, 128)
        networkBusy = true
        try {
            worker.execute {
                try {
                    if (!adapter.capabilities().canConnect) fail("engineUnavailable")
                    val evidence = (runtime ?: fail("engineUnavailable")).inspect(host, port, username)
                    main.post {
                        networkBusy = false
                        if (!foreground()) error(result, "staleSession") else result.success(mapOf(
                            // Preserve v1 keys: these are certificate-probe/client-policy facts,
                            // not an authenticated peer/session receipt.
                            "tls" to (evidence.minimumTlsPolicy == RdpFreeRdpPackage.TLS_PROTOCOL),
                            "requiresNla" to evidence.clientRequiresNla,
                            "certificateFingerprint" to evidence.certificateFingerprint,
                        ))
                    }
                } catch (failure: RdpNativeFailure) {
                    main.post { networkBusy = false; error(result, failure.code) }
                } catch (_: Exception) {
                    main.post { networkBusy = false; error(result, "connectionFailed") }
                }
            }
        } catch (error: RuntimeException) {
            networkBusy = false
            throw error
        }
    }

    private fun inspectGateway(raw: Any?, result: MethodChannel.Result) {
        requireForeground()
        if (!adapter.capabilities().rdGateway) fail("gatewayUnavailable")
        if (networkBusy || session != null || pendingProbe != null) fail("busy")
        val value = map(raw, setOf("schemaVersion", "requestId", "target", "gateway"))
        if (value["schemaVersion"] != 6) fail("invalidRequest")
        ownedId(value)
        val id = requestId ?: fail("staleSession")
        val target = enrollmentPeer(value["target"], includeDomain = false, includePin = false)
        val gateway = enrollmentPeer(value["gateway"], includeDomain = true, includePin = false)
        val endpoint = RdpJniGatewayEndpoint(
            gateway.host, gateway.port, gateway.username, gateway.domain,
        )
        val operation = (runtime ?: fail("engineUnavailable")).inspectGateway(
            target.host, target.port, target.username, endpoint,
        )
        runProbe(id, operation, "gateway", result)
    }

    private fun inspectTargetThroughGateway(raw: Any?, result: MethodChannel.Result) {
        val callerSecret = (raw as? Map<*, *>)?.get("gatewayPassword") as? ByteArray
        val value = try {
            map(
                raw,
                setOf("schemaVersion", "requestId", "target", "gateway", "gatewayPassword"),
            )
        } catch (failure: Exception) {
            callerSecret?.fill(0)
            throw failure
        }
        val bytes = callerSecret ?: fail("invalidSecrets")
        var secret: CharArray? = null
        try {
            requireForeground()
            if (!adapter.capabilities().rdGateway) fail("gatewayUnavailable")
            if (networkBusy || session != null || pendingProbe != null) fail("busy")
            if (value["schemaVersion"] != 6) fail("invalidRequest")
            ownedId(value)
            val id = requestId ?: fail("staleSession")
            val target = enrollmentPeer(value["target"], includeDomain = true, includePin = false)
            val gateway = enrollmentPeer(value["gateway"], includeDomain = true, includePin = true)
            secret = decode(bytes, false)
            val operation = (runtime ?: fail("engineUnavailable")).inspectTargetThroughGateway(
                target.host,
                target.port,
                target.username,
                target.domain,
                RdpNativeGateway(
                    gateway.host,
                    gateway.port,
                    gateway.username,
                    gateway.domain,
                    requireNotNull(gateway.pin),
                ),
                requireNotNull(secret),
            )
            secret = null // operation consumed and wiped the exact mutable owner
            runProbe(id, operation, "target", result)
        } finally {
            bytes.fill(0)
            secret?.fill('\u0000')
        }
    }

    private fun runProbe(
        id: String,
        operation: RdpJniCertificateProbeOperation,
        kind: String,
        result: MethodChannel.Result,
    ) {
        pendingProbe = operation
        networkBusy = true
        try {
            worker.execute {
                var evidence: RdpJniCertificateProbe? = null
                var failureCode: String? = null
                try {
                    evidence = operation.run()
                } catch (failure: RdpNativeFailure) {
                    failureCode = failure.code
                } catch (_: Exception) {
                    failureCode = "connectionFailed"
                }
                val drained = try {
                    operation.closeAndAwaitDrain()
                } catch (_: LinkageError) {
                    false
                } catch (_: Exception) {
                    false
                }
                if (!drained) failureCode = "connectionFailed"
                main.post {
                    val owned = pendingProbe === operation
                    if (owned) pendingProbe = null
                    networkBusy = false
                    when {
                        !owned || !foreground() || requestId != id ->
                            error(result, "staleSession")
                        failureCode != null -> error(result, requireNotNull(failureCode))
                        else -> result.success(mapOf(
                            "schemaVersion" to 6,
                            "requestId" to id,
                            "kind" to kind,
                            "certificateFingerprint" to requireNotNull(evidence).certificateFingerprint,
                        ))
                    }
                }
            }
        } catch (failure: RuntimeException) {
            if (pendingProbe === operation) pendingProbe = null
            networkBusy = false
            operation.close()
            throw failure
        }
    }

    private fun open(raw: Any?, result: MethodChannel.Result) {
        val callerPassword = (raw as? Map<*, *>)?.get("password") as? ByteArray
        val callerGateway = (raw as? Map<*, *>)?.get("gatewayPassword") as? ByteArray
        val value = try {
            map(raw, setOf("schemaVersion", "request", "requestId", "password", "gatewayPassword"))
        } catch (failure: Exception) {
            callerPassword?.fill(0)
            callerGateway?.fill(0)
            throw failure
        }
        val passwordBytes = callerPassword ?: run {
            callerGateway?.fill(0)
            fail("invalidSecrets")
        }
        val gatewayBytes = callerGateway ?: run {
            passwordBytes.fill(0)
            fail("invalidSecrets")
        }
        var decodedPassword: CharArray? = null
        var decodedGateway: CharArray? = null
        val parsed = try {
            requireForeground()
            if (session != null || networkBusy) fail("busy")
            val wireSchema = value["schemaVersion"] as? Int ?: fail("invalidRequest")
            if (wireSchema !in setOf(4, 6)) fail("invalidRequest")
            val id = value["requestId"] as? String ?: fail("invalidRequest")
            if (!UUID.matches(id) || id != requestId || sink == null) fail("staleSession")
            val request = RdpNativeRequest.parse(value["request"])
            if (request.requestId != id || request.schemaVersion != wireSchema) fail("invalidRequest")
            if (request.microphone && !microphonePermission.granted()) {
                fail("microphonePermissionRequired")
            }
            decodedPassword = decode(passwordBytes, false)
            decodedGateway = decode(gatewayBytes, true)
            OpenParameters(
                id,
                request,
                microphonePermissionRevision,
                safTransfers.endpointForOpen(request),
            )
        } catch (failure: Exception) {
            decodedPassword?.fill('\u0000')
            decodedGateway?.fill('\u0000')
            throw failure
        } finally {
            passwordBytes.fill(0)
            gatewayBytes.fill(0)
        }
        val (id, request, permissionRevision, fileTransfer) = parsed
        val ownerSink = sink ?: fail("staleSession")
        val openOwner = openOwners.capture(ownerSink)
        val password = requireNotNull(decodedPassword)
        val gateway = requireNotNull(decodedGateway)
        networkBusy = true
        try {
            worker.execute {
                try {
                    if (request.microphone && (!foreground() ||
                            !microphonePermission.granted() ||
                            permissionRevision != microphonePermissionRevision)) {
                        fail("microphonePermissionRequired")
                    }
                    val secrets = RdpNativeSecrets.take(password, gateway.takeIf { request.gateway != null })
                    if (request.gateway == null) gateway.fill('\u0000')
                    val observer = Observer(id)
                    val opened = adapter.open(
                        request, secrets, observer, fileTransfer,
                    ) as RdpFreeRdpSession
                    if (!openOwnerCurrent(openOwner, id)) {
                        failedOpenTransfer(fileTransfer)
                        opened.close()
                        fail("staleSession")
                    }
                    main.post {
                        networkBusy = false
                        try {
                            val published = openOwners.publishIfCurrent(openOwner, sink) {
                                if (!foreground() || requestId != id) fail("staleSession")
                                if (request.microphone && (!microphonePermission.granted() ||
                                        permissionRevision != microphonePermissionRevision)) {
                                    fail("microphonePermissionRequired")
                                }
                                // Bind all private owners before making the session visible.
                                // Invalidation and this publication share one gate monitor.
                                observer.bind(opened)
                                safTransfers.sessionOpened(opened)
                                session = opened
                            }
                            if (!published) fail("staleSession")
                            observer.flush()
                            result.success(mapOf(
                                "schemaVersion" to opened.schemaVersion,
                                "unicodeTextInput" to opened.unicodeInputSupported,
                                "relativePointer" to opened.relativePointerSupported,
                            ))
                        } catch (failure: RdpNativeFailure) {
                            rejectOpened(openOwner, ownerSink, opened, fileTransfer)
                            error(result, failure.code)
                        } catch (_: Exception) {
                            rejectOpened(openOwner, ownerSink, opened, fileTransfer)
                            error(result, "connectionFailed")
                        }
                    }
                } catch (failure: RdpNativeFailure) {
                    failedOpenTransfer(fileTransfer)
                    password.fill('\u0000'); gateway.fill('\u0000')
                    main.post { networkBusy = false; error(result, failure.code) }
                } catch (_: Exception) {
                    failedOpenTransfer(fileTransfer)
                    password.fill('\u0000'); gateway.fill('\u0000')
                    main.post { networkBusy = false; error(result, "connectionFailed") }
                }
            }
        } catch (error: RuntimeException) {
            networkBusy = false
            failedOpenTransfer(fileTransfer)
            password.fill('\u0000'); gateway.fill('\u0000')
            throw error
        }
    }

    private inner class Observer(private val id: String) : RdpNativeSessionObserver {
        @Volatile private var frameSignalled = false
        @Volatile private var ownedSession: RdpFreeRdpSession? = null
        private var closedSignalled = false
        private var closedPosted = false

        fun bind(opened: RdpFreeRdpSession) {
            synchronized(this) {
                if (ownedSession != null) fail("connectionFailed")
                ownedSession = opened
            }
            dispatchClosed()
        }

        override fun onFrame() {
            frameSignalled = true
            flush()
        }

        fun flush() {
            if (!frameSignalled) return
            val current = ownedSession ?: return
            if (session !== current) return
            val frame = current.pendingFrame ?: return
            frameSignalled = false
            val pixels = ByteArray(frame.pixels.remaining())
            frame.pixels.duplicate().get(pixels)
            main.post {
                if (!foreground() || requestId != id || session !== current) {
                    pixels.fill(0)
                    retire()
                    return@post
                }
                try {
                    sink?.success(mapOf(
                        "requestId" to id,
                        "kind" to "frame",
                        "payload" to mapOf(
                            "schemaVersion" to current.schemaVersion,
                            "sequence" to frame.sequence,
                            "width" to frame.width,
                            "height" to frame.height,
                            "stride" to frame.stride,
                            "displayLayoutRevision" to frame.displayLayoutRevision,
                            "pixels" to pixels,
                        ),
                    ))
                } finally {
                    pixels.fill(0)
                }
            }
        }

        override fun onClosed(code: String?) {
            synchronized(this) { closedSignalled = true }
            dispatchClosed()
        }

        private fun dispatchClosed() {
            val closed = synchronized(this) {
                val owned = ownedSession
                if (!closedSignalled || closedPosted || owned == null) return
                closedPosted = true
                owned
            }
            main.post {
                if (requestId == id && session === closed) {
                    safTransfers.nativeClosed(closed)
                    sink?.success(mapOf("requestId" to id, "kind" to "disconnected", "payload" to null))
                    session = null
                }
            }
        }
    }

    private fun input(raw: Any?, result: MethodChannel.Result) {
        // StandardMessageCodec gives us the caller-owned ByteArray. Wipe it even
        // when foreground, shape, ownership, sequence or channel validation fails.
        val sensitivePayload = (raw as? Map<*, *>)?.get("payload") as? ByteArray
        try {
            requireForeground()
            val value = owned(raw,
                setOf("schemaVersion", "requestId", "sequence", "kind", "frameSequence", "width", "height", "displayLayoutRevision", "x", "y", "buttons"),
                setOf("schemaVersion", "requestId", "sequence", "kind", "frameSequence", "width", "height", "displayLayoutRevision", "deltaX", "deltaY", "buttons"),
                setOf("schemaVersion", "requestId", "sequence", "kind", "frameSequence", "width", "height", "displayLayoutRevision", "wheelDelta"),
                setOf("schemaVersion", "requestId", "sequence", "kind", "physicalKey", "down"),
                setOf("schemaVersion", "requestId", "sequence", "kind", "text"),
                setOf("schemaVersion", "requestId", "sequence", "kind", "channel", "payload"))
            val current = session ?: fail("staleSession")
            if (value["schemaVersion"] != current.schemaVersion) fail("invalidRequest")
            val sequence = sequence(value["sequence"])
            val accepted = when (value["kind"]) {
                "absolutePointer" -> current.absolutePointer(
                    sequence,
                    geometry(value),
                    (value["x"] as? Number)?.toDouble() ?: fail("invalidRequest"),
                    (value["y"] as? Number)?.toDouble() ?: fail("invalidRequest"),
                    integer(value["buttons"], 0, 7),
                )
                "relativePointer" -> current.relativePointer(
                    sequence,
                    geometry(value),
                    integer(value["deltaX"], Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt()),
                    integer(value["deltaY"], Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt()),
                    integer(value["buttons"], 0, 7),
                )
                "verticalWheel" -> current.verticalWheel(
                    sequence,
                    geometry(value),
                    integer(value["wheelDelta"], -120, 120).also {
                        if (it !in setOf(-120, 120)) fail("invalidRequest")
                    },
                )
                "key" -> current.key(
                    sequence,
                    (value["physicalKey"] as? Number)?.toLong() ?: fail("invalidRequest"),
                    value["down"] as? Boolean ?: fail("invalidRequest"),
                )
                "ime" -> current.ime(
                    sequence,
                    RdpNativeImeText.parse(value["text"]).value,
                )
                "channel" -> {
                    if (value["channel"] != "clipboard") fail("invalidRequest")
                    val payload = value["payload"] as? ByteArray ?: fail("invalidRequest")
                    validateClipboardPayload(payload)
                    current.channel(sequence, RdpJniChannel.CLIPBOARD, payload)
                }
                else -> fail("invalidRequest")
            }
            if (!accepted && value["kind"] == "key" && current.failureCode == null) {
                result.success(false)
                return
            }
            if (!accepted) fail(current.failureCode ?: "busy")
            result.success(null)
        } finally {
            sensitivePayload?.fill(0)
        }
    }

    private fun resize(raw: Any?, result: MethodChannel.Result) {
        requireForeground()
        val value = map(raw, setOf("schemaVersion", "requestId", "sequence", "display"))
        val current = session ?: fail("staleSession")
        if (value["schemaVersion"] != current.schemaVersion) fail("invalidRequest")
        ownedId(value)
        val display = map(value["display"], setOf("width", "height", "desktopScaleFactor", "deviceScaleFactor", "externalDisplay", "dynamicResize"))
        val width = integer(display["width"], 640, 8192)
        if (width % 2 != 0) fail("invalidRequest")
        val height = integer(display["height"], 480, 8192)
        if (width.toLong() * height > RdpNativeFrame.MAX_PIXELS) fail("invalidRequest")
        val accepted = current.resize(
            sequence(value["sequence"]),
            RdpNativeDisplay(
                width, height,
                integer(display["desktopScaleFactor"], 100, 500),
                integer(display["deviceScaleFactor"], 100, 180).also {
                    if (it !in setOf(100, 140, 180)) fail("invalidRequest")
                },
                display["externalDisplay"] as? Boolean ?: fail("invalidRequest"),
                display["dynamicResize"] as? Boolean ?: fail("invalidRequest"),
            ),
        )
        if (!accepted) fail(session?.failureCode ?: "busy")
        result.success(null)
    }

    private fun ack(raw: Any?, result: MethodChannel.Result) {
        requireForeground()
        val value = map(raw, setOf("schemaVersion", "requestId", "frameSequence"))
        val current = session ?: fail("staleSession")
        if (value["schemaVersion"] != current.schemaVersion) fail("invalidRequest")
        ownedId(value)
        val accepted = current.acknowledgeFrame(sequence(value["frameSequence"]))
        if (!accepted) fail(session?.failureCode ?: "staleSession")
        result.success(null)
    }

    private fun audioObservation(raw: Any?, result: MethodChannel.Result) {
        requireForeground()
        val value = map(raw, setOf("schemaVersion", "requestId"))
        val current = session ?: fail("staleSession")
        if (value["schemaVersion"] != current.schemaVersion) fail("invalidRequest")
        ownedId(value)
        val id = requestId ?: fail("staleSession")
        result.success(current.audioObservation().toChannel(id, current.schemaVersion))
    }

    private fun microphoneObservation(raw: Any?, result: MethodChannel.Result) {
        requireForeground()
        val value = map(raw, setOf("schemaVersion", "requestId"))
        val current = session ?: fail("staleSession")
        if (value["schemaVersion"] != current.schemaVersion) fail("invalidRequest")
        ownedId(value)
        if (!microphonePermission.granted()) {
            permissionRevoked()
            fail("staleSession")
        }
        val id = requestId ?: fail("staleSession")
        result.success(current.microphoneObservation().toChannel(id, current.schemaVersion))
    }

    private fun requestMicrophonePermission(raw: Any?, result: MethodChannel.Result) {
        requireForeground()
        if (session != null || networkBusy) fail("busy")
        val value = map(raw, setOf("schemaVersion", "requestId"))
        if (value["schemaVersion"] != 4) fail("invalidRequest")
        ownedId(value)
        microphonePermission.request(requestId ?: fail("staleSession"), result)
    }

    private fun cancelMicrophonePermission(raw: Any?, result: MethodChannel.Result) {
        val value = map(raw, setOf("schemaVersion", "requestId"))
        if (value["schemaVersion"] != 4) fail("invalidRequest")
        ownedId(value)
        microphonePermission.cancel(requestId ?: fail("staleSession"))
        result.success(null)
    }

    private fun cancel(raw: Any?, result: MethodChannel.Result) {
        val currentSchema = session?.schemaVersion
        if (raw is Map<*, *> && raw.containsKey("schemaVersion")) {
            val value = map(raw, setOf("schemaVersion", "requestId"))
            if (value["schemaVersion"] != 6) fail("invalidRequest")
            ownedId(value)
        } else {
            if (currentSchema == 6) fail("invalidRequest")
            raw?.let { owned(it, setOf("requestId")) }
        }
        retire()
        result.success(null)
    }

    private fun owned(raw: Any?, vararg shapes: Set<String>): Map<*, *> {
        val value = raw as? Map<*, *> ?: fail("invalidRequest")
        if (shapes.none { value.keys == it }) fail("invalidRequest")
        ownedId(value)
        return value
    }

    private fun geometry(value: Map<*, *>): RdpFreeRdpSession.DisplayedGeometry {
        val width = integer(value["width"], 640, 8192)
        val height = integer(value["height"], 480, 8192)
        if (width.toLong() * height > RdpNativeFrame.MAX_PIXELS) fail("invalidRequest")
        return RdpFreeRdpSession.DisplayedGeometry(
            sequence(value["frameSequence"]), width, height,
            sequence(value["displayLayoutRevision"]),
        )
    }

    private fun ownedId(value: Map<*, *>) {
        if (value["requestId"] != requestId) fail("staleSession")
    }

    private fun requireForeground() { if (!foreground()) fail("foregroundRequired") }
    private fun foreground() = !disposed && resumed && focused

    private fun openOwnerCurrent(owner: RdpOpenOwnerGate.Lease, id: String): Boolean =
        foreground() && requestId == id && openOwners.isCurrent(owner, sink)

    private fun retire() {
        val retiring = openOwners.invalidate {
            session.also { session = null }
        }
        pendingProbe?.close()
        pendingProbe = null
        retiring?.let {
            safTransfers.transportRetiring(it)
            it.close()
        }
    }

    private fun failedOpenTransfer(endpoint: RdpNativeFileTransferEndpoint?) {
        if (endpoint == null) return
        session?.takeIf { it.fileTransferEndpoint?.transferId == endpoint.transferId }?.let {
            safTransfers.transportRetiring(it)
            it.close()
            if (session === it) session = null
        }
        safTransfers.openFailed(endpoint)
    }

    private fun rejectOpened(
        owner: RdpOpenOwnerGate.Lease,
        ownerSink: EventChannel.EventSink,
        opened: RdpFreeRdpSession,
        endpoint: RdpNativeFileTransferEndpoint?,
    ) {
        openOwners.invalidateIfCurrent(owner, ownerSink) {
            if (session === opened) session = null
        }
        safTransfers.transportRetiring(opened)
        opened.close()
        safTransfers.openFailed(endpoint)
    }

    private fun permissionRevoked() {
        microphonePermissionRevision++
        if (session?.microphoneRequested == true) retire()
    }

    private fun retireMicrophoneIfPermissionMissing() {
        if (session?.microphoneRequested == true && !microphonePermission.granted()) {
            permissionRevoked()
        }
    }

    fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean = microphonePermission.onRequestPermissionsResult(
        requestCode, permissions, grantResults,
    )

    fun onActivityResult(requestCode: Int, resultCode: Int, data: android.content.Intent?): Boolean =
        safGrants.onActivityResult(requestCode, resultCode, data)

    fun dispose() {
        if (disposed) return
        disposed = true
        requestId?.let(microphonePermission::cancel)
        retire()
        safTransfers.close()
        microphonePermission.dispose()
        safGrants.dispose()
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        sink = null
        requestId = null
        worker.shutdownNow()
    }

    companion object {
        const val METHODS = "com.ersingundem.larenor/rdp-native"
        const val EVENTS = "com.ersingundem.larenor/rdp-native-events"
        private val UUID = Regex("[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}")
    }

    private data class OpenParameters(
        val requestId: String,
        val request: RdpNativeRequest,
        val permissionRevision: Long,
        val fileTransfer: RdpNativeFileTransferEndpoint?,
    )
}

internal fun RdpNativeCapabilities.toChannel(): Map<String, Any?> = mapOf(
    "schemaVersion" to 4,
    "availability" to availability.name.lowercase(),
    "engineRevision" to engineRevision,
    "security" to mapOf(
        "tls" to tls,
        "certificatePinning" to certificatePinning,
        "nla" to nla,
        "rdGateway" to rdGateway,
    ),
    "display" to mapOf(
        "dynamicResolution" to dynamicResolution, "externalDisplay" to externalDisplay,
        "maxWidth" to maxWidth, "maxHeight" to maxHeight,
        "desktopScaleFactorMin" to desktopScaleFactorMin,
        "desktopScaleFactorMax" to desktopScaleFactorMax,
        "deviceScaleFactors" to listOf(100, 140, 180).filter { it in deviceScaleFactors },
    ),
    "input" to mapOf(
        "absolutePointer" to absolutePointer,
        "relativePointerNegotiation" to relativePointerNegotiation,
        "verticalWheel" to verticalWheel,
        "keyboard" to keyboard,
        "ime" to ime,
    ),
    "channels" to mapOf(
        "clipboard" to clipboardModes.any { it != RdpClipboardMode.DISABLED },
        "clipboardModes" to RdpClipboardMode.entries.filter { it in clipboardModes }.map {
            when (it) {
                RdpClipboardMode.DISABLED -> "disabled"
                RdpClipboardMode.CLIENT_TO_REMOTE -> "clientToRemote"
                RdpClipboardMode.BIDIRECTIONAL -> "bidirectional"
            }
        },
        "audio" to audio, "microphone" to microphone, "files" to files,
    ),
)

private fun map(raw: Any?, keys: Set<String>): Map<*, *> {
    val value = raw as? Map<*, *> ?: fail("invalidRequest")
    if (value.keys != keys) fail("invalidRequest")
    return value
}

private fun safeText(raw: Any?, min: Int, max: Int): String {
    val value = raw as? String ?: fail("invalidRequest")
    if (value.length !in min..max || value != value.trim() || value.any {
            it.code < 32 || it.code == 127 || it.code in 0x202a..0x202e || it.code in 0x2066..0x2069
        }) fail("invalidRequest")
    return value
}

private fun safeHost(raw: Any?): String {
    val value = safeText(raw, 1, 253)
    if (Regex("[\\s/@\\\\?#%\\[\\]]").containsMatchIn(value)) fail("invalidRequest")
    return value
}

private data class RdpEnrollmentPeer(
    val host: String,
    val port: Int,
    val username: String,
    val domain: String,
    val pin: String?,
)

private fun enrollmentPeer(
    raw: Any?,
    includeDomain: Boolean,
    includePin: Boolean,
): RdpEnrollmentPeer {
    val keys = buildSet {
        add("host"); add("port"); add("username")
        if (includeDomain) add("domain")
        if (includePin) add("certificateFingerprint")
    }
    val value = map(raw, keys)
    val pin = if (includePin) safeText(value["certificateFingerprint"], 50, 50).also {
        if (!Regex("SHA256:[A-Za-z0-9+/]{43}").matches(it)) fail("invalidRequest")
    } else null
    return RdpEnrollmentPeer(
        safeHost(value["host"]),
        integer(value["port"], 1, 65535),
        safeText(value["username"], if (includeDomain) 1 else 0, 128),
        if (includeDomain) safeText(value["domain"], 0, 128) else "",
        pin,
    )
}

private fun integer(raw: Any?, min: Int, max: Int): Int {
    val value = when (raw) {
        is Int -> raw
        is Long -> if (raw in Int.MIN_VALUE..Int.MAX_VALUE) raw.toInt() else fail("invalidRequest")
        else -> fail("invalidRequest")
    }
    if (value !in min..max) fail("invalidRequest")
    return value
}

private fun sequence(raw: Any?): Long {
    val value = when (raw) {
        is Int -> raw.toLong()
        is Long -> raw
        else -> fail("invalidRequest")
    }
    if (value !in 1..9_007_199_254_740_991L) fail("invalidRequest")
    return value
}

private fun validateClipboardPayload(bytes: ByteArray) {
    if (bytes.isEmpty() || bytes.size > RdpFreeRdpSession.MAX_CHANNEL_BYTES || bytes.any { it == 0.toByte() }) {
        fail("invalidRequest")
    }
    val decoder = StandardCharsets.UTF_8.newDecoder()
        .onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT)
    val scratch = CharArray(bytes.size)
    try {
        val output = CharBuffer.wrap(scratch)
        val decoded = decoder.decode(ByteBuffer.wrap(bytes), output, true)
        if (decoded.isError) decoded.throwException()
        val flushed = decoder.flush(output)
        if (flushed.isError) flushed.throwException()
    } catch (_: Exception) {
        fail("invalidRequest")
    } finally {
        scratch.fill('\u0000')
    }
}

private fun decode(bytes: ByteArray, empty: Boolean): CharArray {
    if (bytes.size > 4096 || (!empty && bytes.isEmpty())) fail("invalidSecrets")
    val decoder = StandardCharsets.UTF_8.newDecoder()
        .onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT)
    val scratch = CharArray(bytes.size)
    return try {
        val output = CharBuffer.wrap(scratch)
        val result = decoder.decode(ByteBuffer.wrap(bytes), output, true)
        if (result.isError) result.throwException()
        val flushed = decoder.flush(output)
        if (flushed.isError) flushed.throwException()
        scratch.copyOf(output.position()).also { scratch.fill('\u0000') }
    } catch (_: Exception) {
        scratch.fill('\u0000')
        fail("invalidSecrets")
    }
}

private fun fail(code: String): Nothing = throw RdpNativeFailure(code)
private fun error(result: MethodChannel.Result, code: String) =
    result.error(code, "Native RDP operation rejected", mapOf("retryable" to false))
