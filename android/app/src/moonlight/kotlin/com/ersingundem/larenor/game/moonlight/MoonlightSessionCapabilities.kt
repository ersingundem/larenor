package com.ersingundem.larenor.game.moonlight

import android.content.Context
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.util.AtomicFile
import android.view.Display
import com.limelight.computers.ComputerDatabaseManager
import com.limelight.binding.video.MediaCodecHelper
import com.limelight.preferences.GlPreferences
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.net.Inet4Address
import java.net.Inet6Address
import java.net.InetAddress

data class MoonlightStreamPolicy(
    val policyId: String,
    val policyRevision: Long,
    val allowedCodecs: Set<String>,
    val allowMetered: Boolean,
    val requirePin: Boolean,
    val maxWidth: Int,
    val maxHeight: Int,
    val maxFramesPerSecond: Int,
    val maxBitrateKbps: Int,
    val maximumIdleSeconds: Int,
    val maximumSessionSeconds: Int,
    val frameQueueDepth: Int,
    val inputQueueDepth: Int,
) {
    init {
        requireIdentity(policyId, "candidate")
        requireRevision(policyRevision, "revision")
        require(allowedCodecs.isNotEmpty() && allowedCodecs.size <= 3)
        require(allowedCodecs.all { it in setOf("h264", "hevc", "av1") })
        require(maxWidth in 320..8192 && maxHeight in 320..8192)
        require(maxFramesPerSecond in 24..240)
        require(maxBitrateKbps in 2_000..100_000)
        require(maximumIdleSeconds in 30..3_600 && maximumSessionSeconds in 60..3_600)
        require(frameQueueDepth in 1..3 && inputQueueDepth in 1..32)
    }
}

class MoonlightPolicyStore(private val file: File, private val scope: MoonlightScope) {
    private val atomic = AtomicFile(file)

    @Synchronized
    fun current(): MoonlightStreamPolicy? {
        if (!file.exists()) return null
        if (!file.isFile || file.isSymbolicLink() || file.length() !in 1..MAX_BYTES) {
            throw MoonlightRuntimeFailure("invalid_receipt")
        }
        return try {
            decode(JSONObject(String(atomic.readFully(), StandardCharsets.UTF_8)))
        } catch (failure: MoonlightRuntimeFailure) {
            throw failure
        } catch (_: Exception) {
            throw MoonlightRuntimeFailure("invalid_receipt")
        }
    }

    @Synchronized
    fun configure(expectedRevision: Long, requested: MoonlightStreamPolicy): MoonlightStreamPolicy {
        if (expectedRevision !in 0..MAX_JS_REVISION) throw MoonlightRuntimeFailure("invalid_revision")
        val current = current()
        if ((current?.policyRevision ?: 0L) != expectedRevision) {
            throw MoonlightRuntimeFailure("authority_changed")
        }
        val revision = if (current == null) 1L else current.policyRevision + 1L
        if (revision > MAX_JS_REVISION) throw MoonlightRuntimeFailure("invalid_revision")
        val policy = requested.copy(
            policyId = sha256("${scope.storageKey}\u0000stream-policy".toByteArray()).hex().take(32),
            policyRevision = revision,
        )
        write(policy)
        return policy
    }

    private fun write(policy: MoonlightStreamPolicy) {
        val bytes = encode(policy).toString().toByteArray(StandardCharsets.UTF_8)
        val output = try { atomic.startWrite() } catch (_: Exception) {
            throw MoonlightRuntimeFailure("unknown_effect")
        }
        try {
            output.write(bytes)
            output.fd.sync()
            atomic.finishWrite(output)
        } catch (_: Exception) {
            atomic.failWrite(output)
            throw MoonlightRuntimeFailure("unknown_effect")
        }
    }

