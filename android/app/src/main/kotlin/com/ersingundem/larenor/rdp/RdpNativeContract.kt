package com.ersingundem.larenor.rdp

enum class RdpNativeAvailability { UNAVAILABLE, AVAILABLE }
enum class RdpClipboardMode { DISABLED, CLIENT_TO_REMOTE, BIDIRECTIONAL }
enum class RdpKeyboardLayout { AUTOMATIC, TURKISH_Q, US }

class RdpNativeFailure(val code: String) : RuntimeException("Native RDP operation rejected") {
    init {
        if (code !in codes) {
            throw RdpNativeFailure("invalidFailure")
        }
    }

    fun publicDetails(): Map<String, Any> = mapOf("code" to code, "retryable" to false)
    override fun toString() = "RdpNativeFailure($code)"

    companion object {
        private val codes = setOf(
            "invalidFailure", "invalidCapabilities", "invalidRequest", "invalidSecrets",
            "engineUnavailable", "tlsRequired", "certificatePinningRequired", "nlaUnavailable",
            "gatewayUnavailable", "displayUnavailable", "inputUnavailable", "clipboardUnavailable",
            "foregroundRequired", "busy", "timedOut", "cancelled", "staleSession", "connectionFailed",
        )
    }
}

private fun fail(code: String): Nothing = throw RdpNativeFailure(code)
private fun strictMap(value: Any?, keys: Set<String>, code: String): Map<*, *> {
    val map = value as? Map<*, *> ?: fail(code)
    if (map.keys != keys) fail(code)
    return map
}
private fun bool(map: Map<*, *>, key: String, code: String) = map[key] as? Boolean ?: fail(code)
private fun int(map: Map<*, *>, key: String, min: Int, max: Int, code: String): Int {
    val value = map[key] as? Int ?: fail(code)
    if (value !in min..max) fail(code)
    return value
}
private fun text(value: Any?, min: Int, max: Int, code: String): String {
    val result = value as? String ?: fail(code)
    if (result.length !in min..max || result != result.trim() || result.any {
            it.code < 32 || it.code == 127 || it.code in 0x202a..0x202e || it.code in 0x2066..0x2069
        }) fail(code)
    return result
}
private fun enumName(value: Any?, values: Set<String>, code: String): String {
    val result = text(value, 1, 32, code)
    if (result !in values) fail(code)
    return result
}

