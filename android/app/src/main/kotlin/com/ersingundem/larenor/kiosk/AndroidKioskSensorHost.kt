package com.ersingundem.larenor.kiosk

import android.Manifest
import android.content.pm.PackageManager
import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.hardware.camera2.CameraManager
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import java.util.UUID
import kotlin.math.sqrt

/** Reads only ambient light and device acceleration; it never opens a camera or microphone. */
class AndroidKioskSensorHost(context: Context) : KioskSensorHost, SensorEventListener {
    private val context = context.applicationContext
    private val manager = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    private val cameras = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
    private val light = manager.getDefaultSensor(Sensor.TYPE_LIGHT)
    private val motion = manager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
    private var listener: ((KioskSensorSample) -> Unit)? = null
    private var lastVector: DoubleArray? = null
    private var lightStarted = false
    private var motionStarted = false
    private val unavailableCameras = mutableSetOf<String>()
    private var watchingCameras = false
    private var cameraAvailabilityObserved = false
    private val cameraCallback = object : CameraManager.AvailabilityCallback() {
        override fun onCameraAvailable(cameraId: String) {
            cameraAvailabilityObserved = true
            unavailableCameras.remove(cameraId)
        }

        override fun onCameraUnavailable(cameraId: String) {
            cameraAvailabilityObserved = true
            unavailableCameras.add(cameraId)
        }
    }

    override fun availability(): KioskSensorAvailability {
        val granted = context.checkSelfPermission(Manifest.permission.CAMERA) ==
            PackageManager.PERMISSION_GRANTED
        val ids = if (granted) {
            try { cameras.cameraIdList.toSet() } catch (_: RuntimeException) { emptySet() }
        } else {
            emptySet()
        }
        val camera = when {
            !granted -> "permissionDenied"
            ids.isEmpty() -> "unavailable"
            !cameraAvailabilityObserved -> "unavailable"
            ids.all(unavailableCameras::contains) -> "busy"
            else -> "available"
        }
        return KioskSensorAvailability(lightStarted, motionStarted, camera)
    }

    override fun start(listener: (KioskSensorSample) -> Unit) {
        stop()
        this.listener = listener
        lightStarted = light?.let {
            manager.registerListener(this, it, SensorManager.SENSOR_DELAY_NORMAL)
        } == true
        motionStarted = motion?.let {
            manager.registerListener(this, it, SensorManager.SENSOR_DELAY_NORMAL)
        } == true
        if (context.checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
            cameras.registerAvailabilityCallback(cameraCallback, Handler(Looper.getMainLooper()))
            watchingCameras = true
        }
    }

    override fun stop() {
        manager.unregisterListener(this)
        if (watchingCameras) {
            try { cameras.unregisterAvailabilityCallback(cameraCallback) } catch (_: RuntimeException) { }
        }
        watchingCameras = false
        cameraAvailabilityObserved = false
        lightStarted = false
        motionStarted = false
        unavailableCameras.clear()
        listener = null
        lastVector = null
    }

    override fun onSensorChanged(event: SensorEvent?) {
        val current = listener ?: return
        val value = event ?: return
        val at = nowMillis()
        when (value.sensor.type) {
            Sensor.TYPE_LIGHT -> value.values.firstOrNull()?.toDouble()?.let {
                current(KioskSensorSample.Light(it, at))
            }
            Sensor.TYPE_ACCELEROMETER -> if (value.values.size >= 3) {
                val next = doubleArrayOf(
                    value.values[0].toDouble(),
                    value.values[1].toDouble(),
                    value.values[2].toDouble(),
                )
                val previous = lastVector
                lastVector = next
                val delta = if (previous == null) 0.0 else sqrt(
                    (next[0] - previous[0]) * (next[0] - previous[0]) +
                        (next[1] - previous[1]) * (next[1] - previous[1]) +
                        (next[2] - previous[2]) * (next[2] - previous[2]),
                )
                current(KioskSensorSample.Motion(delta, at))
            }
        }
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit
    override fun nowMillis(): Long = SystemClock.elapsedRealtime()
    override fun token(): String = UUID.randomUUID().toString()
}