    private fun encode(value: MoonlightStreamPolicy) = JSONObject()
        .put("schemaVersion", 1)
        .put("policyId", value.policyId)
        .put("policyRevision", value.policyRevision)
        .put("allowedCodecs", JSONArray(value.allowedCodecs.sorted()))
        .put("allowMetered", value.allowMetered)
        .put("requirePin", value.requirePin)
        .put("maxWidth", value.maxWidth)
        .put("maxHeight", value.maxHeight)
        .put("maxFps", value.maxFramesPerSecond)
        .put("maxBitrateKbps", value.maxBitrateKbps)
        .put("maximumIdleSeconds", value.maximumIdleSeconds)
        .put("maximumSessionSeconds", value.maximumSessionSeconds)
        .put("frameQueueDepth", value.frameQueueDepth)
        .put("inputQueueDepth", value.inputQueueDepth)

    private fun decode(value: JSONObject): MoonlightStreamPolicy {
        if (value.keys().asSequence().toSet() != KEYS || value.getInt("schemaVersion") != 1) {
            throw MoonlightRuntimeFailure("invalid_receipt")
        }
        return MoonlightStreamPolicy(
            policyId = value.getString("policyId"),
            policyRevision = value.getLong("policyRevision"),
            allowedCodecs = value.getJSONArray("allowedCodecs").let { array ->
                (0 until array.length()).map { array.getString(it) }.toSet()
            },
            allowMetered = value.getBoolean("allowMetered"),
            requirePin = value.getBoolean("requirePin"),
            maxWidth = value.getInt("maxWidth"),
            maxHeight = value.getInt("maxHeight"),
            maxFramesPerSecond = value.getInt("maxFps"),
            maxBitrateKbps = value.getInt("maxBitrateKbps"),
            maximumIdleSeconds = value.getInt("maximumIdleSeconds"),
            maximumSessionSeconds = value.getInt("maximumSessionSeconds"),
            frameQueueDepth = value.getInt("frameQueueDepth"),
            inputQueueDepth = value.getInt("inputQueueDepth"),
        )
    }

    private fun File.isSymbolicLink(): Boolean = Files.isSymbolicLink(toPath())

    companion object {
        private const val MAX_BYTES = 8_192L
        private val KEYS = setOf(
            "schemaVersion", "policyId", "policyRevision", "allowedCodecs",
            "allowMetered", "requirePin", "maxWidth", "maxHeight", "maxFps",
            "maxBitrateKbps", "maximumIdleSeconds", "maximumSessionSeconds",
            "frameQueueDepth", "inputQueueDepth",
        )
    }
}

data class MoonlightDisplayObservation(
    val displayId: Int,
    val displayRevision: Long,
    val attached: Boolean,
    val widthPixels: Int,
    val heightPixels: Int,
    val densityDpi: Int,
    val secureSurface: Boolean,
    val maxRefreshRate: Int,
)

data class MoonlightNetworkObservation(
    val networkId: String,
    val networkRevision: Long,
    val reachability: String,
    val metered: Boolean,
)

data class MoonlightDecoderObservation(
    val codecId: String,
    val codecRevision: Long,
    val codec: String,
    val supported: Boolean,
    val maxWidthPixels: Int,
    val maxHeightPixels: Int,
    val maxFramesPerSecond: Int,
)

data class MoonlightQualityOption(
    val codec: String,
    val codecId: String,
    val codecRevision: Long,
    val displayId: Int,
    val displayRevision: Long,
    val networkId: String,
    val networkRevision: Long,
    val policyId: String,
    val policyRevision: Long,
    val widthPixels: Int,
    val heightPixels: Int,
    val framesPerSecond: Int,
    val bitrateKbps: Int,
    val frameQueueDepth: Int,
    val inputQueueDepth: Int,
    val secureSurface: Boolean,
)

data class MoonlightSessionCapabilities(
    val availability: String,
    val reason: String?,
    val display: MoonlightDisplayObservation?,
    val network: MoonlightNetworkObservation?,
    val decoders: List<MoonlightDecoderObservation>,
    val policy: MoonlightStreamPolicy?,
    val qualityOptions: List<MoonlightQualityOption>,
)

