package com.ersingundem.larenor.audio

import android.app.Application
import android.net.Uri
import android.os.Looper
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Metadata
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.SimpleBasePlayer
import androidx.media3.common.Timeline
import androidx.media3.common.Tracks
import androidx.media3.common.util.UnstableApi
import androidx.media3.extractor.metadata.icy.IcyInfo
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
@UnstableApi
class AudioArtworkMetadataReviewTest {
    private fun unsafeMetadata(title: String) = MediaMetadata.Builder()
        .setTitle(title)
        .setArtworkUri(Uri.parse("https://fixture.invalid/private?token=synthetic"))
        .setArtworkData(byteArrayOf(1, 2, 3), MediaMetadata.PICTURE_TYPE_FRONT_COVER)
        .build()

    private fun selected(id: String, title: String) = MediaItem.Builder().setMediaId(id)
        .setMediaMetadata(MediaMetadata.Builder().setTitle(title).setArtist("Selected artist")
            .setAlbumTitle("Selected album").setArtworkData(byteArrayOf(4, 5, 6),
                MediaMetadata.PICTURE_TYPE_FRONT_COVER).build()).build()

    private fun rawState(id: String, tag: String): SimpleBasePlayer.State {
        val metadata = unsafeMetadata(tag)
        val item = MediaItem.Builder().setMediaId(id).setUri("https://fixture.invalid/audio")
            .setMediaMetadata(metadata).setRequestMetadata(MediaItem.RequestMetadata.Builder()
                .setMediaUri(Uri.parse("https://fixture.invalid/request?token=synthetic")).build()).build()
        return SimpleBasePlayer.State.Builder()
            .setAvailableCommands(Player.Commands.Builder().addAll(
                Player.COMMAND_PLAY_PAUSE, Player.COMMAND_STOP,
                Player.COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM, Player.COMMAND_GET_CURRENT_MEDIA_ITEM,
                Player.COMMAND_GET_TIMELINE, Player.COMMAND_GET_METADATA,
                Player.COMMAND_GET_TRACKS, Player.COMMAND_RELEASE,
            ).build())
            .setPlaylist(listOf(SimpleBasePlayer.MediaItemData.Builder(id).setMediaItem(item)
                .setMediaMetadata(metadata).setManifest("synthetic-private-manifest")
                .setDurationUs(10_000_000).setIsSeekable(true).build()))
            .setCurrentMediaItemIndex(0)
            .setPlaylistMetadata(metadata)
            .setTimedMetadata(Metadata(123L, IcyInfo(byteArrayOf(9), tag,
                "https://fixture.invalid/icy?token=synthetic")))
            .build()
    }

    private class StatePlayer(var snapshot: State) : SimpleBasePlayer(Looper.getMainLooper()) {
        val commands = mutableListOf<String>()
        override fun getState() = snapshot
        fun emit(next: State) { snapshot = next; invalidateState() }
        override fun handleSetPlayWhenReady(playWhenReady: Boolean): ListenableFuture<*> {
            commands.add(if (playWhenReady) "play" else "pause")
            emit(snapshot.buildUpon().setPlayWhenReady(playWhenReady,
                Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST).build())
            return Futures.immediateVoidFuture()
        }
        override fun handleSeek(mediaItemIndex: Int, positionMs: Long, seekCommand: Int): ListenableFuture<*> {
            commands.add("seek:$mediaItemIndex:$positionMs")
            emit(snapshot.buildUpon().setContentPositionMs(positionMs)
                .setPositionDiscontinuity(Player.DISCONTINUITY_REASON_SEEK, positionMs).build())
            return Futures.immediateVoidFuture()
        }
        override fun handleStop(): ListenableFuture<*> {
            commands.add("stop")
            emit(snapshot.buildUpon().setPlaybackState(Player.STATE_IDLE).build())
            return Futures.immediateVoidFuture()
        }
        override fun handleRelease() = Futures.immediateVoidFuture()
    }

