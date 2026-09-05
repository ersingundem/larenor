package com.ersingundem.larenor.wellbeing

import android.app.Activity
import android.content.Intent
import android.os.Build
import android.view.WindowManager
import androidx.health.connect.client.HealthConnectClient
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.time.ZoneId
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout

class WellbeingBridge(
    private val activity: Activity,
    messenger: BinaryMessenger,
    private val backend: WellbeingBackend = HealthConnectBackend(activity.applicationContext),
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, "larenor/wellbeing")
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var resumed = false
    private var disposed = false
    private var epoch = 0L
    private var readJob: Job? = null
    private var permissionBusy = false
    private val requested = mutableSetOf<WellbeingMetric>()
    private val foreground: Boolean get() = !disposed && resumed && activity.window.decorView.hasWindowFocus()
    private val privateView = WellbeingPrivateView(object : WellbeingSecureWindow {
        override fun isSecure() = activity.window.attributes.flags and WindowManager.LayoutParams.FLAG_SECURE != 0
        override fun setSecure(value: Boolean) {
            if (value) activity.window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
            else activity.window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
    }) { foreground }
    init { channel.setMethodCallHandler(this) }

    fun setResumed(value: Boolean) {
        resumed = value
        if (!value) { cancelRead(); privateView.background() }
    }
    fun windowFocusChanged() { if (!foreground) { cancelRead(); privateView.background() } }
    private fun cancelRead() { epoch++; readJob?.cancel(); readJob = null }

    private suspend fun status(): Map<String, Any?> = withTimeout(10_000) {
        val availability = backend.availability()
        val granted = if (availability == "available") backend.granted() else emptySet()
        mapOf("availability" to availability,
            "permissions" to WellbeingMetric.entries.associate { it.name to when {
                it in granted -> "granted"
                it in requested -> "denied"
                else -> "notRequested"
            } })
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (disposed) { fail(result, "unavailable"); return }
        try {
            when (call.method) {
                "probe" -> {
                    require(call.arguments == null)
                    scope.launch { try { result.success(status()) }
                        catch (_: Exception) { if (!disposed) fail(result, "unavailable") } }
                }
                "cancel" -> { require(call.arguments == null); cancelRead(); result.success(null) }
                "setPrivateView" -> {
                    require(call.arguments is Boolean)
                    if (call.arguments == false) cancelRead()
                    privateView.setPrivate(call.arguments as Boolean)
                    result.success(null)
                }
                "read" -> {
                    check(foreground && privateView.active)
                    check(readJob == null && !permissionBusy)
                    val request = WellbeingReadRequest.parse(call.arguments, System.currentTimeMillis())
                    val generation = ++epoch
                    val zone = ZoneId.systemDefault()
                    val job = scope.launch {
                        try {
                            val response = withTimeout(28_000) {
                                WellbeingReader(backend).read(request, zone) { privateView.active && generation == epoch }
                            }
                            if (privateView.active && generation == epoch) result.success(response)
                            else fail(result, "cancelled")
                        } catch (_: TimeoutCancellationException) { if (!disposed) fail(result, "timeout") }
                        catch (_: CancellationException) { if (!disposed) fail(result, "cancelled") }
                        catch (_: Exception) { if (!disposed) fail(result, "readFailed") }
                        finally { if (generation == epoch) readJob = null }
                    }
                    readJob = job.takeUnless { it.isCompleted }
                }
                "requestReadPermissions" -> {
                    check(privateView.active && !permissionBusy && readJob == null)
                    val raw = call.arguments
                    require(raw is Map<*, *> && raw.keys == setOf("metrics"))
                    val metrics = WellbeingMetric.parse(raw["metrics"]).toSet()
                    permissionBusy = true
                    val permissionEpoch = epoch
                    scope.launch {
                        var token: String? = null
                        try {
                            if (backend.availability() != "available") {
                                result.success(status())
                                return@launch
                            }
                            val granted = withTimeout(10_000) { backend.granted() }
                            check(privateView.active && epoch == permissionEpoch)
                            if (!granted.containsAll(metrics)) {
                                val pending = WellbeingPermissionRuntime.broker.begin(this@WellbeingBridge,
                                    metrics, foreground) { !disposed }
                                token = pending.token
                                activity.startActivity(Intent(activity, WellbeingPermissionActivity::class.java)
                                    .putExtra(WellbeingPermissionActivity.EXTRA_TICKET, token))
                                requested.addAll(metrics)
                                withTimeout(300_000) { pending.finished.await() }
                            }
                            if (!disposed) result.success(status())
                        } catch (_: Exception) { if (!disposed) fail(result, "permission") }
                        finally { WellbeingPermissionRuntime.broker.finish(token); permissionBusy = false }
                    }
                }
                "openPermissionSettings" -> {
                    require(call.arguments == null)
                    check(foreground && !permissionBusy)
                    check(backend.availability() == "available")
                    val intent = Intent(HealthConnectClient.ACTION_HEALTH_CONNECT_SETTINGS)
                    if (Build.VERSION.SDK_INT < 34) intent.setPackage("com.google.android.apps.healthdata")
                    activity.startActivity(intent)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (_: IllegalArgumentException) { fail(result, "invalidData") }
        catch (_: Exception) { fail(result, "unavailable") }
    }
    private fun fail(result: MethodChannel.Result, code: String) =
        result.error(code, "Wellbeing operation unavailable", null)

    fun dispose() {
        if (disposed) return
        privateView.dispose()
        disposed = true
        cancelRead()
        WellbeingPermissionRuntime.broker.disposeOwner(this)
        channel.setMethodCallHandler(null)
        scope.cancel()
    }
}
