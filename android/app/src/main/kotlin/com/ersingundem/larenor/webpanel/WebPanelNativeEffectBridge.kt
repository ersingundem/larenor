package com.ersingundem.larenor.webpanel

import android.app.Activity
import android.speech.tts.TextToSpeech
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

internal enum class NativeEffectOutcome { ACCEPTED, REJECTED, UNSUPPORTED, UNCERTAIN }

internal data class NativeEffectResult(
    val operationId: String,
    val outcome: NativeEffectOutcome,
    val receiptHandle: String? = null,
)

internal data class WebPanelEffectScope(
    val coreId: String,
    val homeId: String,
    val accountId: String,
    val sessionFamily: String,
    val sourceId: String,
    val sourceRevision: Int,
    val policyRevision: Int,
    val routeEpoch: Int,
    val lifecycleEpoch: Int,
    val topOrigin: String,
) {
    fun valid(): Boolean = ID.matches(coreId) && ID.matches(homeId) && ID.matches(sessionFamily) &&
        SAFE_ID.matches(sourceId) && safeAccount(accountId) && sourceRevision > 0 &&
        policyRevision > 0 && routeEpoch > 0 && lifecycleEpoch > 0 && secureOrigin(topOrigin)

    companion object {
        private val ID = Regex("^[0-9a-f]{32}$")
        private val SAFE_ID = Regex("^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
        private fun safeAccount(value: String) = value.isNotEmpty() && value.length <= 128 &&
            value.none { it.code < 0x20 || it.code == 0x7f }
        private fun secureOrigin(value: String): Boolean = runCatching {
            val uri = android.net.Uri.parse(value)
            !uri.isOpaque && uri.scheme == "https" && uri.userInfo == null && uri.host != null &&
                (uri.path.isNullOrEmpty() || uri.path == "/") && uri.query == null && uri.fragment == null
        }.getOrDefault(false)
    }
}

internal data class WebPanelEffectRequest(
    val ownerId: String,
    val operationId: String,
    val method: String,
    val payload: Map<String, Any?>,
    val scope: WebPanelEffectScope,
)

internal interface WebPanelSpeechHost : AutoCloseable {
    fun speak(text: String, locale: String?, receipt: String): Boolean
    fun stop()
}

internal interface WebPanelPrintHost : AutoCloseable {
    fun print(handle: String, title: String?, receipt: String): Boolean
    fun cancel()
}

internal interface WebPanelQrHost : AutoCloseable {
    fun scan(formats: Set<String>, receipt: String): Boolean
    fun cancel()
}

internal class WebPanelNativeEffectRuntime(
    private val speech: WebPanelSpeechHost,
    private val printer: WebPanelPrintHost,
    private val qr: WebPanelQrHost,
) : AutoCloseable {
    private var resumed = false
    private var ownerId: String? = null
    private var scope: WebPanelEffectScope? = null
    private val receipts = LinkedHashMap<String, String>()

    fun setResumed(value: Boolean) {
        resumed = value
        if (!value) cancelEffects()
    }

    fun bind(ownerId: String, scope: WebPanelEffectScope): Boolean {
        if (!OPAQUE.matches(ownerId) || !scope.valid()) return false
        if (this.ownerId != null && (this.ownerId != ownerId || this.scope != scope)) cancelEffects()
        this.ownerId = ownerId
        this.scope = scope
        receipts.clear()
        return true
    }

    fun retire(ownerId: String): Boolean {
        if (this.ownerId != ownerId) return false
        cancelEffects()
        this.ownerId = null
        scope = null
        receipts.clear()
        return true
    }

    fun execute(value: WebPanelEffectRequest): NativeEffectResult {
        if (!resumed || ownerId != value.ownerId || scope != value.scope ||
            !OPAQUE.matches(value.operationId) || !value.scope.valid()
        ) return rejected(value)
        if (receipts.containsKey(value.operationId)) return rejected(value)
        val accepted = when (value.method) {
            "speak" -> executeSpeech(value)
            "printDocument" -> executePrint(value)
            "scanQr" -> executeQr(value)
            else -> false
        }
        if (!accepted) return rejected(value)
        receipts[value.operationId] = value.ownerId
        while (receipts.size > 128) receipts.remove(receipts.keys.first())
        return NativeEffectResult(value.operationId, NativeEffectOutcome.ACCEPTED, value.operationId)
    }

    fun readback(receipt: String, operationId: String): Boolean =
        OPAQUE.matches(receipt) && receipt == operationId && receipts[receipt] == ownerId

    private fun executeSpeech(value: WebPanelEffectRequest): Boolean {
        if (value.payload.keys !in setOf(setOf("text"), setOf("text", "locale"))) return false
        val text = value.payload["text"] as? String ?: return false
        if (!safeText(text, 500)) return false
        val locale = value.payload["locale"]
        if (locale != null && (locale !is String || !LOCALE.matches(locale))) return false
        return speech.speak(text, locale as String?, value.operationId)
    }

    private fun executePrint(value: WebPanelEffectRequest): Boolean {
        if (value.payload.keys !in setOf(setOf("documentHandle"), setOf("documentHandle", "title"))) return false
        val handle = value.payload["documentHandle"] as? String ?: return false
        if (!SAFE_HANDLE.matches(handle)) return false
        val title = value.payload["title"]
        if (title != null && (title !is String || !safeText(title, 120))) return false
        return printer.print(handle, title as String?, value.operationId)
    }

    private fun executeQr(value: WebPanelEffectRequest): Boolean {
        if (value.payload.keys !in setOf(emptySet(), setOf("formats"))) return false
        val formats = value.payload["formats"] ?: listOf("qr")
        if (formats !is List<*> || formats.isEmpty() || formats.size > 2) return false
        val values = formats.map { it as? String ?: return false }.toSet()
        if (values.size != formats.size || !setOf("qr", "dataMatrix").containsAll(values)) return false
        return qr.scan(values, value.operationId)
    }

    private fun cancelEffects() {
        speech.stop()
        printer.cancel()
        qr.cancel()
    }

    override fun close() {
        cancelEffects()
        ownerId = null
        scope = null
        receipts.clear()
        speech.close()
        printer.close()
        qr.close()
    }

    private fun rejected(value: WebPanelEffectRequest) =
        NativeEffectResult(value.operationId, NativeEffectOutcome.REJECTED)

    companion object {
        private val OPAQUE = Regex("^[0-9a-f]{32}$")
        private val SAFE_HANDLE = Regex("^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
        private val LOCALE = Regex("^[a-z]{2,3}(?:-[A-Z]{2})?$")
        private fun safeText(value: String, max: Int) = value.isNotEmpty() && value.length <= max &&
            value.none { it.code < 0x20 || it.code == 0x7f }
    }
}

internal class AndroidWebPanelSpeechHost(activity: Activity) : WebPanelSpeechHost {
    private var ready = false
    private var closed = false
    private var tts: TextToSpeech? = null

    init {
        tts = TextToSpeech(activity.applicationContext) { status ->
        ready = status == TextToSpeech.SUCCESS && !closed
        }
    }

    override fun speak(text: String, locale: String?, receipt: String): Boolean {
        if (closed || !ready) return false
        if (locale != null) {
            val parsed = Locale.forLanguageTag(locale)
            val engine = tts ?: return false
            if (parsed.language.isBlank() || engine.isLanguageAvailable(parsed) < TextToSpeech.LANG_AVAILABLE) {
                return false
            }
            engine.language = parsed
        }
        return tts?.speak(text, TextToSpeech.QUEUE_FLUSH, null, receipt) == TextToSpeech.SUCCESS
    }

    override fun stop() { if (!closed) runCatching { tts?.stop() } }
    override fun close() {
        if (closed) return
        closed = true
        runCatching { tts?.stop() }
        runCatching { tts?.shutdown() }
        tts = null
    }
}

internal object UnsupportedWebPanelPrintHost : WebPanelPrintHost {
    override fun print(handle: String, title: String?, receipt: String) = false
    override fun cancel() = Unit
    override fun close() = Unit
}

internal object UnsupportedWebPanelQrHost : WebPanelQrHost {
    override fun scan(formats: Set<String>, receipt: String) = false
    override fun cancel() = Unit
    override fun close() = Unit
}

internal class WebPanelNativeEffectBridge(
    activity: Activity,
    messenger: BinaryMessenger,
    speech: WebPanelSpeechHost = AndroidWebPanelSpeechHost(activity),
    printer: WebPanelPrintHost = UnsupportedWebPanelPrintHost,
    qr: WebPanelQrHost = UnsupportedWebPanelQrHost,
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, CHANNEL)
    private val runtime = WebPanelNativeEffectRuntime(speech, printer, qr)
    private var disposed = false

    init { channel.setMethodCallHandler(this) }
    fun setResumed(value: Boolean) { if (!disposed) runtime.setResumed(value) }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (disposed) return result.error("unavailable", "Native effects unavailable", null)
        try {
            when (call.method) {
                "bind" -> {
                    val map = exactMap(call.arguments, setOf("ownerId", "scope"))
                    result.success(runtime.bind(text(map, "ownerId"), parseScope(map["scope"])))
                }
                "execute" -> result.success(runtime.execute(parseRequest(call.arguments)).toMap())
                "readback" -> {
                    val map = exactMap(call.arguments, setOf("receiptHandle", "operationId"))
                    result.success(runtime.readback(text(map, "receiptHandle"), text(map, "operationId")))
                }
                "retire" -> {
                    val map = exactMap(call.arguments, setOf("ownerId"))
                    result.success(runtime.retire(text(map, "ownerId")))
                }
                "capabilities" -> result.success(mapOf("revision" to 1, "methods" to listOf("speak")))
                else -> result.notImplemented()
            }
        } catch (_: IllegalArgumentException) {
            result.error("invalidRequest", "Native effect request rejected", null)
        } catch (_: RuntimeException) {
            result.error("unavailable", "Native effects unavailable", null)
        }
    }

    fun dispose() {
        if (disposed) return
        disposed = true
        channel.setMethodCallHandler(null)
        runtime.close()
    }

    companion object { const val CHANNEL = "com.ersingundem.larenor/web_panel_native_effects" }
}

