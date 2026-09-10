package com.ersingundem.larenor.music

import android.app.Application
import android.app.Service
import android.content.Intent
import androidx.media3.common.Player
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class CoreMusicSessionServiceTest {
    @After fun clearRuntime() {
        CoreMusicSessionRuntime.clear()
        CoreMusicSessionRuntime.setActionSink(null)
    }

    @Test fun validOpaqueTicketPublishesSanitizedMedia3StateAndActions() {
        val snapshot = fixture()
        val ticket = CoreMusicSessionRuntime.stage(snapshot, foreground = true)
        val service = Robolectric.buildService(CoreMusicSessionService::class.java).create()
        try {
            val actual = service.get()
            assertEquals(
                Service.START_NOT_STICKY,
                actual.onStartCommand(
                    Intent(CoreMusicSessionService.ACTION_PUBLISH)
                        .putExtra(CoreMusicSessionService.EXTRA_TICKET, ticket),
                    0,
                    1,
                ),
            )
            val player = actual.sessions.single().player
            assertEquals(1, player.mediaItemCount)
            assertEquals("core-music", player.currentMediaItem?.mediaId)
            assertEquals("Fixture song", player.mediaMetadata.title)
            assertNull(player.currentMediaItem?.localConfiguration)
            assertTrue(player.isCommandAvailable(Player.COMMAND_PLAY_PAUSE))
            assertTrue(player.isCommandAvailable(Player.COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM))

            var action: CoreMusicSessionAction? = null
            CoreMusicSessionRuntime.setActionSink { action = it }
            player.play()
            assertEquals("play", action?.action)
            assertEquals(snapshot.sessionId, action?.sessionId)
            assertEquals(snapshot.playerRevision, action?.playerRevision)
            assertFalse(player.playWhenReady)
        } finally {
            service.destroy()
        }
    }

    @Test fun inventedTicketAndProcessRestartFailClosedWithoutSessionState() {
        val service = Robolectric.buildService(CoreMusicSessionService::class.java).create()
        try {
            val actual = service.get()
            assertEquals(
                Service.START_NOT_STICKY,
                actual.onStartCommand(
                    Intent(CoreMusicSessionService.ACTION_PUBLISH)
                        .putExtra(CoreMusicSessionService.EXTRA_TICKET, "invented"),
                    0,
                    1,
                ),
            )
            assertTrue(actual.sessions.isEmpty())
            assertNull(CoreMusicSessionRuntime.snapshot)
        } finally {
            service.destroy()
        }
    }

    private fun fixture() = CoreMusicSessionSnapshot.parse(mapOf(
        "sessionId" to "0123456789abcdef0123456789abcdef",
        "playerRevision" to 7L,
        "title" to "Fixture song",
        "positionMs" to 12_000L,
        "durationMs" to 180_000L,
        "isPlaying" to false,
        "isGroup" to true,
        "canPlay" to true,
        "canPause" to true,
        "canNext" to true,
        "canPrevious" to true,
        "canSeek" to true,
        "canVolume" to true,
        "volumeLevel" to 42,
        "controlsAuthorized" to true,
    ))
}