class RdpNativeCapabilities private constructor(
    val availability: RdpNativeAvailability,
    val engineRevision: String?,
    val tls: Boolean,
    val certificatePinning: Boolean,
    val nla: Boolean,
    val rdGateway: Boolean,
    val dynamicResolution: Boolean,
    val externalDisplay: Boolean,
    val maxWidth: Int,
    val maxHeight: Int,
    val maxDpi: Int,
    val pointer: Boolean,
    val keyboard: Boolean,
    val clipboardModes: Set<RdpClipboardMode>,
) {
    val canConnect get() = availability == RdpNativeAvailability.AVAILABLE && tls &&
        certificatePinning && pointer && keyboard

    companion object {
        fun parse(value: Any?): RdpNativeCapabilities {
            val root = strictMap(value, setOf("schemaVersion", "availability", "engineRevision", "security", "display", "input", "channels"), "invalidCapabilities")
            if (root["schemaVersion"] != 1) fail("invalidCapabilities")
            val availability = when (root["availability"]) {
                "available" -> RdpNativeAvailability.AVAILABLE
                "unavailable" -> RdpNativeAvailability.UNAVAILABLE
                else -> fail("invalidCapabilities")
            }
            val revision = root["engineRevision"]?.let {
                text(it, 1, 64, "invalidCapabilities").also { revision ->
                    if (!Regex("[A-Za-z0-9][A-Za-z0-9._+-]{0,63}").matches(revision)) fail("invalidCapabilities")
                }
            }
            val security = strictMap(root["security"], setOf("tls", "certificatePinning", "nla", "rdGateway"), "invalidCapabilities")
            val display = strictMap(root["display"], setOf("dynamicResolution", "externalDisplay", "maxWidth", "maxHeight", "maxDpi"), "invalidCapabilities")
            val input = strictMap(root["input"], setOf("pointer", "keyboard"), "invalidCapabilities")
            val channels = strictMap(root["channels"], setOf("clipboardModes"), "invalidCapabilities")
            val rawModes = channels["clipboardModes"] as? List<*> ?: fail("invalidCapabilities")
            if (rawModes.size > 3 || rawModes.toSet().size != rawModes.size) fail("invalidCapabilities")
            val modes = rawModes.map {
                when (enumName(it, setOf("disabled", "clientToRemote", "bidirectional"), "invalidCapabilities")) {
                    "disabled" -> RdpClipboardMode.DISABLED
                    "clientToRemote" -> RdpClipboardMode.CLIENT_TO_REMOTE
                    else -> RdpClipboardMode.BIDIRECTIONAL
                }
            }.toSet()
            val result = RdpNativeCapabilities(
                availability, revision,
                bool(security, "tls", "invalidCapabilities"),
                bool(security, "certificatePinning", "invalidCapabilities"),
                bool(security, "nla", "invalidCapabilities"),
                bool(security, "rdGateway", "invalidCapabilities"),
                bool(display, "dynamicResolution", "invalidCapabilities"),
                bool(display, "externalDisplay", "invalidCapabilities"),
                int(display, "maxWidth", 0, 8192, "invalidCapabilities"),
                int(display, "maxHeight", 0, 8192, "invalidCapabilities"),
                int(display, "maxDpi", 0, 640, "invalidCapabilities"),
                bool(input, "pointer", "invalidCapabilities"),
                bool(input, "keyboard", "invalidCapabilities"), modes,
            )
            if (availability == RdpNativeAvailability.UNAVAILABLE) {
                if (revision != null || result.tls || result.certificatePinning || result.nla || result.rdGateway ||
                    result.dynamicResolution || result.externalDisplay || result.maxWidth != 0 || result.maxHeight != 0 ||
                    result.maxDpi != 0 || result.pointer || result.keyboard || modes.isNotEmpty()) fail("invalidCapabilities")
            } else if (revision == null || result.maxWidth < 640 || result.maxHeight < 480 ||
                result.maxDpi < 72 || RdpClipboardMode.DISABLED !in modes) fail("invalidCapabilities")
            return result
        }
    }
}

data class RdpNativeGateway(val host: String, val port: Int, val username: String)
data class RdpNativeDisplay(
    val width: Int, val height: Int, val dpi: Int,
    val externalDisplay: Boolean, val dynamicResize: Boolean,
)

