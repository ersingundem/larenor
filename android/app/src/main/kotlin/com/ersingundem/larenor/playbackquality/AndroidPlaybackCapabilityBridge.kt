package com.ersingundem.larenor.playbackquality

import android.app.Activity
import android.content.Context
import android.hardware.display.DisplayManager
import android.media.MediaCodecList
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.view.Display
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

class AndroidPlaybackCapabilityBridge(
    context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    private val appContext = context.applicationContext
    private val localPlayback = (context as? Activity)?.let(
        ::LocalPlaybackCapabilityObserver,
    )
    private val channel = MethodChannel(messenger, CHANNEL)
    private var disposed = false

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (disposed) {
            result.error("bridgeDisposed", null, null)
            return
        }
        if (call.method != METHOD_SNAPSHOT &&
            call.method != METHOD_LOCAL_PLAYBACK_PROFILE
        ) {
            result.notImplemented()
            return
        }
        if (call.arguments != null) {
            result.error("invalidRequest", null, null)
            return
        }

        if (call.method == METHOD_LOCAL_PLAYBACK_PROFILE) {
            val snapshot = localPlayback?.snapshot()
            if (snapshot == null) {
                result.error("capabilityUnavailable", null, null)
            } else {
                result.success(snapshot.toChannel())
            }
            return
        }
        val decoders = decoderMimeTypes()
        val display = displayEvidence()
        val network = networkEvidence()
        result.success(
            AndroidPlaybackCapabilitySnapshot(
                decoderMimeTypes = decoders.values,
                decoderMimeTypesTruncated = decoders.truncated,
                displayWidthPixels = display.widthPixels,
                displayHeightPixels = display.heightPixels,
                displayHdrTypes = display.hdrTypes,
                networkTransports = network.transports,
                networkValidated = network.validated,
                networkMetered = network.metered,
                networkDownstreamKbps = network.downstreamKbps,
            ).toChannel(),
        )
    }

    private fun decoderMimeTypes(): BoundedDecoderMimeTypes = try {
        val values = MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos
            .asSequence()
            .filterNot { it.isEncoder }
            .flatMap { it.supportedTypes.asSequence() }
            .map { it.trim().lowercase(Locale.ROOT) }
            .filter { MIME_TYPE.matches(it) }
            .distinct()
            .sorted()
            .toList()
        BoundedDecoderMimeTypes(
            values = values.take(MAX_DECODER_MIME_TYPES),
            truncated = values.size > MAX_DECODER_MIME_TYPES,
        )
    } catch (_: Exception) {
        BoundedDecoderMimeTypes(values = null, truncated = false)
    }

    @Suppress("DEPRECATION")
    private fun displayEvidence(): BoundedDisplayEvidence = try {
        val manager = appContext.getSystemService(Context.DISPLAY_SERVICE) as? DisplayManager
        val display = manager?.getDisplay(Display.DEFAULT_DISPLAY)
            ?: return BoundedDisplayEvidence(null, null, null)
        val mode = display.mode
        val width = mode.physicalWidth.takeIf { it in 1..MAX_DISPLAY_PIXELS }
        val height = mode.physicalHeight.takeIf { it in 1..MAX_DISPLAY_PIXELS }
        val resolutionValid = width != null && height != null
        BoundedDisplayEvidence(
            widthPixels = width.takeIf { resolutionValid },
            heightPixels = height.takeIf { resolutionValid },
            hdrTypes = display.hdrCapabilities?.supportedHdrTypes?.let(::boundedHdrTypes),
        )
    } catch (_: Exception) {
        BoundedDisplayEvidence(null, null, null)
    }

    private fun boundedHdrTypes(rawTypes: IntArray): List<String>? {
        val values = ArrayList<String>(rawTypes.size)
        for (rawType in rawTypes) {
            val value = when (rawType) {
                Display.HdrCapabilities.HDR_TYPE_DOLBY_VISION -> "dolbyVision"
                Display.HdrCapabilities.HDR_TYPE_HDR10 -> "hdr10"
                Display.HdrCapabilities.HDR_TYPE_HLG -> "hlg"
                Display.HdrCapabilities.HDR_TYPE_HDR10_PLUS -> "hdr10Plus"
                Display.HdrCapabilities.HDR_TYPE_HLG_PLUS -> "hlgPlus"
                else -> return null
            }
            if (value !in values) values.add(value)
        }
        if (values.size > MAX_HDR_TYPES) return null
        return values.sorted()
    }

    private fun networkEvidence(): BoundedNetworkEvidence = try {
        val manager = appContext.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
        val network = manager?.activeNetwork
        val capabilities = network?.let(manager::getNetworkCapabilities)
            ?: return BoundedNetworkEvidence(null, null, null, null)
        val transports = networkTransports(capabilities)
        val downstream = capabilities.linkDownstreamBandwidthKbps
            .takeIf { it in 1..MAX_DOWNSTREAM_KBPS }
        BoundedNetworkEvidence(
            transports = transports,
            validated = capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED),
            metered = !capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED),
            downstreamKbps = downstream,
        )
    } catch (_: Exception) {
        BoundedNetworkEvidence(null, null, null, null)
    }

    private fun networkTransports(capabilities: NetworkCapabilities): List<String>? {
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

    fun dispose() {
        if (disposed) return
        disposed = true
        channel.setMethodCallHandler(null)
    }

    companion object {
        const val CHANNEL = "com.ersingundem.larenor/playback-quality"
        private const val METHOD_SNAPSHOT = "snapshot"
        private const val METHOD_LOCAL_PLAYBACK_PROFILE =
            "localPlaybackProfileSnapshot"
        private val MIME_TYPE = Regex(
            "[a-z0-9][a-z0-9!#&^_.+-]{0,63}/[a-z0-9][a-z0-9!#&^_.+-]{0,127}",
        )
    }
}