class MoonlightSessionCapabilityObserver(
    private val context: Context,
    private val display: Display?,
) {
    fun observe(
        pairing: MoonlightNativePairing,
        policy: MoonlightStreamPolicy?,
        pinSatisfied: Boolean,
    ): MoonlightSessionCapabilities {
        val network = network(pairing)
        val display = display()
            ?: return unavailable("displayUnavailable", null, network, emptyList(), policy)
        val decoderCapabilities = codecs(display)
        val decoders = decoderCapabilities.map { it.observation }
        if (network == null) return unavailable("networkUnavailable", display, null, decoders, policy)
        if (policy == null) return unavailable("policyUnavailable", display, network, decoders, null)
        if (policy.requirePin && !pinSatisfied) {
            return unavailable("pinRequired", display, network, decoders, policy)
        }
        if (network.reachability == "unavailable") {
            return unavailable("networkUnavailable", display, network, decoders, policy)
        }
        if (network.metered && !policy.allowMetered) {
            return unavailable("meteredDenied", display, network, decoders, policy)
        }
        // The pinned renderer exposes a fixed two-buffer output queue and
        // Android dispatches one input event at a time. No upstream API can
        // truthfully apply other queue depths.
        if (policy.frameQueueDepth != 2 || policy.inputQueueDepth != 1) {
            return unavailable("queuePolicyUnsupported", display, network, decoders, policy)
        }
        val observation = JSONObject(pairing.observationJson)
        val hostCodecs = observation.getJSONArray("codecs").let { array ->
            (0 until array.length()).map { array.getString(it) }.toSet()
        }
        val options = decoderCapabilities.filter { decoder ->
            decoder.observation.supported && decoder.observation.codec in hostCodecs &&
                decoder.observation.codec in policy.allowedCodecs
        }.mapNotNull { decoder ->
            // Sunshine serverinfo reports codec support but no display-mode ceiling.
            // The requested stream mode is therefore bounded only by facts this
            // client can observe and enforce: decoder, attached display and policy.
            val request = supportedRequest(
                decoder.capabilities,
                minOf(display.widthPixels, policy.maxWidth),
                minOf(display.heightPixels, policy.maxHeight),
                minOf(display.maxRefreshRate, policy.maxFramesPerSecond),
            ) ?: return@mapNotNull null
            MoonlightQualityOption(
                codec = decoder.observation.codec,
                codecId = decoder.observation.codecId,
                codecRevision = decoder.observation.codecRevision,
                displayId = display.displayId,
                displayRevision = display.displayRevision,
                networkId = network.networkId,
                networkRevision = network.networkRevision,
                policyId = policy.policyId,
                policyRevision = policy.policyRevision,
                widthPixels = request.first,
                heightPixels = request.second,
                framesPerSecond = request.third,
                bitrateKbps = policy.maxBitrateKbps,
                frameQueueDepth = policy.frameQueueDepth,
                inputQueueDepth = policy.inputQueueDepth,
                secureSurface = display.secureSurface,
            )
        }
        return if (options.isEmpty() || !display.secureSurface) {
            unavailable("codecUnavailable", display, network, decoders, policy)
        } else MoonlightSessionCapabilities("available", null, display, network, decoders, policy, options)
    }

    private fun display(): MoonlightDisplayObservation? {
        val display = display ?: return null
        if (!display.isValid || display.displayId !in 0..63) return null
        val metrics = context.createDisplayContext(display).resources.displayMetrics
        val mode = display.mode ?: return null
        val maxRefresh = display.supportedModes.maxOfOrNull { it.refreshRate.toInt() } ?: mode.refreshRate.toInt()
        val secure = display.flags and Display.FLAG_SECURE != 0 &&
            display.flags and Display.FLAG_SUPPORTS_PROTECTED_BUFFERS != 0
        if (mode.physicalWidth !in 320..8192 || mode.physicalHeight !in 320..8192 ||
            metrics.densityDpi !in 72..640 || maxRefresh !in 24..240
        ) return null
        val revision = publicRevision(
            display.displayId.toString(), mode.physicalWidth.toString(), mode.physicalHeight.toString(),
            metrics.densityDpi.toString(), secure.toString(), maxRefresh.toString(),
        )
        return MoonlightDisplayObservation(
            displayId = display.displayId,
            displayRevision = revision,
            attached = true,
            widthPixels = mode.physicalWidth,
            heightPixels = mode.physicalHeight,
            densityDpi = metrics.densityDpi,
            secureSurface = secure,
            maxRefreshRate = maxRefresh,
        )
    }

    private fun network(pairing: MoonlightNativePairing): MoonlightNetworkObservation? {
        val manager = context.getSystemService(ConnectivityManager::class.java) ?: return null
        val network = manager.activeNetwork ?: return null
        val capabilities = manager.getNetworkCapabilities(network) ?: return null
        val linkProperties = manager.getLinkProperties(network) ?: return null
        val target = targetAddress(pairing) ?: return null
        val matchingPrefixes = linkProperties.routes.filter { it.matches(target) }
            .map { it.destination.prefixLength }
        val localTransport = capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)
        val validatedInternet = capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
            capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
        val reachability = classifyReachability(
            matchingPrefixes, if (target.address.size == 4) 32 else 128,
            localTransport, validatedInternet,
        )
        val metered = !capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
        val transports = listOf(
            NetworkCapabilities.TRANSPORT_WIFI, NetworkCapabilities.TRANSPORT_ETHERNET,
            NetworkCapabilities.TRANSPORT_CELLULAR, NetworkCapabilities.TRANSPORT_VPN,
            NetworkCapabilities.TRANSPORT_BLUETOOTH,
        ).filter(capabilities::hasTransport)
        val targetDigest = sha256(target.address).hex()
        val identity = networkIdentity(
            network.networkHandle, transports, reachability, metered, targetDigest,
        )
        return MoonlightNetworkObservation(
            networkId = identity,
            networkRevision = publicRevision(identity, reachability, metered.toString()),
            reachability = reachability,
            metered = metered,
        )
    }

    private fun targetAddress(pairing: MoonlightNativePairing) = ComputerDatabaseManager(context).let { database ->
        try {
            val details = database.getComputerByUUID(pairing.upstreamHostUuid) ?: return@let null
            val raw = (details.activeAddress ?: details.localAddress ?: details.ipv6Address)?.address
                ?: return@let null
            parseNumericAddress(raw)
        } finally {
            database.close()
        }
    }

    private data class DecoderCapability(
        val observation: MoonlightDecoderObservation,
        val capabilities: MediaCodecInfo.VideoCapabilities,
    )

    private fun codecs(display: MoonlightDisplayObservation): List<DecoderCapability> =
        CODECS.mapNotNull { (name, mime) ->
        val info = selectedMoonlightDecoder(context, name, mime) ?: return@mapNotNull null
        val capability = runCatching { info.getCapabilitiesForType(mime).videoCapabilities }.getOrNull()
            ?: return@mapNotNull null
        val request = supportedRequest(
            capability, display.widthPixels, display.heightPixels, display.maxRefreshRate,
        ) ?: return@mapNotNull null
        val codecName = info.name
        val (width, height, fps) = request
        val revision = publicRevision(
            codecName, name, width.toString(), height.toString(), fps.toString(),
            capability.widthAlignment.toString(), capability.heightAlignment.toString(),
        )
        DecoderCapability(
            MoonlightDecoderObservation(
                codecId = sha256("decoder\u0000$codecName".toByteArray()).hex().take(32),
                codecRevision = revision,
                codec = name,
                supported = true,
                maxWidthPixels = width,
                maxHeightPixels = height,
                maxFramesPerSecond = fps,
            ),
            capability,
        )
    }

    private fun unavailable(
        reason: String,
        display: MoonlightDisplayObservation?,
        network: MoonlightNetworkObservation?,
        decoders: List<MoonlightDecoderObservation>,
        policy: MoonlightStreamPolicy?,
    ) = MoonlightSessionCapabilities("unavailable", reason, display, network, decoders, policy, emptyList())

    companion object {
        private val CODECS: List<Pair<String, String>> = listOf(
            "h264" to MediaFormat.MIMETYPE_VIDEO_AVC,
            "hevc" to MediaFormat.MIMETYPE_VIDEO_HEVC,
            "av1" to MediaFormat.MIMETYPE_VIDEO_AV1,
        )
    }
}

