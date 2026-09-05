package com.ersingundem.larenor.audio

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Matrix
import android.media.ExifInterface
import java.io.ByteArrayInputStream
import android.net.Uri
import androidx.media3.common.MediaMetadata
import androidx.media3.common.util.BitmapLoader
import androidx.media3.common.util.UnstableApi
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import java.io.ByteArrayOutputStream
import java.util.UUID

/** Only a user-selected local image enters this pipeline. It has no URL loader,
 * credentials, disk cache, EXIF output, or metadata-derived network requests. */
class AudioArtwork private constructor(val bytes: ByteArray, val width: Int, val height: Int) {
    override fun toString() = "AudioArtwork(redacted)"
    fun packet(): Map<String, Any> = mapOf("bytes" to bytes.copyOf(), "width" to width, "height" to height)
    companion object {
        const val MAX_INPUT_BYTES = 1024 * 1024
        const val MAX_OUTPUT_BYTES = 128 * 1024
        const val MAX_DIMENSION = 512
        private const val MAX_INPUT_DIMENSION = 4096
        private const val MAX_INPUT_PIXELS = 16 * 1024 * 1024L

        fun input(value: Any?, limit: Int = MAX_INPUT_BYTES): ByteArray {
            if (value !is ByteArray || value.isEmpty() || value.size > limit) throw AudioRejected("invalidArtwork")
            val png = value.size >= 8 && value.take(8).map { it.toInt() and 255 } == listOf(137, 80, 78, 71, 13, 10, 26, 10)
            val jpeg = value.size >= 3 && value[0] == 0xff.toByte() && value[1] == 0xd8.toByte() && value[2] == 0xff.toByte()
            if (!png && !jpeg) throw AudioRejected("invalidArtwork")
            return value.copyOf()
        }

        fun prepare(value: Any?): AudioArtwork {
            val input = input(value)
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(input, 0, input.size, bounds)
            if (bounds.outMimeType !in setOf("image/png", "image/jpeg") ||
                bounds.outWidth !in 1..MAX_INPUT_DIMENSION || bounds.outHeight !in 1..MAX_INPUT_DIMENSION ||
                bounds.outWidth.toLong() * bounds.outHeight > MAX_INPUT_PIXELS) throw AudioRejected("invalidArtwork")
            var sample = 1
            while (maxOf(bounds.outWidth, bounds.outHeight) / sample > MAX_DIMENSION) sample *= 2
            val options = BitmapFactory.Options().apply { inSampleSize = sample; inPreferredConfig = Bitmap.Config.ARGB_8888 }
            val decoded = BitmapFactory.decodeByteArray(input, 0, input.size, options) ?: throw AudioRejected("invalidArtwork")
            try {
                if (decoded.width !in 1..MAX_DIMENSION || decoded.height !in 1..MAX_DIMENSION) throw AudioRejected("invalidArtwork")
                // Flatten transparency on a neutral background, and re-encode
                // pixels only. Camera EXIF/location/text chunks never leave here.
                val orientation = if (bounds.outMimeType == "image/jpeg") {
                    try { ExifInterface(ByteArrayInputStream(input)).getAttributeInt(ExifInterface.TAG_ORIENTATION, 1) }
                    catch (_: Exception) { 1 }
                } else 1
                val matrix = Matrix().apply {
                    when (orientation) {
                        2 -> setScale(-1f, 1f)
                        3 -> setRotate(180f)
                        4 -> setScale(1f, -1f)
                        5 -> { setScale(-1f, 1f); postRotate(270f) }
                        6 -> setRotate(90f)
                        7 -> { setScale(-1f, 1f); postRotate(90f) }
                        8 -> setRotate(270f)
                    }
                }
                val oriented = Bitmap.createBitmap(decoded, 0, 0, decoded.width, decoded.height, matrix, true)
                val clean = Bitmap.createBitmap(oriented.width, oriented.height, Bitmap.Config.ARGB_8888)
                try {
                    Canvas(clean).apply { drawColor(Color.rgb(238, 238, 240)); drawBitmap(oriented, 0f, 0f, Paint()) }
                    for (quality in listOf(88, 75, 60)) {
                        val output = ByteArrayOutputStream()
                        if (clean.compress(Bitmap.CompressFormat.JPEG, quality, output) && output.size() <= MAX_OUTPUT_BYTES) {
                            return AudioArtwork(output.toByteArray(), clean.width, clean.height)
                        }
                    }
                    throw AudioRejected("invalidArtwork")
                } finally { clean.recycle(); if (oriented !== decoded) oriented.recycle() }
            } finally { decoded.recycle() }
        }
    }
}

