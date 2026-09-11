package com.ersingundem.larenor.vnc

import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.nio.CharBuffer
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets

interface VncNativeInputSession : VncNativeSession {
    fun input(sequence: Long, event: Map<String, Any>): Boolean
}

private data class VncBridgeBinding(
    val ownerId: String,
    val accountRevision: Long,
    val routeRevision: Long,
) {
    fun toChannel(): Map<String, Any> = mapOf(
        "ownerId" to ownerId,
        "accountRevision" to accountRevision,
        "routeRevision" to routeRevision,
    )

    companion object {
        fun parse(raw: Any?): VncBridgeBinding {
            val map = raw as? Map<*, *> ?: failBridge("invalidRequest")
            if (map.keys != setOf("ownerId", "accountRevision", "routeRevision")) {
                failBridge("invalidRequest")
            }
            val owner = map["ownerId"] as? String ?: failBridge("invalidRequest")
            if (!Regex("[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}").matches(owner)) {
                failBridge("invalidRequest")
            }
            return VncBridgeBinding(
                owner,
                revision(map["accountRevision"]),
                revision(map["routeRevision"]),
            )
        }

        private fun revision(raw: Any?): Long {
            val value = (raw as? Number)?.toLong() ?: failBridge("invalidRequest")
            if (value < 0 || value > 9_007_199_254_740_991L) failBridge("invalidRequest")
            return value
        }
    }
}

private fun failBridge(code: String): Nothing = throw VncNativeFailure(code)

private fun bridgeMap(raw: Any?, keys: Set<String>): Map<*, *> {
    val map = raw as? Map<*, *> ?: failBridge("invalidRequest")
    if (map.keys != keys) failBridge("invalidRequest")
    return map
}

private fun positiveSequence(raw: Any?): Long {
    val value = (raw as? Number)?.toLong() ?: failBridge("invalidRequest")
    if (value !in 1..9_007_199_254_740_991L) failBridge("invalidRequest")
    return value
}

private fun VncNativeCapabilities.toChannel(): Map<String, Any?> = mapOf(
    "schemaVersion" to 1,
    "availability" to availability.name.lowercase(),
    "engineRevision" to engineRevision,
    "rfbVersions" to rfbVersions.sorted(),
    "securityTypes" to securityTypes.map {
        when (it) {
            VncSecurityType.VENCRYPT_TLS_VNC_AUTH -> "vencryptTlsVncAuth"
            VncSecurityType.VNC_AUTH -> "vncAuth"
            VncSecurityType.NONE -> "none"
        }
    }.sorted(),
    "transport" to mapOf("tls" to tls, "spkiPinning" to spkiPinning),
    "auth" to mapOf("password" to passwordAuth),
    "framebuffer" to mapOf(
        "encodings" to encodings.map {
            when (it) {
                VncFramebufferEncoding.TIGHT -> "tight"
                VncFramebufferEncoding.ZRLE -> "zrle"
                VncFramebufferEncoding.RAW -> "raw"
            }
        }.sorted(),
        "trueColor32" to trueColor32,
        "dynamicResolution" to dynamicResolution,
        "externalDisplay" to externalDisplay,
        "maxWidth" to maxWidth,
        "maxHeight" to maxHeight,
        "maxDpi" to maxDpi,
    ),
    "input" to mapOf("pointer" to pointer, "keyboard" to keyboard, "clipboard" to clipboard),
)

