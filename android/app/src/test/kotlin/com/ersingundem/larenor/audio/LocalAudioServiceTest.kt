package com.ersingundem.larenor.audio

import android.app.Application
import android.app.Service
import android.content.Intent
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import android.net.Uri
import org.junit.After
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class LocalAudioServiceTest {
    private val foregroundOwner = Any()
    @After fun clearRuntime() {
        LocalAudioRuntime.coordinator.stop()
        LocalAudioRuntime.setForeground(foregroundOwner, false)
    }

    @Test fun actualServiceIsIdleUntilAuthorizedSourceAndStopReleasesSession() {
        val service = Robolectric.buildService(LocalAudioService::class.java).create()
        try {
            val actual = service.get()
            assertTrue(LocalAudioRuntime.coordinator.hasOwner)
            assertEquals(1, actual.sessions.size)
            assertEquals(0, actual.sessions.single().player.mediaItemCount)
            assertTrue(actual.sessions.single().player.trackSelectionParameters.disabledTrackTypes.contains(C.TRACK_TYPE_VIDEO))
            actual.sessions.single().player.play()
            assertFalse(actual.sessions.single().player.playWhenReady)
            assertNull(Shadows.shadowOf(actual).lastForegroundNotification)
            LocalAudioRuntime.coordinator.stop()
            assertFalse(LocalAudioRuntime.coordinator.hasOwner)
            assertTrue(actual.sessions.isEmpty())
            assertTrue(Shadows.shadowOf(actual).isStoppedBySelf)
            assertEquals("idle", LocalAudioRuntime.coordinator.state.phase)
        } finally { service.destroy() }
    }

    @Test fun actualSessionCannotExposeUnselectedEmbeddedArtworkOrMetadataUrl() {
        val service = Robolectric.buildService(LocalAudioService::class.java).create()
        try {
            val session = service.get().sessions.single()
            // No prepare/play: exercise the real MediaSession's public metadata
            // projection without opening any socket or starting audio.
            session.player.setMediaItem(MediaItem.Builder().setMediaId("opaque")
                .setUri("https://fixture.invalid/audio")
                .setMediaMetadata(MediaMetadata.Builder().setTitle("unselected stream tag")
                    .setArtworkUri(Uri.parse("https://example/private?token=secret"))
                    .setArtworkData(byteArrayOf(1, 2, 3), MediaMetadata.PICTURE_TYPE_FRONT_COVER).build()).build())
            assertNull(session.player.mediaMetadata.artworkUri)
            assertNull(session.player.mediaMetadata.artworkData)
            assertNull(session.player.mediaMetadata.title)
            try { session.bitmapLoader.loadBitmap(Uri.parse("https://example/image")).get(); fail() }
            catch (_: java.util.concurrent.ExecutionException) { }
            assertNull(Shadows.shadowOf(service.get()).lastForegroundNotification)
        } finally { service.destroy() }
    }

    @Test fun externalStartAndKilledProcessRestartCannotAutoplayOrBecomeForeground() {
        for (intent in listOf(null, Intent(LocalAudioService.ACTION_PLAY)
            .putExtra(LocalAudioService.EXTRA_TICKET, "invented-external-ticket"))) {
            val service = Robolectric.buildService(LocalAudioService::class.java).create()
            try {
                val actual = service.get()
                assertEquals(Service.START_NOT_STICKY, actual.onStartCommand(intent, 0, 1))
                assertFalse(LocalAudioRuntime.coordinator.hasOwner)
                assertFalse(LocalAudioRuntime.coordinator.state.isPlaying)
                assertNull(LocalAudioRuntime.coordinator.state.sourceId)
                assertTrue(actual.sessions.isEmpty())
                assertNull(Shadows.shadowOf(actual).lastForegroundNotification)
            } finally { service.destroy() }
        }
    }

    @Test fun backgroundBeforeServiceConsumesValidTicketPreventsAnyMediaSelection() {
        val coordinator = LocalAudioRuntime.coordinator
        LocalAudioRuntime.setForeground(foregroundOwner, true)
        val source = AudioSource.parse(mapOf("id" to "station", "title" to "Station",
            "mimeType" to "audio/mpeg", "uri" to "https://fixture.invalid/audio.mp3"))
        val ticket = coordinator.request(source, true)
        LocalAudioRuntime.setForeground(foregroundOwner, false)
        val service = Robolectric.buildService(LocalAudioService::class.java).create()
        try {
            val actual = service.get()
            actual.onStartCommand(Intent(LocalAudioService.ACTION_PLAY)
                .putExtra(LocalAudioService.EXTRA_TICKET, ticket), 0, 1)
            assertFalse(coordinator.hasPending)
            assertFalse(coordinator.hasOwner)
            assertTrue(actual.sessions.isEmpty())
            assertNull(Shadows.shadowOf(actual).lastForegroundNotification)
        } finally { service.destroy() }
    }
}
