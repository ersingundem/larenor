package com.ersingundem.larenor.vnc

enum class VncNativeAvailability { UNAVAILABLE, AVAILABLE }
enum class VncSecurityType { VENCRYPT_TLS_VNC_AUTH, VNC_AUTH, NONE }
enum class VncFramebufferEncoding { TIGHT, ZRLE, RAW }
enum class VncPixelFormat { TRUE_COLOR_32 }

class VncNativeFailure(val code: String) : RuntimeException("Native VNC operation rejected") {
    init {
        if (code !in codes) throw VncNativeFailure("invalidFailure")
    }

    fun publicDetails(): Map<String, Any> = mapOf("code" to code, "retryable" to false)
    override fun toString() = "VncNativeFailure($code)"

    companion object {
        private val codes = setOf(
            "invalidFailure", "invalidCapabilities", "invalidRequest", "invalidSecrets",
            "engineUnavailable", "rfbVersionUnavailable", "tlsRequired", "spkiPinningRequired",
            "authUnavailable", "framebufferUnavailable", "inputUnavailable", "foregroundRequired",
            "busy", "timedOut", "cancelled", "staleSession", "connectionFailed",
        )
    }
}

private fun fail(code: String): Nothing = throw VncNativeFailure(code)

private fun strictMap(value: Any?, keys: Set<String>, code: String): Map<*, *> {
    val map = value as? Map<*, *> ?: fail(code)
    if (map.keys != keys) fail(code)
    return map
}

private fun bool(map: Map<*, *>, key: String, code: String): Boolean =
    map[key] as? Boolean ?: fail(code)

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

private fun host(value: Any?): String {
    val result = text(value, 1, 253, "invalidRequest")
    if (Regex("[\\s/@\\\\?#%\\[\\]]").containsMatchIn(result)) fail("invalidRequest")
    if (result.contains(':')) {
        if (!Regex("[0-9a-fA-F:]{2,45}").matches(result) ||
            result.count { it == ':' } < 2 || ":::" in result) fail("invalidRequest")
        return result.lowercase()
    }
    val parts = result.removeSuffix(".").split('.')
    if (parts.any { !Regex("[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?").matches(it) }) {
        fail("invalidRequest")
    }
    if (parts.all { it.all(Char::isDigit) } &&
        (parts.size != 4 || parts.any {
            it.length > 1 && it.startsWith('0') || it.toIntOrNull() !in 0..255
        })) fail("invalidRequest")
    return parts.joinToString(".").lowercase()
}

