package com.ersingundem.larenor.music

import android.app.Activity
import android.content.Intent
import com.ersingundem.larenor.audio.LocalAudioRuntime
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class CoreMusicSessionBridge(
    private val activity: Activity,
    messenger: BinaryMessenger,
) {
    companion object {
        const val METHODS = "com.ersingundem.larenor/core_music_session"
        const val EVENTS = "com.ersingundem.larenor/core_music_session_actions"
    }

    private val methods = MethodChannel(messenger, METHODS)
    private val events = EventChannel(messenger, EVENTS)
    private var sink: EventChannel.EventSink? = null
    private var resumed = false
    private var disposed = false

    init {
        methods.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "publish" -> {
                        val snapshot = CoreMusicSessionSnapshot.parse(call.arguments)
                        if (LocalAudioRuntime.coordinator.hasOwner) {
                            throw CoreMusicSessionRejected("busy")
                        }
                        if (CoreMusicSessionRuntime.hasOwner) {
                            CoreMusicSessionRuntime.update(snapshot)
                        } else {
                            val ticket = CoreMusicSessionRuntime.stage(snapshot, foreground)
                            val intent = Intent(activity, CoreMusicSessionService::class.java)
                                .setAction(CoreMusicSessionService.ACTION_PUBLISH)
                                .putExtra(CoreMusicSessionService.EXTRA_TICKET, ticket)
                            if (activity.startService(intent) == null) {
                                CoreMusicSessionRuntime.failClosed()
                                throw CoreMusicSessionRejected("unavailable")
                            }
                        }
                        result.success(true)
                    }
                    "clear" -> {
                        val map = call.arguments as? Map<*, *>
                            ?: throw CoreMusicSessionRejected("invalidState")
                        if (map.keys != setOf("sessionId")) {
                            throw CoreMusicSessionRejected("invalidState")
                        }
                        val id = map["sessionId"] as? String
                            ?: throw CoreMusicSessionRejected("invalidState")
                        if (!Regex("[0-9a-f]{32}").matches(id)) {
                            throw CoreMusicSessionRejected("invalidState")
                        }
                        CoreMusicSessionRuntime.clear(id)
                        result.success(true)
                    }
                    else -> throw CoreMusicSessionRejected("unsupported")
                }
            } catch (error: CoreMusicSessionRejected) {
                result.error(error.code, "Core music session unavailable", null)
            } catch (_: Exception) {
                CoreMusicSessionRuntime.failClosed()
                result.error("unavailable", "Core music session unavailable", null)
            }
        }
        events.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink) {
                if (disposed || sink != null) {
                    eventSink.error("busy", "Core music session unavailable", null)
                    return
                }
                sink = eventSink
                CoreMusicSessionRuntime.setActionSink { action ->
                    sink?.success(action.toMap())
                        ?: throw CoreMusicSessionRejected("unavailable")
                }
            }

            override fun onCancel(arguments: Any?) {
                sink = null
                CoreMusicSessionRuntime.setActionSink(null)
            }
        })
    }

    private val foreground get() = resumed && !disposed && !activity.isFinishing

    fun setResumed(value: Boolean) { resumed = value }

    fun dispose() {
        disposed = true
        sink = null
        CoreMusicSessionRuntime.setActionSink(null)
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
    }
}
