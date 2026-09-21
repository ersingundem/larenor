package com.ersingundem.larenor.display

import android.app.Activity
import android.app.Presentation
import android.content.Context
import android.hardware.display.DisplayManager
import android.os.Bundle
import android.view.Display
import android.view.Gravity
import android.view.WindowManager
import android.widget.TextView
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Public, bounded Android display bridge.
 *
 * Only route identifiers cross this bridge. Account, home, session-family,
 * media metadata, credentials and rendered Flutter state remain in Dart.
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
        host.refresh()
        controller.snapshot()
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
                "present" -> result.success(controller.present(call.arguments))
                "dismiss" -> result.success(controller.dismiss(call.arguments))
                else -> result.notImplemented()
            }
        } catch (failure: DualDisplayFailure) {
            result.error(failure.code, "Secondary display request rejected", null)
        } catch (_: RuntimeException) {
            result.error("unavailable", "Secondary display unavailable", null)
        }
    }

    override fun onDisplayAdded(displayId: Int) {
        host.refresh()
        controller.snapshot()
    }
    override fun onDisplayChanged(displayId: Int) {
        host.refresh()
        controller.snapshot()
    }
    override fun onDisplayRemoved(displayId: Int) {
        host.refresh()
        controller.snapshot()
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

private class AndroidDualDisplayHost(private val activity: Activity) : DualDisplayHost {
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
            manager.getDisplays(DisplayManager.DISPLAY_CATEGORY_PRESENTATION)
                .asSequence()
                .filter { it.displayId in 1..63 }
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
        val candidate = RoutePresentation(activity, display, request.routeId, surface.securePresentation)
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
            val mode = display.mode
            return DisplaySignature(
                widthPixels = mode.physicalWidth,
                heightPixels = mode.physicalHeight,
                densityDpi = metrics.densityDpi,
                secure = display.flags and Display.FLAG_SECURE != 0,
            )
        }
    }
}

/** A secret-free placeholder until the isolated Flutter renderer is attached. */
private class RoutePresentation(
    context: Context,
    display: Display,
    private val routeId: String,
    secure: Boolean,
) : Presentation(context, display) {
    init {
        if (secure) window?.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(TextView(context).apply {
            gravity = Gravity.CENTER
            textSize = 24f
            text = when (routeId) {
                "dashboard.overview" -> "Larenor · Dashboard"
                "media.now-playing" -> "Larenor · Media"
                else -> "Larenor"
            }
        })
    }

    fun dismissSafely() {
        try {
            dismiss()
        } catch (_: RuntimeException) {
            // The display can disappear before Android delivers its callback.
        }
    }
}
