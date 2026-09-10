package com.ersingundem.larenor.music

import android.os.Looper
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.media3.common.SimpleBasePlayer
import androidx.media3.common.util.UnstableApi
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture

@UnstableApi
class CoreMusicRemotePlayer(
    private val dispatch: (String, Long?) -> Unit,
) : SimpleBasePlayer(Looper.getMainLooper()) {
    private var snapshot: CoreMusicSessionSnapshot? = null

    fun update(value: CoreMusicSessionSnapshot) {
        snapshot = value
        invalidateState()
    }

    fun clear() {
        snapshot = null
        invalidateState()
    }

    override fun getState(): State {
        val value = snapshot ?: return State.Builder()
            .setAvailableCommands(Player.Commands.Builder()
                .add(Player.COMMAND_RELEASE).build())
            .setPlaybackState(Player.STATE_IDLE).build()
        val commands = Player.Commands.Builder().addAll(
            Player.COMMAND_GET_CURRENT_MEDIA_ITEM,
            Player.COMMAND_GET_TIMELINE,
            Player.COMMAND_GET_METADATA,
            Player.COMMAND_RELEASE,
        )
        if (value.controlsAuthorized) {
            if (value.canPlay || value.canPause) commands.add(Player.COMMAND_PLAY_PAUSE)
            if (value.canSeek) commands.add(Player.COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM)
            if (value.canNext) commands.add(Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM)
            if (value.canPrevious) commands.add(Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM)
            if (value.canVolume) commands.add(Player.COMMAND_SET_VOLUME)
        }
        val metadata = MediaMetadata.Builder().setTitle(value.title).build()
        val item = MediaItem.Builder().setMediaId("core-music")
            .setMediaMetadata(metadata).build()
        val data = MediaItemData.Builder("core-music")
            .setMediaItem(item)
            .setMediaMetadata(metadata)
            .setDurationUs(value.durationMs?.times(1000) ?: 0L)
            .setIsSeekable(value.canSeek && value.durationMs != null)
            .build()
        return State.Builder()
            .setAvailableCommands(commands.build())
            .setPlaylist(listOf(data))
            .setPlaylistMetadata(MediaMetadata.EMPTY)
            .setCurrentMediaItemIndex(0)
            .setContentPositionMs(value.positionMs)
            .setPlaybackState(Player.STATE_READY)
            .setPlayWhenReady(
                value.isPlaying,
                Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST,
            )
            .setVolume((value.volumeLevel ?: 100) / 100f)
            .build()
    }

    override fun handleSetPlayWhenReady(playWhenReady: Boolean): ListenableFuture<*> =
        run(if (playWhenReady) "play" else "pause", null)

    override fun handleSeek(
        mediaItemIndex: Int,
        positionMs: Long,
        seekCommand: Int,
    ): ListenableFuture<*> {
        val action = when (seekCommand) {
            Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM,
            Player.COMMAND_SEEK_TO_NEXT -> "next"
            Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM,
            Player.COMMAND_SEEK_TO_PREVIOUS -> "previous"
            else -> "seek"
        }
        return run(action, if (action == "seek") positionMs else null)
    }

    override fun handleSetVolume(volume: Float): ListenableFuture<*> =
        run("volume", (volume.coerceIn(0f, 1f) * 100).toLong())

    override fun handleRelease(): ListenableFuture<*> {
        snapshot = null
        return Futures.immediateVoidFuture()
    }

    private fun run(action: String, value: Long?): ListenableFuture<*> = try {
        dispatch(action, value)
        Futures.immediateVoidFuture()
    } catch (_: CoreMusicSessionRejected) {
        Futures.immediateFailedFuture<Void>(SecurityException("Core music action unavailable"))
    }
}