/** Main-thread identity lease. Even reusing a source ID cannot apply the late
 * cover from an earlier play request, and stop never revives a cached cover. */
class AudioArtworkState {
    private var generation = 0L
    var phase = "none"; private set
    var sourceId: String? = null; private set
    var artworkId: String? = null; private set
    var artwork: AudioArtwork? = null; private set
    fun begin(sourceId: String, hasArtwork: Boolean): Long {
        clear()
        this.sourceId = sourceId
        phase = if (hasArtwork) "loading" else "none"
        return generation
    }
    fun complete(ticket: Long, result: AudioArtwork?): Boolean {
        if (ticket != generation || phase != "loading") return false
        artwork = result
        artworkId = result?.let { UUID.randomUUID().toString() }
        phase = if (result == null) "failed" else "ready"
        return true
    }
    fun clear() { generation++; sourceId = null; artworkId = null; artwork = null; phase = "none" }
    fun read(sourceId: String, artworkId: String): Map<String, Any> {
        if (sourceId != this.sourceId || artworkId != this.artworkId || phase != "ready") throw AudioRejected("unavailable")
        return artwork?.packet() ?: throw AudioRejected("unavailable")
    }
}

/** Media3's default loader can fetch artworkUri supplied by extracted media
 * metadata. This loader accepts only this session's sanitized selected bytes. */
@UnstableApi
class SelectedAudioBitmapLoader(private val state: AudioArtworkState) : BitmapLoader {
    private var cachedId: String? = null
    private var cachedBitmap: Bitmap? = null
    override fun supportsMimeType(mimeType: String) = mimeType == "image/jpeg"
    override fun loadBitmap(uri: Uri): ListenableFuture<Bitmap> =
        Futures.immediateFailedFuture(SecurityException("Artwork URL unavailable"))
    override fun decodeBitmap(data: ByteArray): ListenableFuture<Bitmap> {
        val current = state.artwork
        if (cachedId != state.artworkId) { cachedId = null; cachedBitmap = null }
        if (current == null || !current.bytes.contentEquals(data)) {
            return Futures.immediateFailedFuture(SecurityException("Artwork unavailable"))
        }
        cachedBitmap?.let { return Futures.immediateFuture(it) }
        return try {
            val bitmap = BitmapFactory.decodeByteArray(data, 0, data.size) ?: throw AudioRejected("invalidArtwork")
            cachedId = state.artworkId
            cachedBitmap = bitmap
            Futures.immediateFuture(bitmap)
        } catch (_: Exception) { Futures.immediateFailedFuture(AudioRejected("invalidArtwork")) }
    }
}

/** Rebuilding from the selected source also clears artwork for a new source,
 * failed decode, stop or killed service. No extracted-media URI is forwarded. */
@UnstableApi
fun selectedAudioMetadata(source: AudioSource?, artwork: AudioArtwork?): MediaMetadata {
    if (source == null) return MediaMetadata.EMPTY
    return MediaMetadata.Builder().setTitle(source.title).setArtist(source.artist)
        .setAlbumTitle(source.album).setIsBrowsable(false).setIsPlayable(true)
        .setArtworkData(artwork?.bytes, MediaMetadata.PICTURE_TYPE_FRONT_COVER).build()
}