class RdpNativeRequest private constructor(
    val requestId: String,
    val targetHost: String,
    val targetPort: Int,
    val username: String,
    val domain: String,
    val gateway: RdpNativeGateway?,
    val certificateFingerprint: String,
    val requiresNla: Boolean,
    val display: RdpNativeDisplay,
    val keyboardLayout: RdpKeyboardLayout,
    val clipboardMode: RdpClipboardMode,
) {
    override fun toString() = "RdpNativeRequest(<redacted>)"
    fun publicSummary(): Map<String, Any> = mapOf(
        "requestId" to requestId, "targetPort" to targetPort,
        "gatewayConfigured" to (gateway != null), "displayWidth" to display.width,
        "displayHeight" to display.height, "displayDpi" to display.dpi,
        "externalDisplay" to display.externalDisplay, "dynamicResize" to display.dynamicResize,
        "keyboardLayout" to keyboardLayout.name, "clipboardMode" to clipboardMode.name,
    )

    companion object {
        private val requestKeys = setOf("schemaVersion", "requestId", "targetHost", "targetPort", "username", "domain", "gateway", "certificateFingerprint", "requiresNla", "display", "keyboardLayout", "clipboardMode")
        private fun host(value: Any?): String {
            val host = text(value, 1, 253, "invalidRequest")
            if (Regex("[\\s/@\\\\?#%\\[\\]]").containsMatchIn(host)) fail("invalidRequest")
            if (host.contains(':')) {
                if (!Regex("[0-9a-fA-F:]{2,45}").matches(host) || host.count { it == ':' } < 2 || ":::" in host) fail("invalidRequest")
                return host.lowercase()
            }
            val parts = host.removeSuffix(".").split('.')
            if (parts.any { !Regex("[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?").matches(it) }) fail("invalidRequest")
            if (parts.all { it.all(Char::isDigit) }) {
                if (parts.size != 4 || parts.any { it.length > 1 && it.startsWith('0') || it.toIntOrNull() !in 0..255 }) fail("invalidRequest")
            }
            return parts.joinToString(".").lowercase()
        }

        fun parse(value: Any?): RdpNativeRequest {
            val root = strictMap(value, requestKeys, "invalidRequest")
            if (root["schemaVersion"] != 1) fail("invalidRequest")
            val requestId = text(root["requestId"], 36, 36, "invalidRequest")
            if (!Regex("[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}").matches(requestId)) fail("invalidRequest")
            val gateway = root["gateway"]?.let {
                val map = strictMap(it, setOf("host", "port", "username"), "invalidRequest")
                RdpNativeGateway(host(map["host"]), int(map, "port", 1, 65535, "invalidRequest"), text(map["username"], 0, 128, "invalidRequest"))
            }
            val display = strictMap(root["display"], setOf("width", "height", "dpi", "externalDisplay", "dynamicResize"), "invalidRequest")
            val width = int(display, "width", 640, 8192, "invalidRequest")
            val height = int(display, "height", 480, 8192, "invalidRequest")
            if (width.toLong() * height > 33_554_432L) fail("invalidRequest")
            val fingerprint = text(root["certificateFingerprint"], 50, 50, "invalidRequest")
            if (!Regex("SHA256:[A-Za-z0-9+/]{43}").matches(fingerprint)) fail("invalidRequest")
            val keyboard = when (enumName(root["keyboardLayout"], setOf("automatic", "turkishQ", "us"), "invalidRequest")) {
                "automatic" -> RdpKeyboardLayout.AUTOMATIC
                "turkishQ" -> RdpKeyboardLayout.TURKISH_Q
                else -> RdpKeyboardLayout.US
            }
            val clipboard = when (enumName(root["clipboardMode"], setOf("disabled", "clientToRemote", "bidirectional"), "invalidRequest")) {
                "disabled" -> RdpClipboardMode.DISABLED
                "clientToRemote" -> RdpClipboardMode.CLIENT_TO_REMOTE
                else -> RdpClipboardMode.BIDIRECTIONAL
            }
            return RdpNativeRequest(
                requestId, host(root["targetHost"]), int(root, "targetPort", 1, 65535, "invalidRequest"),
                text(root["username"], 1, 128, "invalidRequest"), text(root["domain"], 0, 128, "invalidRequest"), gateway,
                fingerprint, root["requiresNla"] as? Boolean ?: fail("invalidRequest"),
                RdpNativeDisplay(width, height, int(display, "dpi", 72, 640, "invalidRequest"),
                    bool(display, "externalDisplay", "invalidRequest"), bool(display, "dynamicResize", "invalidRequest")),
                keyboard, clipboard,
            )
        }
    }
}

class RdpNativeNegotiated internal constructor(
    val engineRevision: String,
    val clipboardMode: RdpClipboardMode,
    private val display: RdpNativeDisplay,
) {
    fun toMap(): Map<String, Any> = mapOf(
        "engineRevision" to engineRevision, "clipboardMode" to clipboardMode.name,
        "width" to display.width, "height" to display.height, "dpi" to display.dpi,
        "externalDisplay" to display.externalDisplay, "dynamicResize" to display.dynamicResize,
    )
}

