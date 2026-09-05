package com.ersingundem.larenor.audio

import androidx.media3.common.ForwardingSimpleBasePlayer
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Metadata
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.Tracks
import androidx.media3.common.util.UnstableApi

/**
 * The session sees one projection of the user's selected metadata, including
 * listener arguments, timeline windows and position-discontinuity media items.
 * Getter-only ForwardingPlayer overrides do not filter Media3's event payloads.
 * SimpleBasePlayer derives those callbacks (and onEvents) from this same State.
 *
 * Playback still uses the original player's URI. No URI, request extras,
 * manifest, embedded format metadata or timed tags enter the session playlist.
 */
@UnstableApi
internal open class SelectedAudioPlayer(
    player: Player,
    private val selectedItem: () -> MediaItem?,
) : ForwardingSimpleBasePlayer(player) {
    private var originalError: PlaybackException? = null
    private var exposedError: PlaybackException? = null

    override fun getState(): State {
        val state = super.getState()
        if (state.playerError !== originalError) {
            originalError = state.playerError
            exposedError = state.playerError?.let {
                PlaybackException("Audio playback unavailable", null, it.errorCode)
            }
        }
        val selected = selectedItem()
        val playlist = state.playlist.map { item ->
            // A source replacement can occur before the old timeline is
            // cleared. Never label the previous item as the newly selected one.
            val safeItem = selected?.takeIf { it.mediaId == item.mediaItem.mediaId }
                ?: MediaItem.EMPTY
            item.buildUpon()
                .setMediaItem(safeItem)
                .setMediaMetadata(safeItem.mediaMetadata)
                .setManifest(null)
                .setTracks(Tracks.EMPTY)
                .build()
        }
        return state.buildUpon()
            .setPlaylist(playlist)
            .setPlaylistMetadata(MediaMetadata.EMPTY)
            .setTimedMetadata(Metadata())
            .setPlayerError(exposedError)
            .build()
    }
}