internal fun alignedDown(value: Int, alignment: Int): Int =
    if (alignment <= 0) 0 else value - value % alignment

internal fun classifyReachability(
    matchingPrefixLengths: List<Int>,
    addressBits: Int,
    localTransport: Boolean,
    validatedInternet: Boolean,
): String {
    if (addressBits !in setOf(32, 128) || matchingPrefixLengths.any { it !in 0..addressBits }) {
        return "unavailable"
    }
    if (localTransport && matchingPrefixLengths.any { it > 0 }) return "local"
    return if (validatedInternet && matchingPrefixLengths.isNotEmpty()) "remote" else "unavailable"
}

internal fun networkIdentity(
    networkHandle: Long,
    transports: List<Int>,
    reachability: String,
    metered: Boolean,
    targetDigest: String,
): String = sha256(
    listOf(networkHandle.toString(), transports.sorted().joinToString(","), reachability,
        metered.toString(), targetDigest).joinToString("\u0000").toByteArray(),
).hex().take(32)

internal fun parseNumericAddress(raw: String): InetAddress? {
    if (raw.isEmpty() || raw.length > 64 || raw.count { it == '%' } > 1) return null
    val address = raw.substringBefore('%')
    if (address.matches(Regex("^[0-9]{1,3}(?:\\.[0-9]{1,3}){3}$"))) {
        val octets = address.split('.').map { it.toIntOrNull() ?: return null }
        if (octets.any { it !in 0..255 }) return null
        return InetAddress.getByAddress(octets.map(Int::toByte).toByteArray()) as? Inet4Address
    }
    if (':' !in address || !address.matches(Regex("^[0-9A-Fa-f:.]+$"))) return null
    return runCatching { InetAddress.getByName(address) }.getOrNull() as? Inet6Address
}

