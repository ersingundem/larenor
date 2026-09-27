package com.ersingundem.larenor.camera

import android.Manifest
import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.PowerManager
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.CameraState
import androidx.camera.core.Preview
import androidx.camera.core.SurfaceRequest
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.util.UUID
import java.util.concurrent.Executor

/**
 * Owns one foreground-only front-camera preview.
 *
 * CameraX receives only a preview surface. There is deliberately no image
 * analysis, image capture, recorder, file, log, or network output.
 */
class PersonalCameraBridge(
    private val activity: Activity,
    messenger: BinaryMessenger,
    private val textures: TextureRegistry,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    companion object {
        const val METHODS = "com.ersingundem.larenor/personal_camera"
        const val EVENTS = "com.ersingundem.larenor/personal_camera_events"
        const val REQUEST_CAMERA = 41055
        private const val SCHEMA_VERSION = 1
        private const val WIDTH = 1280
        private const val HEIGHT = 720
        private const val DETECTOR_ARTIFACT = "com.google.mlkit:face-detection"
        private const val DETECTOR_VERSION = "16.1.7"
        private const val TERMS_URL = "https://developers.google.com/ml-kit/terms"
    }

    private data class Session(
        val id: String,
        val producer: TextureRegistry.SurfaceProducer,
        val preview: Preview,
        val camera: Camera,
    )

    private val methods = MethodChannel(messenger, METHODS)
    private val events = EventChannel(messenger, EVENTS)
    private val main: Executor = ContextCompat.getMainExecutor(activity)
    private val power = activity.getSystemService(Context.POWER_SERVICE) as PowerManager
    private var sink: EventChannel.EventSink? = null
    private var provider: ProcessCameraProvider? = null
    private var session: Session? = null
    private var pendingPermission: MethodChannel.Result? = null
    private var resumed = false
    private var focused = false
    private var disposed = false
    private var batteryReceiverRegistered = false
    private var thermalListener: PowerManager.OnThermalStatusChangedListener? = null

    private val batteryReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == Intent.ACTION_BATTERY_CHANGED && batteryCritical(intent)) {
                retire("batteryCritical")
            }
        }
    }

    init {
        methods.setMethodCallHandler(this)
        events.setStreamHandler(this)
    }

    fun setResumed(value: Boolean) {
        resumed = value
        if (!value) {
            cancelPermission("background")
            retire("background")
        }
    }

    fun setWindowFocused(value: Boolean) {
        focused = value
        if (!value && pendingPermission == null) retire("focusLost")
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (disposed) return fail(result, "unavailable")
        try {
            when (call.method) {
                "capabilities" -> capabilities(exact(call.arguments, setOf("schemaVersion")), result)
                "open" -> open(exact(call.arguments, setOf("schemaVersion")), result)
                "close" -> close(exact(call.arguments, setOf("schemaVersion", "sessionId")), result)
                else -> result.notImplemented()
            }
        } catch (_: IllegalArgumentException) {
            fail(result, "invalid")
        } catch (_: RuntimeException) {
            fail(result, "unavailable")
        }
    }

    private fun capabilities(arguments: Map<String, Any?>, result: MethodChannel.Result) {
        require(arguments["schemaVersion"] == SCHEMA_VERSION)
        val frontCamera = activity.packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_FRONT)
        result.success(
            mapOf(
                "schemaVersion" to SCHEMA_VERSION,
                "platform" to "android",
                "osApiLevel" to Build.VERSION.SDK_INT,
                "frontCamera" to frontCamera,
                "preview" to frontCamera,
                "detectorArtifact" to DETECTOR_ARTIFACT,
                "detectorVersion" to DETECTOR_VERSION,
                "detectorDelivery" to "bundled",
                "requiresGooglePlayServices" to false,
                "faceDetection" to true,
                "identityRecognition" to false,
                "termsUrl" to TERMS_URL,
                "performanceEvaluation" to "pending",
            ),
        )
    }

    private fun open(arguments: Map<String, Any?>, result: MethodChannel.Result) {
        require(arguments["schemaVersion"] == SCHEMA_VERSION)
        if (!interactive() || session != null || pendingPermission != null) {
            return fail(result, if (session == null) "background" else "cameraBusy")
        }
        powerFailure()?.let { return fail(result, it) }
        if (activity.checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            pendingPermission = result
            activity.requestPermissions(arrayOf(Manifest.permission.CAMERA), REQUEST_CAMERA)
            return
        }
        bind(result)
    }

    private fun bind(result: MethodChannel.Result) {
        if (!interactive()) return fail(result, "background")
        powerFailure()?.let { return fail(result, it) }
        val future = ProcessCameraProvider.getInstance(activity)
        future.addListener({
            if (disposed || !interactive()) return@addListener fail(result, "background")
            try {
                val cameraProvider = future.get()
                provider = cameraProvider
                if (!cameraProvider.hasCamera(CameraSelector.DEFAULT_FRONT_CAMERA)) {
                    return@addListener fail(result, "noFrontCamera")
                }
                if (session != null) return@addListener fail(result, "cameraBusy")
                val producer = textures.createSurfaceProducer().apply {
                    setSize(WIDTH, HEIGHT)
                }
                val preview = Preview.Builder().build()
                preview.setSurfaceProvider { request -> provideSurface(request, producer) }
                val camera = cameraProvider.bindToLifecycle(
                    activity as LifecycleOwner,
                    CameraSelector.DEFAULT_FRONT_CAMERA,
                    preview,
                )
                val value = Session(UUID.randomUUID().toString(), producer, preview, camera)
                session = value
                observeCamera(value)
                startPowerObservers()
                result.success(
                    mapOf(
                        "schemaVersion" to SCHEMA_VERSION,
                        "sessionId" to value.id,
                        "textureId" to producer.id(),
                        "width" to WIDTH,
                        "height" to HEIGHT,
                    ),
                )
            } catch (_: SecurityException) {
                fail(result, "permissionDenied")
            } catch (_: IllegalArgumentException) {
                fail(result, "noFrontCamera")
            } catch (_: IllegalStateException) {
                fail(result, "cameraBusy")
            } catch (_: RuntimeException) {
                fail(result, "unavailable")
            }
        }, main)
    }

    private fun provideSurface(
        request: SurfaceRequest,
        producer: TextureRegistry.SurfaceProducer,
    ) {
        producer.setSize(request.resolution.width, request.resolution.height)
        val surface = producer.surface
        request.provideSurface(surface, main) { surface.release() }
    }

    private fun observeCamera(owner: Session) {
        owner.camera.cameraInfo.cameraState.observe(activity as LifecycleOwner) { state ->
            if (session?.id != owner.id) return@observe
            val reason = when (state.error?.code) {
                CameraState.ERROR_CAMERA_IN_USE,
                CameraState.ERROR_MAX_CAMERAS_IN_USE -> "cameraBusy"
                CameraState.ERROR_CAMERA_DISABLED -> "permissionDenied"
                CameraState.ERROR_STREAM_CONFIG,
                CameraState.ERROR_OTHER_RECOVERABLE_ERROR,
                CameraState.ERROR_DO_NOT_DISTURB_MODE_ENABLED,
                CameraState.ERROR_CAMERA_FATAL_ERROR,
                CameraState.ERROR_CAMERA_REMOVED -> "unavailable"
                null -> null
                else -> "unavailable"
            }
            if (reason != null) retire(reason)
        }
    }

    private fun close(arguments: Map<String, Any?>, result: MethodChannel.Result) {
        require(arguments["schemaVersion"] == SCHEMA_VERSION)
        val id = arguments["sessionId"] as? String ?: throw IllegalArgumentException()
        val current = session
        if (current == null || current.id != id) return fail(result, "expired")
        release(current)
        result.success(mapOf("schemaVersion" to SCHEMA_VERSION, "sessionId" to id, "closed" to true))
    }

    private fun retire(reason: String) {
        val current = session ?: return
        release(current)
        sink?.success(
            mapOf(
                "schemaVersion" to SCHEMA_VERSION,
                "sessionId" to current.id,
                "state" to "closed",
                "reason" to reason,
            ),
        )
    }

    private fun release(current: Session) {
        if (session?.id != current.id) return
        session = null
        current.camera.cameraInfo.cameraState.removeObservers(activity as LifecycleOwner)
        try {
            provider?.unbind(current.preview)
        } catch (_: RuntimeException) {
            // The texture is still retired below; no old session can be reused.
        }
        current.producer.release()
        stopPowerObservers()
    }

    private fun interactive(): Boolean = resumed && focused &&
        !disposed && !activity.isFinishing && !activity.isDestroyed

    private fun powerFailure(): String? {
        if (Build.VERSION.SDK_INT >= 29 && power.currentThermalStatus >= PowerManager.THERMAL_STATUS_SEVERE) {
            return "thermalCritical"
        }
        val battery = activity.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        return if (battery != null && batteryCritical(battery)) "batteryCritical" else null
    }

    private fun batteryCritical(intent: Intent): Boolean {
        val level = intent.getIntExtra("level", -1)
        val scale = intent.getIntExtra("scale", -1)
        val plugged = intent.getIntExtra("plugged", 0)
        if (level < 0 || scale <= 0) return true
        return level * 100 / scale <= 10 && plugged == 0
    }

    private fun startPowerObservers() {
        if (!batteryReceiverRegistered) {
            activity.registerReceiver(batteryReceiver, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            batteryReceiverRegistered = true
        }
        if (Build.VERSION.SDK_INT >= 29 && thermalListener == null) {
            val listener = PowerManager.OnThermalStatusChangedListener { status ->
                if (status >= PowerManager.THERMAL_STATUS_SEVERE) retire("thermalCritical")
            }
            thermalListener = listener
            power.addThermalStatusListener(main, listener)
        }
    }

    private fun stopPowerObservers() {
        if (batteryReceiverRegistered) {
            try {
                activity.unregisterReceiver(batteryReceiver)
            } catch (_: IllegalArgumentException) {
                // Already retired by Android.
            }
            batteryReceiverRegistered = false
        }
        if (Build.VERSION.SDK_INT >= 29) {
            thermalListener?.let { power.removeThermalStatusListener(it) }
        }
        thermalListener = null
    }

    fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != REQUEST_CAMERA) return false
        val result = pendingPermission ?: return true
        pendingPermission = null
        val granted = permissions.size == 1 &&
            permissions[0] == Manifest.permission.CAMERA &&
            grantResults.size == 1 && grantResults[0] == PackageManager.PERMISSION_GRANTED
        if (!granted) {
            fail(result, "permissionDenied")
        } else {
            // The permission callback may arrive one frame before Android
            // restores this window's focus. Wait for that ownership signal;
            // never bind while the system sheet still owns the window.
            activity.window.decorView.postDelayed({
                focused = activity.window.decorView.hasWindowFocus()
                if (interactive()) bind(result) else fail(result, "background")
            }, 150)
        }
        return true
    }

    private fun cancelPermission(code: String) {
        pendingPermission?.let { fail(it, code) }
        pendingPermission = null
    }

    override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink?) {
        if (arguments != null || sink != null) {
            eventSink?.error("invalid", "Personal camera events unavailable", null)
        } else {
            sink = eventSink
        }
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    fun dispose() {
        if (disposed) return
        disposed = true
        cancelPermission("unavailable")
        session?.let(::release)
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        sink = null
    }

    private fun exact(raw: Any?, keys: Set<String>): Map<String, Any?> {
        val map = raw as? Map<*, *> ?: throw IllegalArgumentException()
        if (map.keys.any { it !is String } || map.keys.toSet() != keys) throw IllegalArgumentException()
        @Suppress("UNCHECKED_CAST")
        return map as Map<String, Any?>
    }

    private fun fail(result: MethodChannel.Result, code: String) {
        result.error(code, "Personal camera unavailable", null)
    }
}
