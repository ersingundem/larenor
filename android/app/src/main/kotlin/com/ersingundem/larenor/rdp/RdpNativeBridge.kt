package com.ersingundem.larenor.rdp

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
        type.getConstructor(Context::class.java).newInstance(context.applicationContext) as RdpJniRuntime
    } catch (_: LinkageError) {
        null
    } catch (_: ReflectiveOperationException) {
        null
    } catch (_: Exception) {
        null
    }
}

class RdpNativeBridge(
    context: Context,
    messenger: BinaryMessenger,
    runtime: RdpJniRuntime? = RdpJniRuntimeLoader.load(context),
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "larenor-rdp").apply { isDaemon = true }
    }
    private val methods = MethodChannel(messenger, METHODS)
    private val events = EventChannel(messenger, EVENTS)
    private val runtime = runtime
    private val adapter = RdpNativeAdapter(RdpFreeRdpBackend(runtime))
    private var sink: EventChannel.EventSink? = null
    private var resumed = false
    private var focused = true
    private var disposed = false
    private var requestId: String? = null
    private var networkBusy = false
    @Volatile private var session: RdpFreeRdpSession? = null

    init {
        methods.setMethodCallHandler(this)
        events.setStreamHandler(this)
    }

    fun setResumed(value: Boolean) {
        if (disposed) return
        resumed = value
        if (!value) retire()
    }

    fun setWindowFocused(value: Boolean) {
        if (disposed) return
        focused = value
        if (!value) retire()
    }

    override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink) {
        if (disposed || arguments !is String || !UUID.matches(arguments) || sink != null) {
            eventSink.error("invalidRequest", "RDP event owner rejected", null)
            return
        }
        requestId = arguments
        sink = eventSink
    }

    override fun onCancel(arguments: Any?) {
        if (arguments == requestId) {
            retire()
            sink = null
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (disposed) return error(result, "engineUnavailable")
        try {
            when (call.method) {
                "capabilities" -> {
                    if (call.arguments != null) fail("invalidRequest")
                    result.success(adapter.capabilities().toChannel())
                }
                "activate" -> {
                    requireForeground()
                    val value = map(call.arguments, setOf("requestId"))
                    val id = value["requestId"] as? String ?: fail("invalidRequest")
                    if (!UUID.matches(id) || requestId != id || sink == null) fail("staleSession")
                    result.success(null)
                }
                "inspect" -> inspect(call.arguments, result)
                "open" -> open(call.arguments, result)
                "input" -> input(call.arguments, result)
                "resize" -> resize(call.arguments, result)
                "ackFrame" -> ack(call.arguments, result)
                "cancel" -> cancel(call.arguments, result)
                else -> result.notImplemented()
            }
        } catch (failure: RdpNativeFailure) {
            if (call.method != "capabilities" && call.method != "inspect") retire()
            error(result, failure.code)
        } catch (_: Exception) {
            if (call.method != "capabilities") retire()
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

    private fun open(raw: Any?, result: MethodChannel.Result) {
        requireForeground()
        if (session != null || networkBusy) fail("busy")
        val value = map(raw, setOf("schemaVersion", "request", "requestId", "password", "gatewayPassword"))
        if (value["schemaVersion"] != 2) fail("invalidRequest")
        val id = value["requestId"] as? String ?: fail("invalidRequest")
        if (!UUID.matches(id) || id != requestId || sink == null) fail("staleSession")
        val request = RdpNativeRequest.parse(value["request"])
        if (request.requestId != id) fail("invalidRequest")
        val passwordBytes = value["password"] as? ByteArray ?: fail("invalidSecrets")
        val gatewayBytes = value["gatewayPassword"] as? ByteArray ?: fail("invalidSecrets")
        val password = decode(passwordBytes, false)
        val gateway = decode(gatewayBytes, true)
        passwordBytes.fill(0)
        gatewayBytes.fill(0)
        networkBusy = true
        try {
            worker.execute {
                try {
                    val secrets = RdpNativeSecrets.take(password, gateway.takeIf { request.gateway != null })
                    if (request.gateway == null) gateway.fill('\u0000')
                    val observer = Observer(id)
                    val opened = adapter.open(request, secrets, observer) as RdpFreeRdpSession
                    session = opened
                    observer.flush()
                    main.post {
                        networkBusy = false
                        if (!foreground() || requestId != id) {
                            opened.close()
                            error(result, "staleSession")
                        } else {
                            result.success(mapOf(
                                "schemaVersion" to 2,
                                "unicodeTextInput" to opened.unicodeInputSupported,
                                "relativePointer" to opened.relativePointerSupported,
                            ))
                        }
                    }
                } catch (failure: RdpNativeFailure) {
                    password.fill('\u0000'); gateway.fill('\u0000')
                    main.post { networkBusy = false; error(result, failure.code) }
                } catch (_: Exception) {
                    password.fill('\u0000'); gateway.fill('\u0000')
                    main.post { networkBusy = false; error(result, "connectionFailed") }
                }
            }
        } catch (error: RuntimeException) {
            networkBusy = false
            password.fill('\u0000'); gateway.fill('\u0000')
            throw error
        }
    }

    private inner class Observer(private val id: String) : RdpNativeSessionObserver {
        @Volatile private var frameSignalled = false
        override fun onFrame() {
            frameSignalled = true
            flush()
        }

        fun flush() {
            if (!frameSignalled) return
            val current = session ?: return
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
                            "schemaVersion" to 2,
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
            main.post {
                if (requestId == id) {
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
            if (value["schemaVersion"] != 2) fail("invalidRequest")
            val current = session ?: fail("staleSession")
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
        if (value["schemaVersion"] != 2) fail("invalidRequest")
        ownedId(value)
        val display = map(value["display"], setOf("width", "height", "desktopScaleFactor", "deviceScaleFactor", "externalDisplay", "dynamicResize"))
        val width = integer(display["width"], 640, 8192)
        if (width % 2 != 0) fail("invalidRequest")
        val height = integer(display["height"], 480, 8192)
        if (width.toLong() * height > RdpNativeFrame.MAX_PIXELS) fail("invalidRequest")
        val accepted = (session ?: fail("staleSession")).resize(
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
        if (value["schemaVersion"] != 2) fail("invalidRequest")
        ownedId(value)
        val accepted = (session ?: fail("staleSession")).acknowledgeFrame(sequence(value["frameSequence"]))
        if (!accepted) fail(session?.failureCode ?: "staleSession")
        result.success(null)
    }

    private fun cancel(raw: Any?, result: MethodChannel.Result) {
        if (raw != null) {
            val value = map(raw, setOf("requestId"))
            ownedId(value)
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

    private fun retire() {
        session?.close()
        session = null
    }

    fun dispose() {
        if (disposed) return
        disposed = true
        retire()
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
}

internal fun RdpNativeCapabilities.toChannel(): Map<String, Any?> = mapOf(
    "schemaVersion" to 2,
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
        "audio" to audio, "files" to files,
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