class VncNativeCapabilities private constructor(
    val availability: VncNativeAvailability,
    val engineRevision: String?,
    val rfbVersions: Set<String>,
    val securityTypes: Set<VncSecurityType>,
    val tls: Boolean,
    val spkiPinning: Boolean,
    val passwordAuth: Boolean,
    val encodings: Set<VncFramebufferEncoding>,
    val trueColor32: Boolean,
    val dynamicResolution: Boolean,
    val externalDisplay: Boolean,
    val maxWidth: Int,
    val maxHeight: Int,
    val maxDpi: Int,
    val pointer: Boolean,
    val keyboard: Boolean,
    val clipboard: Boolean,
) {
    val canConnect get() = availability == VncNativeAvailability.AVAILABLE &&
        "3.8" in rfbVersions && VncSecurityType.VENCRYPT_TLS_VNC_AUTH in securityTypes &&
        tls && spkiPinning && passwordAuth && trueColor32 && pointer && keyboard

    companion object {
        fun parse(value: Any?): VncNativeCapabilities {
            val root = strictMap(value, setOf(
                "schemaVersion", "availability", "engineRevision", "rfbVersions", "securityTypes",
                "transport", "auth", "framebuffer", "input",
            ), "invalidCapabilities")
            if (root["schemaVersion"] != 1) fail("invalidCapabilities")
            val availability = when (root["availability"]) {
                "available" -> VncNativeAvailability.AVAILABLE
                "unavailable" -> VncNativeAvailability.UNAVAILABLE
                else -> fail("invalidCapabilities")
            }
            val revision = root["engineRevision"]?.let {
                text(it, 1, 64, "invalidCapabilities").also { candidate ->
                    if (!Regex("[A-Za-z0-9][A-Za-z0-9._+-]{0,63}").matches(candidate)) {
                        fail("invalidCapabilities")
                    }
                }
            }
            val versions = stringSet(root["rfbVersions"], setOf("3.8"))
            val security = stringSet(
                root["securityTypes"],
                setOf("vencryptTlsVncAuth", "vncAuth", "none"),
            ).map {
                when (it) {
                    "vencryptTlsVncAuth" -> VncSecurityType.VENCRYPT_TLS_VNC_AUTH
                    "vncAuth" -> VncSecurityType.VNC_AUTH
                    else -> VncSecurityType.NONE
                }
            }.toSet()
            val transport = strictMap(root["transport"], setOf("tls", "spkiPinning"), "invalidCapabilities")
            val auth = strictMap(root["auth"], setOf("password"), "invalidCapabilities")
            val framebuffer = strictMap(root["framebuffer"], setOf(
                "encodings", "trueColor32", "dynamicResolution", "externalDisplay",
                "maxWidth", "maxHeight", "maxDpi",
            ), "invalidCapabilities")
            val encodings = stringSet(
                framebuffer["encodings"],
                setOf("tight", "zrle", "raw"),
            ).map {
                when (it) {
                    "tight" -> VncFramebufferEncoding.TIGHT
                    "zrle" -> VncFramebufferEncoding.ZRLE
                    else -> VncFramebufferEncoding.RAW
                }
            }.toSet()
            val input = strictMap(root["input"], setOf("pointer", "keyboard", "clipboard"), "invalidCapabilities")
            val result = VncNativeCapabilities(
                availability = availability,
                engineRevision = revision,
                rfbVersions = versions,
                securityTypes = security,
                tls = bool(transport, "tls", "invalidCapabilities"),
                spkiPinning = bool(transport, "spkiPinning", "invalidCapabilities"),
                passwordAuth = bool(auth, "password", "invalidCapabilities"),
                encodings = encodings,
                trueColor32 = bool(framebuffer, "trueColor32", "invalidCapabilities"),
                dynamicResolution = bool(framebuffer, "dynamicResolution", "invalidCapabilities"),
                externalDisplay = bool(framebuffer, "externalDisplay", "invalidCapabilities"),
                maxWidth = int(framebuffer, "maxWidth", 0, 8192, "invalidCapabilities"),
                maxHeight = int(framebuffer, "maxHeight", 0, 8192, "invalidCapabilities"),
                maxDpi = int(framebuffer, "maxDpi", 0, 640, "invalidCapabilities"),
                pointer = bool(input, "pointer", "invalidCapabilities"),
                keyboard = bool(input, "keyboard", "invalidCapabilities"),
                clipboard = bool(input, "clipboard", "invalidCapabilities"),
            )
            if (availability == VncNativeAvailability.UNAVAILABLE) {
                if (revision != null || versions.isNotEmpty() || security.isNotEmpty() || result.tls ||
                    result.spkiPinning || result.passwordAuth || encodings.isNotEmpty() || result.trueColor32 ||
                    result.dynamicResolution || result.externalDisplay || result.maxWidth != 0 ||
                    result.maxHeight != 0 || result.maxDpi != 0 || result.pointer || result.keyboard ||
                    result.clipboard) fail("invalidCapabilities")
            } else if (revision == null || result.maxWidth < 640 || result.maxHeight < 480 ||
                result.maxDpi < 72 || encodings.isEmpty()) fail("invalidCapabilities")
            return result
        }

        private fun stringSet(value: Any?, allowed: Set<String>): Set<String> {
            val items = value as? List<*> ?: fail("invalidCapabilities")
            if (items.size > allowed.size || items.toSet().size != items.size) fail("invalidCapabilities")
            return items.map {
                enumName(it, allowed, "invalidCapabilities")
            }.toSet()
        }
    }
}

data class VncNativeDisplay(
    val width: Int,
    val height: Int,
    val dpi: Int,
    val externalDisplay: Boolean,
    val dynamicResolution: Boolean,
)

