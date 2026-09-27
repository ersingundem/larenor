package com.ersingundem.larenor.playbackquality

internal const val PLAYBACK_CAPABILITY_SCHEMA_VERSION = 1
internal const val MAX_DECODER_MIME_TYPES = 128
internal const val MAX_DISPLAY_PIXELS = 16_384
internal const val MAX_HDR_TYPES = 8
internal const val MAX_NETWORK_TRANSPORTS = 12
internal const val MAX_DOWNSTREAM_KBPS = 10_000_000

internal data class AndroidPlaybackCapabilitySnapshot(
    val decoderMimeTypes: List<String>?,
    val decoderMimeTypesTruncated: Boolean,
    val displayWidthPixels: Int?,
    val displayHeightPixels: Int?,
    val displayHdrTypes: List<String>?,
    val networkTransports: List<String>?,
    val networkValidated: Boolean?,
    val networkMetered: Boolean?,
    val networkDownstreamKbps: Int?,
) {
    fun toChannel(): Map<String, Any?> = mapOf(
        "schemaVersion" to PLAYBACK_CAPABILITY_SCHEMA_VERSION,
        "decoderMimeTypes" to decoderMimeTypes,
        "decoderMimeTypesTruncated" to decoderMimeTypesTruncated,
        "displayWidthPixels" to displayWidthPixels,
        "displayHeightPixels" to displayHeightPixels,
        "displayHdrTypes" to displayHdrTypes,
        "networkTransports" to networkTransports,
        "networkValidated" to networkValidated,
        "networkMetered" to networkMetered,
        "networkDownstreamKbps" to networkDownstreamKbps,
    )
}

internal data class BoundedDecoderMimeTypes(
    val values: List<String>?,
    val truncated: Boolean,
)

internal data class BoundedDisplayEvidence(
    val widthPixels: Int?,
    val heightPixels: Int?,
    val hdrTypes: List<String>?,
)

internal data class BoundedNetworkEvidence(
    val transports: List<String>?,
    val validated: Boolean?,
    val metered: Boolean?,
    // Android's link-capability estimate; this is not measured throughput.
    val downstreamKbps: Int?,
)
