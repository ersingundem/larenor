package com.ersingundem.larenor.audio

import android.app.PendingIntent
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.os.SystemClock
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.common.util.Log
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.upstream.DefaultLoadErrorHandlingPolicy
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import androidx.media3.session.SessionCommands
import androidx.media3.session.SessionResult
import com.ersingundem.larenor.MainActivity
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.Future

object LocalAudioRuntime {
    val coordinator = AudioCoordinator(SystemClock::elapsedRealtime)
    private val foregroundOwners = mutableSetOf<Any>()
    val activityForeground get() = foregroundOwners.isNotEmpty()
    fun setForeground(owner: Any, value: Boolean) {
        if (value) foregroundOwners.add(owner) else foregroundOwners.remove(owner)
    }
}

@UnstableApi
class LocalAudioService : MediaSessionService(), AudioOwner {
    companion object {
        const val ACTION_PLAY = "com.ersingundem.larenor.LOCAL_AUDIO_PLAY"
        const val EXTRA_TICKET = "ticket"
    }
    private lateinit var player: ExoPlayer
    private var session: MediaSession? = null
    private var source: AudioSource? = null
    private var releasing = false
    private var replacing = false
    private val handler = Handler(Looper.getMainLooper())
    private val coordinator get() = LocalAudioRuntime.coordinator
    private val transport = SafeAudioHttp.client()
    private var lastFailure: String? = null
    private val artwork = AudioArtworkState()
    private val artworkWorker = ThreadPoolExecutor(1, 1, 0, TimeUnit.MILLISECONDS, ArrayBlockingQueue<Runnable>(1))
    private var artworkJob: Future<*>? = null