class VncNativeRequest private constructor(
    val requestId: String,
    val targetHost: String,
    val targetPort: Int,
    val securityType: VncSecurityType,
    val spkiFingerprint: String,
    val display: VncNativeDisplay,
    val framebufferEncoding: VncFramebufferEncoding,
    val pixelFormat: VncPixelFormat,
    val pointer: Boolean,
    val keyboard: Boolean,
    val clipboard: Boolean,
) {
    override fun toString() = "VncNativeRequest(<redacted>)"

    fun publicSummary(): Map<String, Any> = mapOf(
        "requestId" to requestId,
        "targetPort" to targetPort,
        "width" to display.width,
        "height" to display.height,
        "dpi" to display.dpi,
        "externalDisplay" to display.externalDisplay,
        "dynamicResolution" to display.dynamicResolution,
        "framebufferEncoding" to framebufferEncoding.name,
        "pixelFormat" to pixelFormat.name,
        "pointer" to pointer,
        "keyboard" to keyboard,
        "clipboard" to clipboard,
    )

    companion object {
        fun parse(value: Any?): VncNativeRequest {
            val root = strictMap(value, setOf(
                "schemaVersion", "requestId", "targetHost", "targetPort", "security",
                "display", "framebuffer", "input",
            ), "invalidRequest")
            if (root["schemaVersion"] != 1) fail("invalidRequest")
            val requestId = text(root["requestId"], 36, 36, "invalidRequest")
            if (!Regex("[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}").matches(requestId)) {
                fail("invalidRequest")
            }
            val security = strictMap(root["security"], setOf(
                "type", "spkiFingerprint", "requiresPassword",
            ), "invalidRequest")
            if (security["type"] != "vencryptTlsVncAuth" || security["requiresPassword"] != true) {
                fail("invalidRequest")
            }
            val fingerprint = text(security["spkiFingerprint"], 50, 50, "invalidRequest")
            if (!Regex("SHA256:[A-Za-z0-9+/]{43}").matches(fingerprint)) fail("invalidRequest")
            val display = strictMap(root["display"], setOf(
                "width", "height", "dpi", "externalDisplay", "dynamicResolution",
            ), "invalidRequest")
            val width = int(display, "width", 640, 8192, "invalidRequest")
            val height = int(display, "height", 480, 8192, "invalidRequest")
            if (width.toLong() * height > 33_554_432L) fail("invalidRequest")
            val framebuffer = strictMap(root["framebuffer"], setOf("encoding", "pixelFormat"), "invalidRequest")
            val encoding = when (enumName(
                framebuffer["encoding"], setOf("tight", "zrle", "raw"), "invalidRequest",
            )) {
                "tight" -> VncFramebufferEncoding.TIGHT
                "zrle" -> VncFramebufferEncoding.ZRLE
                else -> VncFramebufferEncoding.RAW
            }
            if (framebuffer["pixelFormat"] != "trueColor32") fail("invalidRequest")
            val input = strictMap(root["input"], setOf("pointer", "keyboard", "clipboard"), "invalidRequest")
            return VncNativeRequest(
                requestId = requestId,
                targetHost = host(root["targetHost"]),
                targetPort = int(root, "targetPort", 1, 65535, "invalidRequest"),
                securityType = VncSecurityType.VENCRYPT_TLS_VNC_AUTH,
                spkiFingerprint = fingerprint,
                display = VncNativeDisplay(
                    width, height, int(display, "dpi", 72, 640, "invalidRequest"),
                    bool(display, "externalDisplay", "invalidRequest"),
                    bool(display, "dynamicResolution", "invalidRequest"),
                ),
                framebufferEncoding = encoding,
                pixelFormat = VncPixelFormat.TRUE_COLOR_32,
                pointer = bool(input, "pointer", "invalidRequest"),
                keyboard = bool(input, "keyboard", "invalidRequest"),
                clipboard = bool(input, "clipboard", "invalidRequest"),
            )
        }
    }
}

class VncNativePlan internal constructor(
    val engineRevision: String,
    val rfbVersion: String,
    val securityType: VncSecurityType,
    val framebufferEncoding: VncFramebufferEncoding,
    private val request: VncNativeRequest,
) {
    fun toMap(): Map<String, Any> = mapOf(
        "engineRevision" to engineRevision,
        "rfbVersion" to rfbVersion,
        "securityType" to securityType.name,
        "framebufferEncoding" to framebufferEncoding.name,
        "pixelFormat" to request.pixelFormat.name,
        "width" to request.display.width,
        "height" to request.display.height,
        "dpi" to request.display.dpi,
        "externalDisplay" to request.display.externalDisplay,
        "dynamicResolution" to request.display.dynamicResolution,
        "pointer" to request.pointer,
        "keyboard" to request.keyboard,
        "clipboard" to request.clipboard,
    )
}

