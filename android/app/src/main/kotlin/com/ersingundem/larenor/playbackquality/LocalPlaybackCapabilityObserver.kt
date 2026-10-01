package com.ersingundem.larenor.playbackquality

import android.app.Activity
import android.content.Context
import android.media.MediaCodecList
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.view.Display
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.util.Locale
import java.util.concurrent.atomic.AtomicLong

internal const val LOCAL_PLAYBACK_PROFILE_SCHEMA_VERSION = 1
internal const val LOCAL_PLAYBACK_MAX_SAFE_INTEGER = 9_007_199_254_740_991L

internal data class LocalPlaybackDisplayFacts(
    val id: Int,
    val modeId: Int,
    val widthPixels: Int,
    val heightPixels: Int,
    val refreshRateBits: Int,
    val hdrTypes: List<String>,
)

internal data class LocalPlaybackDecoderFacts(
    val mimeTypes: List<String>,
    val truncated: Boolean,
)

internal data class LocalPlaybackNetworkFacts(
    // Never serialized. It distinguishes a replacement active Network whose
    // public transport flags happen to be identical.
    val handle: Long,
    val transports: List<String>,
    val validated: Boolean,
    val metered: Boolean,
    val downstreamKbps: Int?,
)

internal data class LocalPlaybackNativeSnapshot(
    val displayWidthPixels: Int,
    val displayHeightPixels: Int,
    val displayRevision: Long,
    val decoderMimeTypes: List<String>,
    val decoderMimeTypesTruncated: Boolean,
    val decoderRevision: Long,
    val networkTransports: List<String>,
    val networkValidated: Boolean,
    val networkMetered: Boolean,
    val networkDownstreamKbps: Int?,
    val networkRevision: Long,
) {
    fun toChannel(): Map<String, Any?> = mapOf(
        "schemaVersion" to LOCAL_PLAYBACK_PROFILE_SCHEMA_VERSION,
        "displayWidthPixels" to displayWidthPixels,
        "displayHeightPixels" to displayHeightPixels,
        "displayRevision" to displayRevision,
        "decoderMimeTypes" to decoderMimeTypes,
        "decoderMimeTypesTruncated" to decoderMimeTypesTruncated,
        "decoderRevision" to decoderRevision,
        "networkTransports" to networkTransports,
        "networkValidated" to networkValidated,
        "networkMetered" to networkMetered,
        "networkDownstreamKbps" to networkDownstreamKbps,
        "networkRevision" to networkRevision,
    )
}