    private fun assertSelected(item: MediaItem?, title: String) {
        assertNotNull(item)
        assertEquals(title, item!!.mediaMetadata.title)
        assertEquals("Selected artist", item.mediaMetadata.artist)
        assertEquals("Selected album", item.mediaMetadata.albumTitle)
        assertArrayEquals(byteArrayOf(4, 5, 6), item.mediaMetadata.artworkData)
        assertNull(item.mediaMetadata.artworkUri)
        assertNull(item.localConfiguration)
        assertEquals(MediaItem.RequestMetadata.EMPTY, item.requestMetadata)
    }

    @Test fun sessionListenersMustReceiveTheSameSanitizedMetadataAsTheGetter() {
        val owner = Robolectric.buildService(LocalAudioService::class.java).create()
        try {
            val player = owner.get().sessions.single().player
            val events = mutableListOf<MediaMetadata>()
            player.addListener(object : Player.Listener {
                override fun onMediaMetadataChanged(mediaMetadata: MediaMetadata) {
                    events.add(mediaMetadata)
                }
            })
            // No prepare or play: exercising Media3's real event projection
            // performs no socket operation and starts no audio playback.
            player.setMediaItem(MediaItem.Builder().setMediaId("synthetic-item")
                .setUri("https://fixture.invalid/audio")
                .setMediaMetadata(MediaMetadata.Builder()
                    .setTitle("unselected stream tag")
                    .setArtworkUri(Uri.parse("https://fixture.invalid/private?token=synthetic"))
                    .setArtworkData(byteArrayOf(1, 2, 3), MediaMetadata.PICTURE_TYPE_FRONT_COVER)
                    .build()).build())
            Shadows.shadowOf(Looper.getMainLooper()).idle()
            assertNull(player.mediaMetadata.title)
            assertNull(player.mediaMetadata.artworkUri)
            assertEquals(MediaItem.EMPTY, player.currentMediaItem)
            assertEquals(MediaItem.EMPTY, player.getMediaItemAt(0))
            val window = player.currentTimeline.getWindow(0, Timeline.Window())
            assertEquals(MediaItem.EMPTY, window.mediaItem)
            assertNull(window.manifest)
            // A correctly filtered wrapper may suppress this event entirely.
            // If it forwards an event, it must match its sanitized getter.
            for (event in events) {
                assertNull("Extracted title leaked through Player.Listener", event.title)
                assertNull("Artwork URL leaked through Player.Listener", event.artworkUri)
                assertNull("Unselected bytes leaked through Player.Listener", event.artworkData)
            }
            assertFalse(player.isPlaying)
        } finally {
            LocalAudioRuntime.coordinator.stop()
            owner.destroy()
        }
    }