object VncNativeNegotiator {
    fun negotiate(request: VncNativeRequest, capabilities: VncNativeCapabilities): VncNativePlan {
        if (capabilities.availability != VncNativeAvailability.AVAILABLE) fail("engineUnavailable")
        if ("3.8" !in capabilities.rfbVersions) fail("rfbVersionUnavailable")
        if (!capabilities.tls) fail("tlsRequired")
        if (!capabilities.spkiPinning) fail("spkiPinningRequired")
        if (request.securityType !in capabilities.securityTypes || !capabilities.passwordAuth) {
            fail("authUnavailable")
        }
        val display = request.display
        if (request.framebufferEncoding !in capabilities.encodings || !capabilities.trueColor32 ||
            display.width > capabilities.maxWidth || display.height > capabilities.maxHeight ||
            display.dpi > capabilities.maxDpi ||
            display.externalDisplay && !capabilities.externalDisplay ||
            display.dynamicResolution && !capabilities.dynamicResolution) fail("framebufferUnavailable")
        if (request.pointer && !capabilities.pointer || request.keyboard && !capabilities.keyboard ||
            request.clipboard && !capabilities.clipboard) fail("inputUnavailable")
        return VncNativePlan(
            capabilities.engineRevision ?: fail("invalidCapabilities"),
            "3.8", request.securityType, request.framebufferEncoding, request,
        )
    }
}

class VncNativeSecrets private constructor(private var password: CharArray?) : AutoCloseable {
    var closed = false
        private set

    override fun toString() = "VncNativeSecrets(<redacted>)"
    fun publicSummary(): Map<String, Any> = mapOf("present" to !closed)

    internal fun use(block: (CharArray) -> Unit) {
        if (closed) fail("invalidSecrets")
        block(password ?: fail("invalidSecrets"))
    }

    override fun close() {
        password?.fill('\u0000')
        password = null
        closed = true
    }

    companion object {
        fun take(password: CharArray): VncNativeSecrets {
            if (password.isEmpty() || password.size > 4096 || password.any { it == '\u0000' }) {
                password.fill('\u0000')
                fail("invalidSecrets")
            }
            return VncNativeSecrets(password)
        }
    }
}

interface VncNativeSession { fun close() }

interface VncNativeBackend {
    fun capabilities(): VncNativeCapabilities
    fun open(request: VncNativeRequest, plan: VncNativePlan, secrets: VncNativeSecrets): VncNativeSession
}

class UnavailableVncNativeBackend : VncNativeBackend {
    var openCalls = 0
        private set

    override fun capabilities() = VncNativeCapabilities.parse(mapOf(
        "schemaVersion" to 1,
        "availability" to "unavailable",
        "engineRevision" to null,
        "rfbVersions" to emptyList<String>(),
        "securityTypes" to emptyList<String>(),
        "transport" to mapOf("tls" to false, "spkiPinning" to false),
        "auth" to mapOf("password" to false),
        "framebuffer" to mapOf(
            "encodings" to emptyList<String>(),
            "trueColor32" to false,
            "dynamicResolution" to false,
            "externalDisplay" to false,
            "maxWidth" to 0,
            "maxHeight" to 0,
            "maxDpi" to 0,
        ),
        "input" to mapOf("pointer" to false, "keyboard" to false, "clipboard" to false),
    ))

    override fun open(
        request: VncNativeRequest,
        plan: VncNativePlan,
        secrets: VncNativeSecrets,
    ): VncNativeSession {
        openCalls++
        fail("engineUnavailable")
    }
}

class VncNativeAdapter(private val backend: VncNativeBackend = UnavailableVncNativeBackend()) {
    fun capabilities() = backend.capabilities()

    fun open(
        request: VncNativeRequest,
        secrets: VncNativeSecrets,
        expectedEngineRevision: String? = null,
    ): VncNativeSession = try {
        val capabilities = backend.capabilities()
        if (expectedEngineRevision != null && capabilities.engineRevision != expectedEngineRevision) {
            fail("staleSession")
        }
        val plan = VncNativeNegotiator.negotiate(request, capabilities)
        backend.open(request, plan, secrets)
    } catch (failure: VncNativeFailure) {
        throw failure
    } catch (_: Exception) {
        fail("connectionFailed")
    } finally {
        secrets.close()
    }
}