internal fun selectedMoonlightDecoder(
    context: Context,
    codec: String,
    mime: String,
): MediaCodecInfo? {
    MediaCodecHelper.initialize(context, GlPreferences.readPreferences(context).glRenderer)
    return when (codec) {
        // These are the same selectors used by pinned MediaCodecDecoderRenderer.
        // HEVC/AV1 are observed under the same FORCE_* preference that is
        // persisted before Game is launched.
        "h264" -> MediaCodecHelper.findProbableSafeDecoder(mime, 8)
            ?: MediaCodecHelper.findFirstDecoder(mime)
        "hevc", "av1" -> MediaCodecHelper.findProbableSafeDecoder(mime, -1)
        else -> null
    }
}

private fun supportedRequest(
    capabilities: MediaCodecInfo.VideoCapabilities,
    maxWidth: Int,
    maxHeight: Int,
    maxFramesPerSecond: Int,
): Triple<Int, Int, Int>? {
    for ((width, height) in candidateDimensions(
        maxWidth.coerceAtMost(8192), maxHeight.coerceAtMost(8192),
        capabilities.widthAlignment, capabilities.heightAlignment,
    )) {
        if (!capabilities.supportedWidths.contains(width) || !capabilities.supportedHeights.contains(height)) continue
        val rates = runCatching { capabilities.getSupportedFrameRatesFor(width, height) }.getOrNull() ?: continue
        if (!rates.upper.isFinite()) continue
        val fps = minOf(maxFramesPerSecond, rates.upper.toInt(), 240)
        if (fps >= 24 && capabilities.areSizeAndRateSupported(width, height, fps.toDouble())) {
            return Triple(width, height, fps)
        }
    }
    return null
}

internal fun candidateDimensions(
    maxWidth: Int,
    maxHeight: Int,
    widthAlignment: Int,
    heightAlignment: Int,
): List<Pair<Int, Int>> {
    if (maxWidth !in 320..8192 || maxHeight !in 320..8192 ||
        widthAlignment <= 0 || heightAlignment <= 0
    ) return emptyList()
    return (64 downTo 1).mapNotNull { scale ->
        val width = alignedDown(maxWidth * scale / 64, widthAlignment)
        val height = alignedDown(maxHeight * scale / 64, heightAlignment)
        (width to height).takeIf { width >= 320 && height >= 320 }
    }.distinct()
}
