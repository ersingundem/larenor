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
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
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
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.face.Face
import com.google.mlkit.vision.face.FaceDetection
import com.google.mlkit.vision.face.FaceDetectorOptions
import java.util.UUID
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.sqrt

/**
 * Owns one foreground-only front-camera preview.
 *
 * CameraX receives only a preview surface until the user explicitly enrolls
 * or checks a local personalization profile. Temporary analysis frames are
 * closed immediately; there is no image capture, recorder, file, log, or
 * network output.
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
        private const val ENROLLMENT_SAMPLES = 8
        private const val ENROLLMENT_TIMEOUT_MS = 20_000L
        private const val MATCH_SAMPLES = 5
        private const val MATCH_TIMEOUT_MS = 15_000L
        private const val MATCH_RMS_LIMIT = 0.055
        private const val MATCH_COMPONENT_LIMIT = 0.15
    }

    private data class Session(
        val id: String,
        val producer: TextureRegistry.SurfaceProducer,
        val preview: Preview,
        val camera: Camera,
    )

    private data class Enrollment(
        val sessionId: String,
        val result: MethodChannel.Result,
        val samples: MutableList<List<Double>> = mutableListOf(),
        var analysis: ImageAnalysis? = null,
        var timeout: Runnable? = null,
    )

    private data class Matching(
        val sessionId: String,
        val profile: PersonalFaceProfile,
        val result: MethodChannel.Result,
        val samples: MutableList<List<Double>> = mutableListOf(),
        var analysis: ImageAnalysis? = null,
        var timeout: Runnable? = null,
    )

    private val methods = MethodChannel(messenger, METHODS)
    private val events = EventChannel(messenger, EVENTS)
    private val main: Executor = ContextCompat.getMainExecutor(activity)
    private val power = activity.getSystemService(Context.POWER_SERVICE) as PowerManager
    private val profiles = PersonalFaceProfileStore(activity)
    private val analysisExecutor = Executors.newSingleThreadExecutor()
    private val analysisBusy = AtomicBoolean(false)
    private val detector = FaceDetection.getClient(
        FaceDetectorOptions.Builder()
            .setPerformanceMode(FaceDetectorOptions.PERFORMANCE_MODE_ACCURATE)
            .setLandmarkMode(FaceDetectorOptions.LANDMARK_MODE_ALL)
            .setMinFaceSize(0.25f)
            .build(),
    )
    private var sink: EventChannel.EventSink? = null
    private var provider: ProcessCameraProvider? = null
    private var session: Session? = null
    private var pendingPermission: MethodChannel.Result? = null
    private var enrollment: Enrollment? = null
    private var matching: Matching? = null
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
                "profile" -> profile(exact(call.arguments, setOf("schemaVersion")), result)
                "enroll" -> enroll(exact(call.arguments, setOf("schemaVersion", "sessionId")), result)
                "match" -> match(exact(call.arguments, setOf("schemaVersion", "sessionId")), result)
                "deleteProfile" -> deleteProfile(
                    exact(call.arguments, setOf("schemaVersion", "profileId")),
                    result,
                )
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

    private fun profile(arguments: Map<String, Any?>, result: MethodChannel.Result) {
        require(arguments["schemaVersion"] == SCHEMA_VERSION)
        val value = profiles.load()
        result.success(value?.let(::profileMap) ?: mapOf("schemaVersion" to SCHEMA_VERSION, "exists" to false))
    }

    private fun enroll(arguments: Map<String, Any?>, result: MethodChannel.Result) {
        require(arguments["schemaVersion"] == SCHEMA_VERSION)
        val sessionId = arguments["sessionId"] as? String ?: throw IllegalArgumentException()
        val current = session
        if (current == null || current.id != sessionId || !interactive()) return fail(result, "expired")
        if (profiles.load() != null) return fail(result, "profileExists")
        if (enrollment != null || matching != null) return fail(result, "cameraBusy")
        powerFailure()?.let { return fail(result, it) }
        try {
            val value = Enrollment(sessionId, result)
            val analysis = ImageAnalysis.Builder()
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .build()
            value.analysis = analysis
            enrollment = value
            analysis.setAnalyzer(analysisExecutor, ::analyzeEnrollmentFrame)
            provider?.bindToLifecycle(
                activity as LifecycleOwner,
                CameraSelector.DEFAULT_FRONT_CAMERA,
                analysis,
            ) ?: throw IllegalStateException("camera_provider_missing")
            val timeout = Runnable {
                if (enrollment === value) stopEnrollment("enrollmentTimeout")
            }
            value.timeout = timeout
            activity.window.decorView.postDelayed(timeout, ENROLLMENT_TIMEOUT_MS)
        } catch (_: RuntimeException) {
            if (enrollment == null) fail(result, "unavailable") else stopEnrollment("unavailable")
        }
    }

    private fun match(arguments: Map<String, Any?>, result: MethodChannel.Result) {
        require(arguments["schemaVersion"] == SCHEMA_VERSION)
        val sessionId = arguments["sessionId"] as? String ?: throw IllegalArgumentException()
        val current = session
        if (current == null || current.id != sessionId || !interactive()) return fail(result, "expired")
        val profile = profiles.load() ?: return fail(result, "profileMissing")
        if (enrollment != null || matching != null) return fail(result, "cameraBusy")
        powerFailure()?.let { return fail(result, it) }
        try {
            val value = Matching(sessionId, profile, result)
            val analysis = ImageAnalysis.Builder()
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .build()
            value.analysis = analysis
            matching = value
            analysis.setAnalyzer(analysisExecutor, ::analyzeMatchFrame)
            provider?.bindToLifecycle(
                activity as LifecycleOwner,
                CameraSelector.DEFAULT_FRONT_CAMERA,
                analysis,
            ) ?: throw IllegalStateException("camera_provider_missing")
            val timeout = Runnable {
                if (matching === value) stopMatching("matchTimeout")
            }
            value.timeout = timeout
            activity.window.decorView.postDelayed(timeout, MATCH_TIMEOUT_MS)
        } catch (_: RuntimeException) {
            if (matching == null) fail(result, "unavailable") else stopMatching("unavailable")
        }
    }

    private fun deleteProfile(arguments: Map<String, Any?>, result: MethodChannel.Result) {
        require(arguments["schemaVersion"] == SCHEMA_VERSION)
        val profileId = arguments["profileId"] as? String ?: throw IllegalArgumentException()
        if (enrollment != null || matching != null) return fail(result, "cameraBusy")
        if (!profiles.deleteVerified(profileId)) return fail(result, "profileStale")
        result.success(
            mapOf(
                "schemaVersion" to SCHEMA_VERSION,
                "profileId" to profileId,
                "deleted" to true,
            ),
        )
    }

    private fun analyzeEnrollmentFrame(image: ImageProxy) {
        val operation = enrollment
        val mediaImage = image.image
        if (operation == null || mediaImage == null || session?.id != operation.sessionId ||
            !analysisBusy.compareAndSet(false, true)
        ) {
            image.close()
            return
        }
        val input = InputImage.fromMediaImage(mediaImage, image.imageInfo.rotationDegrees)
        detector.process(input)
            .addOnSuccessListener(main) { faces ->
                if (enrollment !== operation || session?.id != operation.sessionId) return@addOnSuccessListener
                faceVector(faces)?.let { vector ->
                    operation.samples.add(vector)
                    if (operation.samples.size >= ENROLLMENT_SAMPLES) completeEnrollment(operation)
                }
            }
            .addOnFailureListener(main) {
                if (enrollment === operation) stopEnrollment("unavailable")
            }
            .addOnCompleteListener {
                analysisBusy.set(false)
                image.close()
            }
    }

    private fun analyzeMatchFrame(image: ImageProxy) {
        val operation = matching
        val mediaImage = image.image
        if (operation == null || mediaImage == null || session?.id != operation.sessionId ||
            !analysisBusy.compareAndSet(false, true)
        ) {
            image.close()
            return
        }
        val input = InputImage.fromMediaImage(mediaImage, image.imageInfo.rotationDegrees)
        detector.process(input)
            .addOnSuccessListener(main) { faces ->
                if (matching !== operation || session?.id != operation.sessionId) return@addOnSuccessListener
                if (faces.size > 1) {
                    completeMatching(operation, "ambiguous")
                    return@addOnSuccessListener
                }
                faceVector(faces)?.let { vector ->
                    operation.samples.add(vector)
                    if (operation.samples.size >= MATCH_SAMPLES) {
                        val candidate = average(operation.samples)
                        val differences = candidate.zip(operation.profile.vector) { left, right -> left - right }
                        val rms = sqrt(differences.sumOf { it * it } / differences.size)
                        val maximum = differences.maxOf { abs(it) }
                        completeMatching(
                            operation,
                            if (rms <= MATCH_RMS_LIMIT && maximum <= MATCH_COMPONENT_LIMIT) {
                                "matched"
                            } else {
                                "noMatch"
                            },
                        )
                    }
                }
            }
            .addOnFailureListener(main) {
                if (matching === operation) stopMatching("unavailable")
            }
            .addOnCompleteListener {
                analysisBusy.set(false)
                image.close()
            }
    }

    private fun faceVector(faces: List<Face>): List<Double>? {
        val face = faces.singleOrNull() ?: return null
        if (face.boundingBox.width() < 160 || face.boundingBox.height() < 160 ||
            abs(face.headEulerAngleX) > 12f || abs(face.headEulerAngleY) > 12f ||
            abs(face.headEulerAngleZ) > 12f
        ) return null
        val leftEye = face.getLandmark(com.google.mlkit.vision.face.FaceLandmark.LEFT_EYE)?.position
            ?: return null
        val rightEye = face.getLandmark(com.google.mlkit.vision.face.FaceLandmark.RIGHT_EYE)?.position
            ?: return null
        val points = listOf(
            com.google.mlkit.vision.face.FaceLandmark.NOSE_BASE,
            com.google.mlkit.vision.face.FaceLandmark.MOUTH_LEFT,
            com.google.mlkit.vision.face.FaceLandmark.MOUTH_RIGHT,
            com.google.mlkit.vision.face.FaceLandmark.LEFT_CHEEK,
            com.google.mlkit.vision.face.FaceLandmark.RIGHT_CHEEK,
        ).map { face.getLandmark(it)?.position ?: return null }
        val dx = rightEye.x - leftEye.x
        val dy = rightEye.y - leftEye.y
        val eyeDistance = hypot(dx.toDouble(), dy.toDouble())
        if (eyeDistance < 24.0) return null
        val ux = dx / eyeDistance
        val uy = dy / eyeDistance
        val midX = (leftEye.x + rightEye.x) / 2.0
        val midY = (leftEye.y + rightEye.y) / 2.0
        val vector = mutableListOf<Double>()
        points.forEach { point ->
            val px = point.x - midX
            val py = point.y - midY
            vector += (px * ux + py * uy) / eyeDistance
            vector += (-px * uy + py * ux) / eyeDistance
        }
        vector += face.boundingBox.width().toDouble() / face.boundingBox.height().toDouble()
        return vector.takeIf { it.all(Double::isFinite) }
    }

    private fun completeEnrollment(operation: Enrollment) {
        if (enrollment !== operation) return
        val vector = average(operation.samples)
        val profile = PersonalFaceProfile(
            id = UUID.randomUUID().toString(),
            createdAtMs = System.currentTimeMillis(),
            sampleCount = operation.samples.size,
            detectorVersion = DETECTOR_VERSION,
            vector = vector,
        )
        try {
            profiles.save(profile)
            finishEnrollment(operation)
            operation.result.success(profileMap(profile))
        } catch (_: Exception) {
            stopEnrollment("unavailable")
        }
    }

    private fun average(samples: List<List<Double>>): List<Double> {
        val dimensions = samples.first().size
        return List(dimensions) { index -> samples.sumOf { it[index] } / samples.size }
    }

    private fun completeMatching(operation: Matching, state: String) {
        if (matching !== operation) return
        finishMatching(operation)
        operation.result.success(
            mapOf(
                "schemaVersion" to SCHEMA_VERSION,
                "profileId" to operation.profile.id,
                "state" to state,
                "sampleCount" to operation.samples.size,
            ),
        )
    }

    private fun profileMap(value: PersonalFaceProfile): Map<String, Any?> = mapOf(
        "schemaVersion" to SCHEMA_VERSION,
        "exists" to true,
        "profileId" to value.id,
        "createdAtMs" to value.createdAtMs,
        "sampleCount" to value.sampleCount,
        "detectorVersion" to value.detectorVersion,
    )

    private fun stopEnrollment(code: String) {
        val operation = enrollment ?: return
        finishEnrollment(operation)
        fail(operation.result, code)
    }

    private fun finishEnrollment(operation: Enrollment) {
        if (enrollment !== operation) return
        enrollment = null
        operation.timeout?.let { activity.window.decorView.removeCallbacks(it) }
        operation.analysis?.clearAnalyzer()
        operation.analysis?.let { analysis -> runCatching { provider?.unbind(analysis) } }
        operation.analysis = null
    }

    private fun stopMatching(code: String) {
        val operation = matching ?: return
        finishMatching(operation)
        fail(operation.result, code)
    }

    private fun finishMatching(operation: Matching) {
        if (matching !== operation) return
        matching = null
        operation.timeout?.let { activity.window.decorView.removeCallbacks(it) }
        operation.analysis?.clearAnalyzer()
        operation.analysis?.let { analysis -> runCatching { provider?.unbind(analysis) } }
        operation.analysis = null
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
                "personalizationMatching" to true,
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
        stopEnrollment("expired")
        stopMatching("expired")
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
        detector.close()
        analysisExecutor.shutdownNow()
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