    override fun onCreate() {
        super.onCreate()
        // Surface safe typed failures to Flutter; never print transport causes
        // (which may contain the user-chosen source URL) through Media3 logging.
        Log.setLogLevel(Log.LOG_LEVEL_OFF)
        val data = OkHttpDataSource.Factory(transport)
            .setContentTypePredicate { contentType ->
                contentType?.substringBefore(';')?.trim()?.lowercase() in AudioSource.mimeTypes
            }
        player = ExoPlayer.Builder(this)
            .setMediaSourceFactory(DefaultMediaSourceFactory(data)
                .setLoadErrorHandlingPolicy(DefaultLoadErrorHandlingPolicy(0)))
            .setAudioAttributes(AudioAttributes.Builder().setUsage(C.USAGE_MEDIA)
                .setContentType(C.AUDIO_CONTENT_TYPE_MUSIC).build(), true)
            .setHandleAudioBecomingNoisy(true)
            // Media3 holds these only while this real local player needs them.
            .setWakeMode(C.WAKE_MODE_NETWORK)
            .build()
        player.trackSelectionParameters = player.trackSelectionParameters.buildUpon()
            .setTrackTypeDisabled(C.TRACK_TYPE_VIDEO, true).build()
        setListener(object : MediaSessionService.Listener {
            override fun onForegroundServiceStartNotAllowedException() {
                handler.post {
                    if (!releasing) {
                        lastFailure = "foregroundRequired"
                        publish()
                        shutdown()
                    }
                }
            }
        })
        player.addListener(object : Player.Listener {
            override fun onEvents(player: Player, events: Player.Events) {
                if (!replacing && !releasing) {
                    publish()
                }
            }
            override fun onPlayerError(error: PlaybackException) {
                if (releasing) return
                lastFailure = when (error.errorCode) {
                    PlaybackException.ERROR_CODE_AUDIO_TRACK_INIT_FAILED,
                    PlaybackException.ERROR_CODE_AUDIO_TRACK_WRITE_FAILED -> "audioOutput"
                    PlaybackException.ERROR_CODE_DECODING_FAILED,
                    PlaybackException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED -> "unsupportedFormat"
                    else -> "network"
                }
                publish()
                shutdown()
            }
        })
        val exposedPlayer = object : SelectedAudioPlayer(player, {
            source?.let { current ->
                MediaItem.Builder().setMediaId(current.id)
                    .setMediaMetadata(selectedAudioMetadata(current, artwork.artwork)).build()
            }
        }) {
            override fun handleStop(): ListenableFuture<*> {
                coordinator.stop()
                return Futures.immediateVoidFuture()
            }
            override fun handleSetPlayWhenReady(value: Boolean): ListenableFuture<*> {
                if (source != null && !releasing) {
                    if (value) this@LocalAudioService.resume() else this@LocalAudioService.pause()
                }
                return Futures.immediateVoidFuture()
            }
        }
        val activity = PendingIntent.getActivity(this, 0,
            Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        session = MediaSession.Builder(this, exposedPlayer)
            .setSessionActivity(activity)
            .setBitmapLoader(SelectedAudioBitmapLoader(artwork))
            .setCallback(object : MediaSession.Callback {
                override fun onConnectAsync(session: MediaSession, controller: MediaSession.ControllerInfo): ListenableFuture<MediaSession.ConnectionResult> {
                    if (!allowed(session, controller)) return Futures.immediateFuture(MediaSession.ConnectionResult.reject())
                    val commands = Player.Commands.Builder().addAll(
                        Player.COMMAND_PLAY_PAUSE, Player.COMMAND_STOP,
                        Player.COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM, Player.COMMAND_GET_CURRENT_MEDIA_ITEM,
                        Player.COMMAND_GET_TIMELINE, Player.COMMAND_GET_METADATA,
                    ).build()
                    return Futures.immediateFuture(MediaSession.ConnectionResult.AcceptedResultBuilder(session, controller)
                        .setAvailableSessionCommands(SessionCommands.EMPTY)
                        .setAvailablePlayerCommands(commands).build())
                }
                @Suppress("OVERRIDE_DEPRECATION")
                override fun onPlayerCommandRequest(session: MediaSession, controller: MediaSession.ControllerInfo, playerCommand: Int): Int {
                    if (!allowed(session, controller) || source == null || releasing) return SessionResult.RESULT_ERROR_PERMISSION_DENIED
                    return SessionResult.RESULT_SUCCESS
                }
                override fun onAddMediaItems(session: MediaSession, controller: MediaSession.ControllerInfo, mediaItems: List<MediaItem>): ListenableFuture<List<MediaItem>> =
                    Futures.immediateFailedFuture(SecurityException("External media selection unavailable"))
            }).build()
        addSession(session!!)
        coordinator.attach(this)
    }

    private fun allowed(session: MediaSession, controller: MediaSession.ControllerInfo) =
        AudioControllerPolicy.mayConnect(controller.uid == Process.myUid(), controller.isTrusted,
            session.isMediaNotificationController(controller))

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? {
        val current = session ?: return null
        if (source == null && !coordinator.hasPending) { stopSelf(); return null }
        return if (allowed(current, controllerInfo)) current else null
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (releasing) { coordinator.cancelPending(); return START_NOT_STICKY }
        if (intent?.action == ACTION_PLAY) {
            val ticket = try { intent.getStringExtra(EXTRA_TICKET) } catch (_: Exception) { null }
            val next = coordinator.consume(ticket, LocalAudioRuntime.activityForeground)
            if (next != null) {
                replacing = true
                source = next
                artworkJob?.cancel(true)
                artworkWorker.purge()
                val artworkTicket = artwork.begin(next.id, next.artworkBytes != null)
                lastFailure = null
                player.stop()
                player.clearMediaItems()
                val metadata = selectedAudioMetadata(next, null)
                player.setMediaItem(MediaItem.Builder().setMediaId(next.id).setUri(next.uri.toString())
                    .setMimeType(next.mimeType).setMediaMetadata(metadata).build())
                player.prepare()
                player.play()
                replacing = false
                publish()
                next.artworkBytes?.let { bytes ->
                    artworkJob = artworkWorker.submit {
                        val prepared = try { AudioArtwork.prepare(bytes) } catch (_: Exception) { null }
                        handler.post {
                            if (!releasing && source === next && artwork.complete(artworkTicket, prepared)) {
                                val current = player.currentMediaItem
                                if (current != null && current.mediaId == next.id) {
                                    val updated = selectedAudioMetadata(next, prepared)
                                    player.replaceMediaItem(player.currentMediaItemIndex,
                                        current.buildUpon().setMediaMetadata(updated).build())
                                }
                                publish()
                            }
                        }
                    }
                }
            } else if (source == null) shutdown()
        } else if (intent != null && source != null) {
            // The service is exported for real media controllers; malformed
            // foreign parcelables must not crash an existing playback owner.
            try { super.onStartCommand(intent, flags, startId) } catch (_: Exception) { /* Ignore invalid intent. */ }
        } else if (source == null) shutdown()
        // A killed process has no source/ticket and must not restart playback.
        return START_NOT_STICKY
    }

    override fun snapshot(): AudioSnapshot {
        val current = source ?: return AudioSnapshot()
        val duration = player.duration.takeIf { it != C.TIME_UNSET && it in 1..2_592_000_000L }
        val phase = when {
            lastFailure != null -> "error"
            player.playbackState == Player.STATE_BUFFERING -> "loading"
            player.playbackState == Player.STATE_ENDED -> "ended"
            player.playbackState == Player.STATE_READY -> "ready"
            else -> "loading"
        }
        val usable = !releasing && lastFailure == null && player.playbackState != Player.STATE_IDLE
        return AudioSnapshot(phase = phase, sourceId = current.id, title = current.title,
            artist = current.artist, album = current.album, isPlaying = usable && player.isPlaying,
            positionMs = player.currentPosition.takeIf { it >= 0 }, durationMs = duration,
            canPlay = usable && (!player.playWhenReady || player.playbackState == Player.STATE_ENDED),
            canPause = usable && player.playWhenReady && player.playbackState != Player.STATE_ENDED,
            canSeek = usable && duration != null && player.isCurrentMediaItemSeekable,
            canStop = !releasing, failure = lastFailure,
            artworkState = if (lastFailure == null) artwork.phase else "none",
            artworkId = if (lastFailure == null) artwork.artworkId else null)
    }

    override fun artwork(sourceId: String, artworkId: String) = artwork.read(sourceId, artworkId)
    private fun publish() { coordinator.report(this, snapshot()) }
    override fun pause() { player.pause(); publish() }
    override fun resume() {
        if (player.playbackState == Player.STATE_ENDED) player.seekTo(0)
        player.play(); publish()
    }
    override fun seek(positionMs: Long) { player.seekTo(positionMs); publish() }
    override fun shutdown() {
        if (releasing) return
        releasing = true
        handler.removeCallbacksAndMessages(null)
        artwork.clear()
        artworkJob?.cancel(true)
        artworkWorker.shutdownNow()
        player.stop()
        player.clearMediaItems()
        session?.let { removeSession(it); it.release() }
        session = null
        player.release()
        transport.dispatcher.cancelAll()
        transport.connectionPool.evictAll()
        coordinator.detach(this)
        source = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }
    override fun onTaskRemoved(rootIntent: Intent?) {
        if (!isPlaybackOngoing) coordinator.stop()
    }
    override fun onDestroy() { shutdown(); super.onDestroy() }
}