internal class LocalPlaybackCapabilityObserver(
    private val activity: Activity,
    private val ownerGeneration: Long = nextOwnerGeneration(),
    private val displayReader: () -> LocalPlaybackDisplayFacts? = {
        readDisplay(activity)
    },
    private val decoderReader: () -> LocalPlaybackDecoderFacts? = ::readDecoders,
    private val networkReader: () -> LocalPlaybackNetworkFacts? = {
        readNetwork(activity)
    },
) {
    fun snapshot(): LocalPlaybackNativeSnapshot? {
        if (stale()) return null
        val display = displayReader() ?: return null
        val decoders = decoderReader() ?: return null
        val network = networkReader() ?: return null
        if (stale() || displayReader() != display || networkReader() != network) {
            return null
        }
        val displayRevision = revision(
            "display",
            ownerGeneration,
            display.id,
            display.modeId,
            display.widthPixels,
            display.heightPixels,
            display.refreshRateBits,
            display.hdrTypes.joinToString(","),
        )
        val decoderRevision = revision(
            "decoder",
            ownerGeneration,
            decoders.truncated,
            decoders.mimeTypes.joinToString(","),
        )
        val networkRevision = revision(
            "network",
            ownerGeneration,
            network.handle,
            network.transports.joinToString(","),
            network.validated,
            network.metered,
            network.downstreamKbps ?: 0,
        )
        return LocalPlaybackNativeSnapshot(
            displayWidthPixels = display.widthPixels,
            displayHeightPixels = display.heightPixels,
            displayRevision = displayRevision,
            decoderMimeTypes = decoders.mimeTypes,
            decoderMimeTypesTruncated = decoders.truncated,
            decoderRevision = decoderRevision,
            networkTransports = network.transports,
            networkValidated = network.validated,
            networkMetered = network.metered,
            networkDownstreamKbps = network.downstreamKbps,
            networkRevision = networkRevision,
        )
    }

    private fun stale(): Boolean = activity.isFinishing || activity.isDestroyed

    companion object {
        private val owners = AtomicLong(0)

        private fun nextOwnerGeneration(): Long = owners.incrementAndGet().let {
            if (it > 0) it else {
                owners.set(1)
                1
            }
        }

        @Suppress("DEPRECATION")
        private fun readDisplay(activity: Activity): LocalPlaybackDisplayFacts? = try {
            val display = if (Build.VERSION.SDK_INT >= 30) {
                activity.display
            } else {
                activity.windowManager.defaultDisplay
            } ?: return null
            val mode = display.mode
            val width = mode.physicalWidth.takeIf { it in 1..MAX_DISPLAY_PIXELS }
                ?: return null
            val height = mode.physicalHeight.takeIf { it in 1..MAX_DISPLAY_PIXELS }
                ?: return null
            val hdrTypes = display.hdrCapabilities?.supportedHdrTypes
                ?.asSequence()
                ?.mapNotNull(::hdrType)
                ?.distinct()
                ?.sorted()
                ?.toList()
                ?: emptyList()
            if (hdrTypes.size > MAX_HDR_TYPES) return null
            LocalPlaybackDisplayFacts(
                id = display.displayId,
                modeId = mode.modeId,
                widthPixels = width,
                heightPixels = height,
                refreshRateBits = mode.refreshRate.toRawBits(),
                hdrTypes = hdrTypes,
            )
        } catch (_: Exception) {
            null
        }

        private fun readDecoders(): LocalPlaybackDecoderFacts? = try {
            val values = MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos
                .asSequence()
                .filterNot { it.isEncoder }
                .flatMap { it.supportedTypes.asSequence() }
                .map { it.trim().lowercase(Locale.ROOT) }
                .filter { LOCAL_PLAYBACK_MIME_TYPE.matches(it) }
                .distinct()
                .sorted()
                .toList()
            LocalPlaybackDecoderFacts(
                mimeTypes = values.take(MAX_DECODER_MIME_TYPES),
                truncated = values.size > MAX_DECODER_MIME_TYPES,
            )
        } catch (_: Exception) {
            null
        }

        private fun readNetwork(activity: Activity): LocalPlaybackNetworkFacts? = try {
            val manager = activity.getSystemService(Context.CONNECTIVITY_SERVICE)
                as? ConnectivityManager ?: return null
            val network = manager.activeNetwork ?: return null
            val capabilities = manager.getNetworkCapabilities(network) ?: return null
            val transports = networkTransports(capabilities) ?: return null
            LocalPlaybackNetworkFacts(
                handle = network.networkHandle,
                transports = transports,
                validated = capabilities.hasCapability(
                    NetworkCapabilities.NET_CAPABILITY_VALIDATED,
                ),
                metered = !capabilities.hasCapability(
                    NetworkCapabilities.NET_CAPABILITY_NOT_METERED,
                ),
                downstreamKbps = capabilities.linkDownstreamBandwidthKbps
                    .takeIf { it in 1..MAX_DOWNSTREAM_KBPS },
            )
        } catch (_: Exception) {
            null
        }

        private fun networkTransports(
            capabilities: NetworkCapabilities,
        ): List<String>? {
            val candidates = buildList {
                add(NetworkCapabilities.TRANSPORT_BLUETOOTH to "bluetooth")
                add(NetworkCapabilities.TRANSPORT_CELLULAR to "cellular")
                add(NetworkCapabilities.TRANSPORT_ETHERNET to "ethernet")
                add(NetworkCapabilities.TRANSPORT_LOWPAN to "lowpan")
                add(NetworkCapabilities.TRANSPORT_USB to "usb")
                add(NetworkCapabilities.TRANSPORT_VPN to "vpn")
                add(NetworkCapabilities.TRANSPORT_WIFI to "wifi")
                add(NetworkCapabilities.TRANSPORT_WIFI_AWARE to "wifiAware")
                if (Build.VERSION.SDK_INT >= 35) {
                    add(NetworkCapabilities.TRANSPORT_SATELLITE to "satellite")
                }
                if (Build.VERSION.SDK_INT >= 36) {
                    add(NetworkCapabilities.TRANSPORT_THREAD to "thread")
                }
            }
            val values = candidates
                .asSequence()
                .filter { capabilities.hasTransport(it.first) }
                .map { it.second }
                .sorted()
                .toList()
            return values.takeIf { it.size <= MAX_NETWORK_TRANSPORTS }
        }

        private fun hdrType(value: Int): String? = when (value) {
            Display.HdrCapabilities.HDR_TYPE_DOLBY_VISION -> "dolbyVision"
            Display.HdrCapabilities.HDR_TYPE_HDR10 -> "hdr10"
            Display.HdrCapabilities.HDR_TYPE_HLG -> "hlg"
            Display.HdrCapabilities.HDR_TYPE_HDR10_PLUS -> "hdr10Plus"
            Display.HdrCapabilities.HDR_TYPE_HLG_PLUS -> "hlgPlus"
            else -> null
        }

        internal fun revision(namespace: String, vararg facts: Any): Long {
            val canonical = buildString {
                append(namespace.length).append(':').append(namespace)
                for (fact in facts) {
                    val value = fact.toString()
                    append('|').append(value.length).append(':').append(value)
                }
            }
            val digest = MessageDigest.getInstance("SHA-256").digest(
                canonical.toByteArray(StandardCharsets.UTF_8),
            )
            var result = 0L
            repeat(7) { index ->
                result = (result shl 8) or (digest[index].toLong() and 0xffL)
            }
            result = result and LOCAL_PLAYBACK_MAX_SAFE_INTEGER
            return if (result == 0L) 1L else result
        }

        private val LOCAL_PLAYBACK_MIME_TYPE = Regex(
            "[a-z0-9][a-z0-9!#&^_.+-]{0,63}/" +
                "[a-z0-9][a-z0-9!#&^_.+-]{0,127}",
        )
    }
}
