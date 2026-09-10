package com.ersingundem.larenor.cast

import android.app.Activity
import android.os.Handler
import android.os.Looper
import androidx.mediarouter.media.MediaRouter
import com.google.android.gms.cast.CastDevice
import com.google.android.gms.cast.framework.CastContext
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.UUID
import kotlin.math.roundToInt

/** Bounded, read-only Google Cast discovery for exact Core target matching. */
class CoreCastRouteBridge(
    private val activity: Activity,
    messenger: BinaryMessenger,
) {
    companion object {
        const val METHODS = "com.ersingundem.larenor/core_cast_routes"
        const val EVENTS = "com.ersingundem.larenor/core_cast_route_events"
        private const val DISCOVERY_MS = 15_000L
    }

    private val methods = MethodChannel(messenger, METHODS)
    private val events = EventChannel(messenger, EVENTS)
    private val router = MediaRouter.getInstance(activity)
    private val handler = Handler(Looper.getMainLooper())
    private val gate = CoreCastRouteGate()
    private var sink: EventChannel.EventSink? = null
    private var selector: androidx.mediarouter.media.MediaRouteSelector? = null
    private var resumed = false
    private var active = false
    private var disposed = false
    private var revision = 0L

    private val callback = object : MediaRouter.Callback() {
        override fun onRouteAdded(router: MediaRouter, route: MediaRouter.RouteInfo) = publish()
        override fun onRouteRemoved(router: MediaRouter, route: MediaRouter.RouteInfo) = publish()
        override fun onRouteChanged(router: MediaRouter, route: MediaRouter.RouteInfo) = publish()
        override fun onRouteVolumeChanged(router: MediaRouter, route: MediaRouter.RouteInfo) = publish()
        override fun onRouteSelected(router: MediaRouter, route: MediaRouter.RouteInfo, reason: Int) = publish()
        override fun onRouteUnselected(router: MediaRouter, route: MediaRouter.RouteInfo, reason: Int) = publish()
    }

    init {
        methods.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "start" -> {
                        start()
                        result.success(true)
                    }
                    "stop" -> {
                        stop(publishEmpty = true)
                        result.success(true)
                    }
                    else -> throw CoreCastRouteRejected("unsupported")
                }
            } catch (error: CoreCastRouteRejected) {
                stop(publishEmpty = false)
                result.error(error.code, "Google Cast discovery unavailable", null)
            } catch (_: Exception) {
                stop(publishEmpty = false)
                result.error("unavailable", "Google Cast discovery unavailable", null)
            }
        }
        events.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink) {
                if (disposed || sink != null) {
                    eventSink.error("busy", "Google Cast discovery unavailable", null)
                    return
                }
                sink = eventSink
            }

            override fun onCancel(arguments: Any?) {
                sink = null
                stop(publishEmpty = false)
            }
        })
    }

    fun setResumed(value: Boolean) {
        resumed = value
        if (!value) stop(publishEmpty = true)
    }

    private fun start() {
        if (disposed || !resumed || sink == null) throw CoreCastRouteRejected("foregroundRequired")
        if (active) return
        val castContext = try {
            CastContext.getSharedInstance(activity.applicationContext)
        } catch (_: Exception) {
            throw CoreCastRouteRejected("unavailable")
        }
        selector = castContext.mergedSelector
        val selected = selector ?: throw CoreCastRouteRejected("unavailable")
        active = true
        router.addCallback(selected, callback, MediaRouter.CALLBACK_FLAG_REQUEST_DISCOVERY)
        handler.removeCallbacksAndMessages(null)
        handler.postDelayed({ stop(publishEmpty = true) }, DISCOVERY_MS)
        publish()
    }

    private fun publish() {
        if (!active || disposed) return
        val selected = selector ?: return
        val routes = mutableMapOf<String, CoreCastRoute>()
        for (route in router.routes) {
            if (!route.matchesSelector(selected) || route.isDefaultOrBluetooth) continue
            val device = try { CastDevice.getFromBundle(route.extras) } catch (_: Exception) { null }
                ?: continue
            val id = try { UUID.fromString(device.deviceId).toString() } catch (_: Exception) { continue }
            val name = device.friendlyName?.toString()?.trim().orEmpty()
            val volume = if (route.volumeHandling == MediaRouter.RouteInfo.PLAYBACK_VOLUME_VARIABLE &&
                route.volumeMax > 0) {
                ((route.volume.toDouble() / route.volumeMax) * 100).roundToInt().coerceIn(0, 100)
            } else null
            val state = when (route.connectionState) {
                MediaRouter.RouteInfo.CONNECTION_STATE_CONNECTING -> "connecting"
                MediaRouter.RouteInfo.CONNECTION_STATE_CONNECTED -> "connected"
                else -> "disconnected"
            }
            val value = CoreCastRoute.parse(mapOf(
                "id" to id,
                "name" to name,
                "kind" to if (device.hasCapability(CastDevice.CAPABILITY_MULTIZONE_GROUP)) "group" else "device",
                "available" to route.isEnabled,
                "connectionState" to state,
                "volumeLevel" to volume,
            ))
            val previous = routes.put(id, value)
            if (previous != null && previous != value) {
                fail("ambiguous")
                return
            }
        }
        val snapshot = CoreCastRouteSnapshot(++revision, routes.values.sortedBy(CoreCastRoute::id))
        try {
            gate.publish(snapshot)
            sink?.success(snapshot.toMap()) ?: throw CoreCastRouteRejected("unavailable")
        } catch (_: Exception) {
            fail("unavailable")
        }
    }

    private fun fail(code: String) {
        val currentSink = sink
        stop(publishEmpty = false)
        currentSink?.error(code, "Google Cast discovery unavailable", null)
    }

    private fun stop(publishEmpty: Boolean) {
        handler.removeCallbacksAndMessages(null)
        if (!active) return
        active = false
        router.removeCallback(callback)
        selector = null
        gate.clear()
        if (publishEmpty && sink != null && !disposed) {
            val snapshot = CoreCastRouteSnapshot(++revision, emptyList())
            gate.publish(snapshot)
            sink?.success(snapshot.toMap())
        }
    }

    fun dispose() {
        disposed = true
        stop(publishEmpty = false)
        sink = null
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
    }
}
