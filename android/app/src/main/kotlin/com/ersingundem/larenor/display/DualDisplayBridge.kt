package com.ersingundem.larenor.display

import android.app.Activity
import android.app.Presentation
import android.content.Context
import android.hardware.display.DisplayManager
import android.os.Bundle
import android.view.Display
import android.view.WindowManager
import io.flutter.FlutterInjector
import io.flutter.embedding.android.FlutterView
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

/**
 * Public, bounded Android display bridge.
 *
 * Only a route identifier and the closed public Core-health projection cross
 * this bridge. Account, home, session-family, media metadata, credentials and
 * rendered primary Flutter state remain in the primary engine.
 */
class DualDisplayBridge(
    activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler, DisplayManager.DisplayListener {
    private val channel = MethodChannel(messenger, CHANNEL)
    private val host = AndroidDualDisplayHost(activity)
    private val controller = DualDisplayController(host)
    private var disposed = false

    init {
        channel.setMethodCallHandler(this)
        host.listen(this)
    }

    fun setResumed(value: Boolean) {
        if (disposed) return
        host.refresh()
        controller.setResumed(value)
    }

    fun setWindowFocused(value: Boolean) {
        if (disposed) return
        host.refresh()
        controller.setFocused(value)
    }

    fun configurationChanged() {
        if (disposed) return
        topologyChanged()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (disposed) {
            result.error("unavailable", "Secondary display unavailable", null)
            return
        }
        try {
            when (call.method) {
                "snapshot" -> {
                    if (call.arguments != null) throw DualDisplayFailure("invalidRequest")
                    host.refresh()
                    result.success(controller.snapshot())
                }
                "present" -> {
                    // Display callbacks and method calls share the main looper,
                    // but a dock can change between Dart's snapshot and this
                    // request. Read the platform again at the send boundary.
                    host.refresh()
                    result.success(controller.present(call.arguments))
                }
                "dismiss" -> result.success(controller.dismiss(call.arguments))
                "publishPublicSnapshot" -> controller.publish(call.arguments) { accepted ->
                    if (!accepted) {
                        result.error("unavailable", "Secondary display unavailable", null)
                    } else {
                        val update = DualDisplayPublicUpdate.parse(call.arguments)
                        result.success(mapOf(
                            "sessionId" to update.sessionId,
                            "displayId" to update.displayId,
                            "snapshotRevision" to update.publicSnapshot.snapshotRevision,
                            "accepted" to true,
                        ))
                    }
                }
                else -> result.notImplemented()
            }
        } catch (failure: DualDisplayFailure) {
            result.error(failure.code, "Secondary display request rejected", null)
        } catch (_: RuntimeException) {
            result.error("unavailable", "Secondary display unavailable", null)
        }
    }

    override fun onDisplayAdded(displayId: Int) {
        topologyChanged()
    }
    override fun onDisplayChanged(displayId: Int) {
        topologyChanged()
    }
    override fun onDisplayRemoved(displayId: Int) {
        topologyChanged()
    }

    private fun topologyChanged() {
        if (disposed) return
        host.refresh()
        val snapshot = controller.snapshot()
        channel.invokeMethod(
            "topologyChanged",
            mapOf("revision" to snapshot["revision"]),
        )
    }

    fun dispose() {
        if (disposed) return
        disposed = true
        channel.setMethodCallHandler(null)
        host.stopListening(this)
        controller.dispose()
        host.dispose()
    }

    companion object {
        const val CHANNEL = "com.ersingundem.larenor/dual_display"
    }
}

internal class AndroidDualDisplayHost(
    private val activity: Activity,
    private val eligibleExternal: (Display) -> Boolean = {
        it.displayId in 1..63 && it.flags and Display.FLAG_PRESENTATION != 0
    },
) : DualDisplayHost {
    private val manager = activity.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
    private var revision = 1L
    private var surfaces = emptyList<DualDisplaySurface>()
    private var signatures = emptyMap<Int, DisplaySignature>()
    private val generations = mutableMapOf<Int, Long>()
    private var presentation: RoutePresentation? = null

    init {
        refresh()
    }

    fun listen(listener: DisplayManager.DisplayListener) = manager.registerDisplayListener(listener, null)
    fun stopListening(listener: DisplayManager.DisplayListener) = manager.unregisterDisplayListener(listener)

    @Synchronized
    fun refresh() {
        val displays = buildList {
            manager.getDisplay(Display.DEFAULT_DISPLAY)?.let(::add)
            manager.displays
                .asSequence()
                .filter(eligibleExternal)
                .sortedBy(Display::getDisplayId)
                .take(4)
                .forEach(::add)
        }
        if (displays.none { it.displayId == Display.DEFAULT_DISPLAY }) {
            throw DualDisplayFailure("displayUnavailable")
        }
        val nextSignatures = displays.associate { display ->
            display.displayId to DisplaySignature.read(display)
        }
        if (nextSignatures == signatures) return
        if (signatures.isNotEmpty()) revision = nextRevision(revision)
        nextSignatures.forEach { (id, signature) ->
            if (signatures[id] != signature) {
                generations[id] = nextRevision(generations[id] ?: 0)
            }
        }
        generations.keys.retainAll(nextSignatures.keys)
        signatures = nextSignatures
        surfaces = displays.map { display ->
            val signature = nextSignatures.getValue(display.displayId)
            DualDisplaySurface(
                displayId = display.displayId,
                generation = generations.getValue(display.displayId),
                primary = display.displayId == Display.DEFAULT_DISPLAY,
                widthPixels = signature.widthPixels,
                heightPixels = signature.heightPixels,
                densityDpi = signature.densityDpi,
                securePresentation = signature.secure,
            )
        }
        val active = presentation
        if (active != null && surfaces.none { it.displayId == active.display.displayId }) {
            presentation = null
            active.dismissSafely()
        }
    }

    @Synchronized
    override fun topology(): DualDisplayTopology {
        if (surfaces.isEmpty()) refresh()
        return DualDisplayTopology(revision, surfaces.toList())
    }

    @Synchronized
    override fun present(request: DualDisplayRequest): Boolean {
        if (presentation != null) return false
        val display = manager.getDisplay(request.displayId) ?: return false
        val surface = surfaces.singleOrNull { it.displayId == request.displayId } ?: return false
        if (surface.primary || surface.generation != request.displayGeneration) return false
        val candidate = RoutePresentation(
            activity, display, request.routeId, request.publicSnapshot, surface.securePresentation,
        )
        return try {
            candidate.show()
            if (!candidate.isShowing) {
                candidate.dismissSafely()
                false
            } else {
                presentation = candidate
                true
            }
        } catch (_: WindowManager.InvalidDisplayException) {
            candidate.dismissSafely()
            false
        } catch (_: RuntimeException) {
            candidate.dismissSafely()
            false
        }
    }

    @Synchronized
    override fun dismiss(displayId: Int) {
        val active = presentation ?: return
        if (active.display.displayId != displayId) return
        presentation = null
        active.dismissSafely()
    }

    @Synchronized
    override fun publish(update: DualDisplayPublicUpdate, completion: (Boolean) -> Unit) {
        val active = presentation
        if (active == null || active.display.displayId != update.displayId) {
            completion(false)
            return
        }
        active.publish(update.publicSnapshot, completion)
    }

    fun dispose() {
        val active = presentation
        presentation = null
        active?.dismissSafely()
    }

    private fun nextRevision(value: Long): Long = if (value >= Long.MAX_VALUE - 1) 1 else value + 1
}

private data class DisplaySignature(
    val widthPixels: Int,
    val heightPixels: Int,
    val densityDpi: Int,
    val secure: Boolean,
) {
    companion object {
        @Suppress("DEPRECATION")
        fun read(display: Display): DisplaySignature {
            val metrics = android.util.DisplayMetrics()
            display.getRealMetrics(metrics)
            return DisplaySignature(
                widthPixels = metrics.widthPixels,
                heightPixels = metrics.heightPixels,
                densityDpi = metrics.densityDpi,
                secure = display.flags and Display.FLAG_SECURE != 0,
            )
        }
    }
}

/** A plugin-free Flutter renderer that cannot inherit the primary session. */
private class RoutePresentation(
    context: Context,
    display: Display,
    private val routeId: String,
    private val initialSnapshot: PublicCoreStatusSnapshot,
    secure: Boolean,
) : Presentation(context, display) {
    private var engine: FlutterEngine? = null
    private var flutterView: FlutterView? = null

    init {
        window?.addFlags(WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE)
        if (secure) window?.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setOnDismissListener { releaseRenderer() }
        val loader = FlutterInjector.instance().flutterLoader()
        val isolatedEngine = FlutterEngine(context, null, false)
        val view = FlutterView(context)
        view.attachToFlutterEngine(isolatedEngine)
        engine = isolatedEngine
        flutterView = view
        setContentView(view)
        isolatedEngine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint(
                loader.findAppBundlePath(),
                "dualDisplayMain",
            ),
            listOf(routeId, JSONObject(initialSnapshot.projection()).toString()),
        )
    }

    override fun onStart() {
        super.onStart()
        engine?.lifecycleChannel?.appIsResumed()
        engine?.lifecycleChannel?.noWindowsAreFocused()
    }

    override fun onStop() {
        engine?.lifecycleChannel?.appIsPaused()
        super.onStop()
    }

    private fun releaseRenderer() {
        val ownedEngine = engine ?: return
        engine = null
        flutterView?.detachFromFlutterEngine()
        flutterView = null
        ownedEngine.lifecycleChannel.appIsDetached()
        ownedEngine.destroy()
    }

    fun publish(snapshot: PublicCoreStatusSnapshot, completion: (Boolean) -> Unit) {
        val ownedEngine = engine
        if (ownedEngine == null) {
            completion(false)
            return
        }
        MethodChannel(ownedEngine.dartExecutor.binaryMessenger, PUBLIC_CHANNEL).invokeMethod(
            "publicSnapshot",
            snapshot.projection(),
            object : MethodChannel.Result {
                override fun success(result: Any?) = completion(result == true)
                override fun error(code: String, message: String?, details: Any?) = completion(false)
                override fun notImplemented() = completion(false)
            },
        )
    }

    fun dismissSafely() {
        releaseRenderer()
        try {
            dismiss()
        } catch (_: RuntimeException) {
            // The display can disappear before Android delivers its callback.
        }
    }

    companion object {
        const val PUBLIC_CHANNEL = "com.ersingundem.larenor/dual_display_public"
    }
}