    @Test fun stateProjectionFiltersTimelinePlaylistTimedTagsAndErrorCauses() {
        var chosen = selected("first", "Chosen title")
        val raw = StatePlayer(rawState("first", "embedded first"))
        val exposed = SelectedAudioPlayer(raw) { chosen }
        try {
            assertSelected(exposed.currentMediaItem, "Chosen title")
            assertSelected(exposed.getMediaItemAt(0), "Chosen title")
            assertNull(exposed.currentTimeline.getWindow(0, Timeline.Window()).manifest)
            assertEquals(MediaMetadata.EMPTY, exposed.playlistMetadata)
            assertEquals(Tracks.EMPTY, exposed.currentTracks)
            var timedEvents = 0
            var errorEvents = 0
            val transitions = mutableListOf<MediaItem?>()
            val timelines = mutableListOf<Timeline>()
            exposed.addListener(object : Player.Listener {
                override fun onMetadata(metadata: Metadata) { timedEvents++ }
                override fun onPlayerErrorChanged(error: PlaybackException?) { errorEvents++ }
                override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) { transitions.add(mediaItem) }
                override fun onTimelineChanged(timeline: Timeline, reason: Int) { timelines.add(timeline) }
            })
            chosen = selected("second", "Second selected")
            raw.emit(rawState("second", "embedded second").buildUpon()
                .setPlayerError(PlaybackException("https://fixture.invalid/private?token=synthetic",
                    IllegalArgumentException("private cause"), PlaybackException.ERROR_CODE_IO_UNSPECIFIED)).build())
            Shadows.shadowOf(Looper.getMainLooper()).idle()
            assertEquals(0, timedEvents)
            assertEquals(1, transitions.size)
            assertSelected(transitions.single(), "Second selected")
            assertFalse(timelines.isEmpty())
            for (timeline in timelines) {
                assertSelected(timeline.getWindow(0, Timeline.Window()).mediaItem, "Second selected")
            }
            assertEquals("Audio playback unavailable", exposed.playerError?.message)
            assertNull(exposed.playerError?.cause)
            assertEquals(PlaybackException.ERROR_CODE_IO_UNSPECIFIED, exposed.playerError?.errorCode)
            raw.emit(raw.snapshot.buildUpon().setContentPositionMs(100).build())
            Shadows.shadowOf(Looper.getMainLooper()).idle()
            assertEquals("An unchanged failure must not become a new error on every state update", 1, errorEvents)
        } finally { exposed.release() }
    }

    @Test fun batchEventsUseSafeWrapperAndListenerRemovalKeepsOneRegistration() {
        var chosen = selected("first", "First")
        val raw = StatePlayer(rawState("first", "raw first"))
        val exposed = SelectedAudioPlayer(raw) { chosen }
        try {
            assertSelected(exposed.currentMediaItem, "First")
            val batches = mutableListOf<String>()
            val callbackTitles = mutableListOf<String>()
            val listener = object : Player.Listener {
                override fun onMediaMetadataChanged(mediaMetadata: MediaMetadata) {
                    callbackTitles.add(mediaMetadata.title.toString())
                    assertNull(mediaMetadata.artworkUri)
                }
                override fun onEvents(player: Player, events: Player.Events) {
                    assertSame(exposed, player)
                    assertTrue(events.contains(Player.EVENT_MEDIA_METADATA_CHANGED))
                    assertSelected(player.currentMediaItem, "Latest")
                    batches.add(player.mediaMetadata.title.toString())
                }
            }
            exposed.addListener(listener)
            exposed.addListener(listener)
            chosen = selected("second", "Intermediate")
            raw.emit(rawState("second", "raw second"))
            chosen = selected("third", "Latest")
            raw.emit(rawState("third", "raw third"))
            Shadows.shadowOf(Looper.getMainLooper()).idle()
            assertEquals(listOf("Latest"), batches)
            assertEquals(listOf("Latest"), callbackTitles)
            exposed.removeListener(listener)
            exposed.removeListener(listener)
            chosen = selected("fourth", "Removed")
            raw.emit(rawState("fourth", "raw fourth"))
            Shadows.shadowOf(Looper.getMainLooper()).idle()
            assertEquals(listOf("Latest"), batches)
            assertEquals(listOf("Latest"), callbackTitles)
        } finally { exposed.release() }
    }

    @Test fun sourceReplacementCannotRelabelOldTimelineAndPlaybackCommandsStillForward() {
        var chosen = selected("first", "First")
        val raw = StatePlayer(rawState("first", "embedded first"))
        val exposed = SelectedAudioPlayer(raw) { chosen }
        try {
            assertSelected(exposed.currentMediaItem, "First")
            chosen = selected("second", "Second")
            raw.emit(rawState("first", "old stream update"))
            Shadows.shadowOf(Looper.getMainLooper()).idle()
            assertEquals(MediaItem.EMPTY, exposed.currentMediaItem)
            assertEquals(MediaMetadata.EMPTY, exposed.mediaMetadata)
            raw.emit(rawState("second", "new stream update"))
            Shadows.shadowOf(Looper.getMainLooper()).idle()
            assertSelected(exposed.currentMediaItem, "Second")
            val positions = mutableListOf<Player.PositionInfo>()
            exposed.addListener(object : Player.Listener {
                override fun onPositionDiscontinuity(oldPosition: Player.PositionInfo,
                    newPosition: Player.PositionInfo, reason: Int) {
                    positions.add(oldPosition)
                    positions.add(newPosition)
                }
            })
            exposed.play()
            exposed.pause()
            exposed.seekTo(4000L)
            exposed.stop()
            Shadows.shadowOf(Looper.getMainLooper()).idle()
            assertEquals(listOf("play", "pause", "seek:0:4000", "stop"), raw.commands)
            assertFalse(positions.isEmpty())
            for (position in positions) assertSelected(position.mediaItem, "Second")
        } finally { exposed.release() }
    }
}