class VncNativeBridge(
    messenger: BinaryMessenger,
    private val adapter: VncNativeAdapter = VncNativeAdapter(),
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private val methods = MethodChannel(messenger, METHODS)
    private val events = EventChannel(messenger, EVENTS)
    private var sink: EventChannel.EventSink? = null
    private var resumed = false
    private var windowFocused = true
    private var disposed = false
    private var binding: VncBridgeBinding? = null
    private var session: VncNativeSession? = null
    private var request: VncNativeRequest? = null
    private var lastInputSequence = 0L
    private var nextFrameSequence = 1L
    private var pendingFrameSequence: Long? = null

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
        windowFocused = value
        if (!value) retire()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (disposed) {
            error(result, "engineUnavailable")
            return
        }
        try {
            when (call.method) {
                "capabilities" -> {
                    if (call.arguments != null) failBridge("invalidRequest")
                    result.success(adapter.capabilities().toChannel())
                }
                "activate" -> {
                    requireForeground()
                    val next = VncBridgeBinding.parse(call.arguments)
                    val current = binding
                    if (current != null && current != next) failBridge("busy")
                    binding = next
                    result.success(null)
                }
                "open" -> open(call.arguments, result)
                "cancel" -> {
                    val requested = VncBridgeBinding.parse(call.arguments)
                    val current = binding
                    if (current != null && current != requested) failBridge("staleSession")
                    retire()
                    result.success(null)
                }
                "input" -> input(call.arguments, result)
                "ackFrame" -> acknowledge(call.arguments, result)
                else -> result.notImplemented()
            }
        } catch (failure: VncNativeFailure) {
            if (call.method == "open" ||
                call.method == "ackFrame" ||
                call.method == "input" && failure.code != "busy") {
                retire()
            }
            error(result, failure.code)
        } catch (_: Exception) {
            if (call.method in setOf("open", "input", "ackFrame")) retire()
            error(result, "connectionFailed")
        }
    }

    private fun open(raw: Any?, result: MethodChannel.Result) {
        requireForeground()
        val value = bridgeMap(raw, setOf(
            "binding", "request", "expectedEngineRevision", "password",
        ))
        val requestedBinding = VncBridgeBinding.parse(value["binding"])
        requireBinding(requestedBinding)
        if (session != null) failBridge("busy")
        val password = value["password"] as? ByteArray ?: failBridge("invalidRequest")
        try {
            if (password.isEmpty() || password.size > 4096) failBridge("invalidSecrets")
            val expectedRevision = value["expectedEngineRevision"]?.let {
                val revision = it as? String ?: failBridge("invalidRequest")
                if (!Regex("[A-Za-z0-9][A-Za-z0-9._+-]{0,63}").matches(revision)) {
                    failBridge("invalidRequest")
                }
                revision
            }
            val parsedRequest = VncNativeRequest.parse(value["request"])
            val secrets = VncNativeSecrets.take(decodePassword(password))
            val opened = adapter.open(parsedRequest, secrets, expectedRevision)
            try {
                requireForeground()
                requireBinding(requestedBinding)
                session = opened
                request = parsedRequest
                lastInputSequence = 0
                nextFrameSequence = 1
                pendingFrameSequence = null
                result.success(mapOf(
                    "sessionId" to parsedRequest.requestId,
                    "requestId" to parsedRequest.requestId,
                ))
            } catch (failure: Exception) {
                opened.close()
                throw failure
            }
        } finally {
            password.fill(0)
        }
    }

    private fun decodePassword(bytes: ByteArray): CharArray {
        val decoder = StandardCharsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
        val scratch = CharArray(bytes.size)
        val output = CharBuffer.wrap(scratch)
        try {
            val decoded = decoder.decode(ByteBuffer.wrap(bytes), output, true)
            if (decoded.isError) decoded.throwException()
            val flushed = decoder.flush(output)
            if (flushed.isError) flushed.throwException()
            val result = scratch.copyOf(output.position())
            scratch.fill('\u0000')
            return result
        } catch (_: Exception) {
            scratch.fill('\u0000')
            failBridge("invalidSecrets")
        }
    }

    private fun input(raw: Any?, result: MethodChannel.Result) {
        requireForeground()
        val value = bridgeMap(raw, setOf("binding", "sequence", "event"))
        requireBinding(VncBridgeBinding.parse(value["binding"]))
        val sequence = positiveSequence(value["sequence"])
        if (sequence != lastInputSequence + 1) failBridge("staleSession")
        val interactive = session as? VncNativeInputSession ?: failBridge("inputUnavailable")
        val event = parseInput(value["event"])
        if (event["kind"] == "clipboard" && request?.clipboard != true) {
            failBridge("inputUnavailable")
        }
        if (!interactive.input(sequence, event)) failBridge("busy")
        lastInputSequence = sequence
        result.success(null)
    }

    private fun parseInput(raw: Any?): Map<String, Any> {
        val value = raw as? Map<*, *> ?: failBridge("invalidRequest")
        return when (value["kind"]) {
            "key" -> {
                if (value.keys != setOf("kind", "code", "down")) failBridge("invalidRequest")
                val code = (value["code"] as? Number)?.toInt() ?: failBridge("invalidRequest")
                val down = value["down"] as? Boolean ?: failBridge("invalidRequest")
                if (code !in 1..0xffff) failBridge("invalidRequest")
                mapOf("kind" to "key", "code" to code, "down" to down)
            }
            "pointer" -> {
                if (value.keys != setOf("kind", "x", "y", "buttons")) failBridge("invalidRequest")
                val x = (value["x"] as? Number)?.toDouble() ?: failBridge("invalidRequest")
                val y = (value["y"] as? Number)?.toDouble() ?: failBridge("invalidRequest")
                val buttons = (value["buttons"] as? Number)?.toInt() ?: failBridge("invalidRequest")
                if (!x.isFinite() || !y.isFinite() || x !in 0.0..1.0 || y !in 0.0..1.0 || buttons !in 0..31) {
                    failBridge("invalidRequest")
                }
                mapOf("kind" to "pointer", "x" to x, "y" to y, "buttons" to buttons)
            }
            "clipboard" -> {
                if (value.keys != setOf("kind", "text")) failBridge("invalidRequest")
                val text = value["text"] as? String ?: failBridge("invalidRequest")
                if (text.isEmpty() || text.length > 65_536 || text.indexOf('\u0000') >= 0) {
                    failBridge("invalidRequest")
                }
                val encoded = text.toByteArray(StandardCharsets.UTF_8)
                try {
                    if (encoded.size > 65_536) failBridge("invalidRequest")
                } finally {
                    encoded.fill(0)
                }
                mapOf("kind" to "clipboard", "text" to text)
            }
            else -> failBridge("invalidRequest")
        }
    }

    private fun acknowledge(raw: Any?, result: MethodChannel.Result) {
        requireForeground()
        val value = bridgeMap(raw, setOf("binding", "sequence"))
        requireBinding(VncBridgeBinding.parse(value["binding"]))
        val sequence = positiveSequence(value["sequence"])
        if (sequence != pendingFrameSequence) {
            retire()
            failBridge("staleSession")
        }
        pendingFrameSequence = null
        nextFrameSequence++
        result.success(null)
    }

    fun publishFrame(
        rawBinding: Any?,
        sequence: Long,
        width: Int,
        height: Int,
        byteLength: Int,
    ): Boolean {
        if (disposed || !resumed || !windowFocused || session == null || sink == null) return false
        val found = try { VncBridgeBinding.parse(rawBinding) } catch (_: VncNativeFailure) { return false }
        if (found != binding) return false
        val activeRequest = request ?: return false
        if (pendingFrameSequence != null) return false
        if (sequence != nextFrameSequence || width != activeRequest.display.width ||
            height != activeRequest.display.height || byteLength <= 0 || byteLength > MAX_FRAME_BYTES ||
            byteLength.toLong() > width.toLong() * height * 4L) {
            retire()
            return false
        }
        pendingFrameSequence = sequence
        return try {
            sink?.success(found.toChannel() + mapOf(
                "sessionId" to activeRequest.requestId,
                "sequence" to sequence,
                "width" to width,
                "height" to height,
                "byteLength" to byteLength,
            ))
            true
        } catch (_: Exception) {
            retire()
            false
        }
    }

    private fun requireForeground() {
        if (!resumed || !windowFocused) failBridge("foregroundRequired")
    }

    private fun requireBinding(value: VncBridgeBinding) {
        if (value != binding) failBridge("staleSession")
    }

    private fun retire() {
        val current = session
        session = null
        request = null
        binding = null
        pendingFrameSequence = null
        lastInputSequence = 0
        nextFrameSequence = 1
        current?.close()
    }

    private fun error(result: MethodChannel.Result, code: String) {
        val safe = try { VncNativeFailure(code).code } catch (_: VncNativeFailure) { "connectionFailed" }
        result.error(safe, "Native VNC unavailable", null)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        if (disposed || arguments != null) {
            events.endOfStream()
            return
        }
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
        retire()
    }

    fun dispose() {
        if (disposed) return
        disposed = true
        retire()
        sink = null
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
    }

    companion object {
        const val METHODS = "com.ersingundem.larenor/vnc_native"
        const val EVENTS = "com.ersingundem.larenor/vnc_native_frames"
        const val MAX_FRAME_BYTES = 16 * 1024 * 1024
    }
}