object RdpNativeNegotiator {
    fun negotiate(request: RdpNativeRequest, capabilities: RdpNativeCapabilities): RdpNativeNegotiated {
        if (capabilities.availability != RdpNativeAvailability.AVAILABLE) fail("engineUnavailable")
        if (!capabilities.tls) fail("tlsRequired")
        if (!capabilities.certificatePinning) fail("certificatePinningRequired")
        if (request.requiresNla && !capabilities.nla) fail("nlaUnavailable")
        if (request.gateway != null && !capabilities.rdGateway) fail("gatewayUnavailable")
        val display = request.display
        if (display.width > capabilities.maxWidth || display.height > capabilities.maxHeight || display.dpi > capabilities.maxDpi ||
            display.externalDisplay && !capabilities.externalDisplay || display.dynamicResize && !capabilities.dynamicResolution) fail("displayUnavailable")
        if (!capabilities.pointer || !capabilities.keyboard) fail("inputUnavailable")
        if (request.clipboardMode !in capabilities.clipboardModes) fail("clipboardUnavailable")
        return RdpNativeNegotiated(capabilities.engineRevision ?: fail("invalidCapabilities"), request.clipboardMode, display)
    }
}

class RdpNativeSecrets private constructor(
    private var password: CharArray?, private var gatewayPassword: CharArray?,
) : AutoCloseable {
    var closed = false
        private set
    override fun toString() = "RdpNativeSecrets(<redacted>)"
    fun publicSummary(): Map<String, Any> = mapOf("present" to !closed, "gatewayPresent" to (!closed && gatewayPassword != null))
    internal fun requireGatewayShape(gatewayConfigured: Boolean) {
        if (closed || (gatewayPassword != null) != gatewayConfigured) fail("invalidSecrets")
    }
    internal fun use(block: (CharArray, CharArray?) -> Unit) {
        if (closed) fail("invalidSecrets")
        block(password ?: fail("invalidSecrets"), gatewayPassword)
    }
    override fun close() {
        password?.fill('\u0000')
        gatewayPassword?.fill('\u0000')
        password = null
        gatewayPassword = null
        closed = true
    }
    companion object {
        fun take(password: CharArray, gatewayPassword: CharArray?): RdpNativeSecrets {
            if (password.isEmpty() || password.size > 4096 || password.any { it == '\u0000' } ||
                gatewayPassword?.let { it.size > 4096 || it.any { char -> char == '\u0000' } } == true) {
                password.fill('\u0000'); gatewayPassword?.fill('\u0000'); fail("invalidSecrets")
            }
            return RdpNativeSecrets(password, gatewayPassword)
        }
    }
}

interface RdpNativeSession { fun close() }
interface RdpNativeBackend {
    fun capabilities(): RdpNativeCapabilities
    fun open(request: RdpNativeRequest, negotiated: RdpNativeNegotiated, secrets: RdpNativeSecrets): RdpNativeSession
}

class UnavailableRdpNativeBackend : RdpNativeBackend {
    var openCalls = 0
        private set
    override fun capabilities() = RdpNativeCapabilities.parse(mapOf(
        "schemaVersion" to 1, "availability" to "unavailable", "engineRevision" to null,
        "security" to mapOf("tls" to false, "certificatePinning" to false, "nla" to false, "rdGateway" to false),
        "display" to mapOf("dynamicResolution" to false, "externalDisplay" to false, "maxWidth" to 0, "maxHeight" to 0, "maxDpi" to 0),
        "input" to mapOf("pointer" to false, "keyboard" to false),
        "channels" to mapOf("clipboardModes" to emptyList<String>()),
    ))
    override fun open(request: RdpNativeRequest, negotiated: RdpNativeNegotiated, secrets: RdpNativeSecrets): RdpNativeSession {
        openCalls++
        fail("engineUnavailable")
    }
}

class RdpNativeAdapter(private val backend: RdpNativeBackend = UnavailableRdpNativeBackend()) {
    fun capabilities() = backend.capabilities()
    fun open(request: RdpNativeRequest, secrets: RdpNativeSecrets): RdpNativeSession = try {
        secrets.requireGatewayShape(request.gateway != null)
        val negotiated = RdpNativeNegotiator.negotiate(request, backend.capabilities())
        backend.open(request, negotiated, secrets)
    } catch (failure: RdpNativeFailure) {
        throw failure
    } catch (_: Exception) {
        fail("connectionFailed")
    } finally {
        secrets.close()
    }
}
