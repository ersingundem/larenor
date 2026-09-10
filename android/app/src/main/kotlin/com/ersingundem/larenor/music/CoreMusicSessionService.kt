package com.ersingundem.larenor.music

import android.app.PendingIntent
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.os.Process
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import androidx.media3.session.SessionCommands
import androidx.media3.session.SessionResult
import com.ersingundem.larenor.MainActivity
import com.ersingundem.larenor.audio.AudioControllerPolicy
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture

@UnstableApi
class CoreMusicSessionService : MediaSessionService(), CoreMusicSessionOwner {
    companion object {
        const val ACTION_PUBLISH = "com.ersingundem.larenor.CORE_MUSIC_PUBLISH"
        const val EXTRA_TICKET = "ticket"
    }

    private lateinit var player: CoreMusicRemotePlayer
    private var session: MediaSession? = null
    private var releasing = false
    private val handler = Handler(Looper.getMainLooper())

    override fun onCreate() {
        super.onCreate()
        setListener(object : MediaSessionService.Listener {
            override fun onForegroundServiceStartNotAllowedException() {
                handler.post { shutdown() }
            }
        })
        player = CoreMusicRemotePlayer(CoreMusicSessionRuntime::begin)
        val activity = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        session = MediaSession.Builder(this, player)
            .setSessionActivity(activity)
            .setCallback(object : MediaSession.Callback {
                override fun onConnectAsync(
                    session: MediaSession,
                    controller: MediaSession.ControllerInfo,
                ): ListenableFuture<MediaSession.ConnectionResult> {
                    if (!allowed(session, controller)) {
                        return Futures.immediateFuture(MediaSession.ConnectionResult.reject())
                    }
                    return Futures.immediateFuture(
                        MediaSession.ConnectionResult.AcceptedResultBuilder(session, controller)
                            .setAvailableSessionCommands(SessionCommands.EMPTY)
                            .setAvailablePlayerCommands(player.availableCommands)
                            .build(),
                    )
                }

                @Suppress("OVERRIDE_DEPRECATION")
                override fun onPlayerCommandRequest(
                    session: MediaSession,
                    controller: MediaSession.ControllerInfo,
                    playerCommand: Int,
                ): Int = if (allowed(session, controller) &&
                    CoreMusicSessionRuntime.snapshot?.controlsAuthorized == true &&
                    player.isCommandAvailable(playerCommand)
                ) SessionResult.RESULT_SUCCESS else SessionResult.RESULT_ERROR_PERMISSION_DENIED

                override fun onAddMediaItems(
                    session: MediaSession,
                    controller: MediaSession.ControllerInfo,
                    mediaItems: List<androidx.media3.common.MediaItem>,
                ): ListenableFuture<List<androidx.media3.common.MediaItem>> =
                    Futures.immediateFailedFuture(SecurityException("External selection unavailable"))
            }).build()
        addSession(session!!)
        CoreMusicSessionRuntime.attach(this)
    }

    private fun allowed(session: MediaSession, controller: MediaSession.ControllerInfo) =
        AudioControllerPolicy.mayConnect(
            controller.uid == Process.myUid(), controller.isTrusted,
            session.isMediaNotificationController(controller),
        )

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? {
        val value = session ?: return null
        return if (CoreMusicSessionRuntime.snapshot != null && allowed(value, controllerInfo)) {
            value
        } else null
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (releasing) return START_NOT_STICKY
        if (intent?.action == ACTION_PUBLISH) {
            val ticket = try { intent.getStringExtra(EXTRA_TICKET) } catch (_: Exception) { null }
            val value = CoreMusicSessionRuntime.consume(ticket, true)
            if (value == null) shutdown() else update(value)
        } else if (intent != null && CoreMusicSessionRuntime.snapshot != null) {
            try { super.onStartCommand(intent, flags, startId) } catch (_: Exception) { }
        } else shutdown()
        return START_NOT_STICKY
    }

    override fun update(snapshot: CoreMusicSessionSnapshot) { player.update(snapshot) }

    override fun shutdown() {
        if (releasing) return
        releasing = true
        handler.removeCallbacksAndMessages(null)
        player.clear()
        session?.let { removeSession(it); it.release() }
        session = null
        player.release()
        CoreMusicSessionRuntime.detach(this)
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        shutdown()
        super.onDestroy()
    }
}
