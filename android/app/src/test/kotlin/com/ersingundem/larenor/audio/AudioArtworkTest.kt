package com.ersingundem.larenor.audio

import android.app.Application
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.net.Uri
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.io.ByteArrayOutputStream
import java.util.concurrent.ExecutionException

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class AudioArtworkTest {
    private fun image(width: Int = 1024, height: Int = 768): ByteArray {
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        bitmap.eraseColor(Color.argb(128, 250, 100, 20))
        val bytes = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.PNG, 100, bytes)
        bitmap.recycle()
        return bytes.toByteArray()
    }
    private fun rejects(block: () -> Unit) {
        try { block(); fail("Expected safe rejection") } catch (error: AudioRejected) {
            assertEquals("Local audio operation rejected", error.message)
        }
    }
    @Test fun decodesPixelsResizesAndStripsAncillaryPayloadBeforeSession() {
        val input = image() + "private-location-and-file-name".toByteArray()
        val output = AudioArtwork.prepare(input)
        assertEquals(512, output.width)
        assertEquals(384, output.height)
        assertTrue(output.bytes.size <= AudioArtwork.MAX_OUTPUT_BYTES)
        assertFalse(String(output.bytes).contains("private-location-and-file-name"))
        val decoded = BitmapFactory.decodeByteArray(output.bytes, 0, output.bytes.size)
        assertNotNull(decoded)
        assertEquals(255, Color.alpha(decoded.getPixel(0, 0)))
        decoded.recycle()
        val packet = output.packet()
        (packet["bytes"] as ByteArray).fill(0)
        assertEquals(255, output.bytes.first().toInt() and 255)
        assertEquals("AudioArtwork(redacted)", output.toString())
    }
    @Test fun jpegOrientationIsAppliedToPixelsBeforeExifIsRemoved() {
        val jpeg = AudioArtwork.prepare(image(32, 16)).bytes
        // Standard TIFF orientation=6 (90 degrees clockwise), inside JPEG APP1.
        val exif = byteArrayOf(69,120,105,102,0,0, 73,73,42,0,8,0,0,0,
            1,0, 18,1,3,0,1,0,0,0,6,0,0,0, 0,0,0,0)
        val payload = jpeg.take(2).toByteArray() + byteArrayOf(0xff.toByte(),0xe1.toByte(),0,(exif.size+2).toByte()) + exif + jpeg.drop(2).toByteArray()
        val prepared = AudioArtwork.prepare(payload)
        assertEquals(16, prepared.width)
        assertEquals(32, prepared.height)
        assertFalse(String(prepared.bytes).contains("Exif"))
    }
    @Test fun rejectsNonImagesTruncationOversizeDimensionsAndOversizeBytes() {
        rejects { AudioArtwork.prepare("https://user:secret@example/image".toByteArray()) }
        rejects { AudioArtwork.prepare(byteArrayOf(0xff.toByte(), 0xd8.toByte(), 0xff.toByte())) }
        rejects { AudioArtwork.prepare(image(4097, 1)) }
        rejects { AudioArtwork.prepare(ByteArray(AudioArtwork.MAX_INPUT_BYTES + 1)) }
        rejects { AudioSource.parse(sourceMap() + ("artworkUri" to "https://example/art?token=secret")) }
        rejects { AudioSource.parse(sourceMap() + ("artworkBytes" to ByteArray(AudioArtwork.MAX_OUTPUT_BYTES + 1))) }
    }
    @Test fun sameSourceIdStillExpiresOldDecodeAndStopCannotReviveArtwork() {
        val state = AudioArtworkState()
        val decoded = AudioArtwork.prepare(image(32, 16))
        val first = state.begin("same-source", true)
        val second = state.begin("same-source", true)
        assertFalse(state.complete(first, decoded))
        assertTrue(state.complete(second, decoded))
        val id = state.artworkId!!
        assertNotNull(state.read("same-source", id)["bytes"])
        state.begin("replacement", false)
        assertNull(state.artwork)
        rejects { state.read("same-source", id) }
        val third = state.begin("third", true)
        state.clear()
        assertFalse(state.complete(third, decoded))
        assertEquals("none", state.phase)
    }
    @Test fun failedCoverRemainsExplicitWithoutLosingAudioTitleOrLeavingOldImage() {
        val state = AudioArtworkState()
        val ticket = state.begin("station", true)
        assertTrue(state.complete(ticket, null))
        assertEquals("failed", state.phase)
        assertNull(state.artworkId)
        val source = AudioSource.parse(sourceMap())
        val covered = selectedAudioMetadata(source, AudioArtwork.prepare(image(32, 16)))
        assertNotNull(covered.artworkData)
        assertNull(covered.artworkUri)
        val fallback = selectedAudioMetadata(source, state.artwork)
        assertEquals("Chosen title", fallback.title)
        assertNull(fallback.artworkData)
        assertNull(selectedAudioMetadata(null, null).artworkData)
    }
    @Test fun loaderNeverFetchesAnyUriAndAcceptsOnlyCurrentSelectedBytes() {
        val state = AudioArtworkState()
        val loader = SelectedAudioBitmapLoader(state)
        for (uri in listOf("https://example/art.jpg", "http://127.0.0.1/redirect", "https://user:secret@example/art?token=secret", "file:///private/art")) {
            try { loader.loadBitmap(Uri.parse(uri)).get(); fail() } catch (_: ExecutionException) { }
        }
        val art = AudioArtwork.prepare(image(32, 16))
        try { loader.decodeBitmap(art.bytes).get(); fail() } catch (_: ExecutionException) { }
        val ticket = state.begin("station", true)
        state.complete(ticket, art)
        val bitmap = loader.decodeBitmap(art.bytes).get()
        assertSame(bitmap, loader.decodeBitmap(art.bytes.copyOf()).get())
        assertEquals(32, bitmap.width)
        state.clear()
        try { loader.decodeBitmap(art.bytes).get(); fail() } catch (_: ExecutionException) { }
    }
    private fun sourceMap() = mapOf("id" to "station", "uri" to "https://radio.example/live", "mimeType" to "audio/mpeg", "title" to "Chosen title", "artist" to "Chosen artist", "album" to "Chosen album")
}