private fun NativeEffectResult.toMap() = mapOf(
    "operationId" to operationId,
    "outcome" to outcome.name.lowercase(),
    "receiptHandle" to receiptHandle,
)

private fun parseRequest(raw: Any?): WebPanelEffectRequest {
    val map = exactMap(raw, setOf("ownerId", "operationId", "method", "payload", "scope"))
    @Suppress("UNCHECKED_CAST")
    val payload = map["payload"] as? Map<String, Any?> ?: throw IllegalArgumentException()
    return WebPanelEffectRequest(
        text(map, "ownerId"), text(map, "operationId"), text(map, "method"),
        payload, parseScope(map["scope"]),
    )
}

private fun parseScope(raw: Any?): WebPanelEffectScope {
    val keys = setOf("coreId", "homeId", "accountId", "sessionFamily", "sourceId", "sourceRevision", "policyRevision", "routeEpoch", "lifecycleEpoch", "topOrigin")
    val map = exactMap(raw, keys)
    return WebPanelEffectScope(
        text(map, "coreId"), text(map, "homeId"), text(map, "accountId"), text(map, "sessionFamily"),
        text(map, "sourceId"), integer(map, "sourceRevision"), integer(map, "policyRevision"),
        integer(map, "routeEpoch"), integer(map, "lifecycleEpoch"), text(map, "topOrigin"),
    )
}

private fun exactMap(raw: Any?, keys: Set<String>): Map<*, *> {
    val map = raw as? Map<*, *> ?: throw IllegalArgumentException()
    if (map.keys != keys) throw IllegalArgumentException()
    return map
}
private fun text(map: Map<*, *>, key: String) = map[key] as? String ?: throw IllegalArgumentException()
private fun integer(map: Map<*, *>, key: String): Int = when (val value = map[key]) {
    is Int -> value
    is Long -> value.takeIf { it in 1..Int.MAX_VALUE }?.toInt()
    else -> null
} ?: throw IllegalArgumentException()
