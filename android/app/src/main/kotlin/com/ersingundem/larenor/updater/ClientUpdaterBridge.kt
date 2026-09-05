package com.ersingundem.larenor.updater

import android.app.Activity
import android.app.KeyguardManager
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

class ClientUpdaterBridge(private val activity: Activity, messenger: BinaryMessenger) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler, UpdateHost {
    private val methods = MethodChannel(messenger, "com.ersingundem.larenor/client_updates")
    private val events = EventChannel(messenger, "com.ersingundem.larenor/client_updates_events")
    private val handler = Handler(Looper.getMainLooper())
    private val executor = Executors.newSingleThreadExecutor()
    private val verifier = AndroidApkVerifier(activity)
    private val coordinator = UpdateCoordinator(File(activity.cacheDir, "client_updates"), this)
    private val downloader = UpdateDownloader()
    private var sink: EventChannel.EventSink? = null
    private var resumed = false
    private var disposed = false
    private var permissionLaunched = false
    private var interactionEpoch = 0L
    private var lostFocus = false
    init { methods.setMethodCallHandler(this); events.setStreamHandler(this) }
    fun setResumed(value: Boolean) { if (value && !resumed) permissionLaunched = false; resumed = value; if (!value) { interactionEpoch++; coordinator.suspend() } }
    fun windowChanged() {
        if (!foreground()) { interactionEpoch++; lostFocus = true; coordinator.suspend() }
        else if (lostFocus) { lostFocus = false; permissionLaunched = false }
    }
    override fun foreground() = !disposed && resumed && activity.window.decorView.hasWindowFocus() &&
        !(activity.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager).isKeyguardLocked
    override fun installed() = verifier.installed()
    override fun verify(file: File) = verifier.verify(file)
    override fun onListen(arguments: Any?, events: EventChannel.EventSink) { sink = events }
    override fun onCancel(arguments: Any?) { sink = null }
    private fun string(map: Map<*, *>, name: String) = map[name] as? String ?: throw UpdateFailure("invalidMetadata")
    private fun args(raw: Any?, count: Int): Map<*, *> = (raw as? Map<*, *>)?.takeIf { it.size == count } ?: throw UpdateFailure("invalidMetadata")
    private fun requireInteraction(raw: Map<*, *>) {
        val expected = when(val value = raw["interactionEpoch"]) { is Int -> value.toLong(); is Long -> value; else -> throw UpdateFailure("expired") }
        if (expected != interactionEpoch || !foreground()) throw UpdateFailure("expired")
    }
    private fun error(result: MethodChannel.Result, e: Exception) = result.error((e as? UpdateFailure)?.code ?: "unavailable", "Client update unavailable", null)
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (disposed) { error(result, UpdateFailure("expired")); return }
        try {
            when (call.method) {
                "snapshot" -> {
                    if (call.arguments != null) throw UpdateFailure("invalidMetadata")
                    val installed = installed()
                    result.success(mapOf("supported" to true, "applicationId" to installed.applicationId,
                        "versionCode" to installed.versionCode, "versionName" to installed.versionName,
                        "certificateSha256" to installed.certificates.toList(), "sdkInt" to installed.sdkInt,
                        "canRequestPackageInstalls" to activity.packageManager.canRequestPackageInstalls(),
                        "resumed" to resumed, "focused" to activity.window.decorView.hasWindowFocus(), "interactionEpoch" to interactionEpoch))
                }
                "activateSession", "invalidate", "cancel" -> {
                    val raw = args(call.arguments, 1); val id = string(raw, "sessionId")
                    when(call.method) { "activateSession" -> coordinator.activate(id); "invalidate" -> coordinator.invalidate(id); else -> coordinator.cancel(id) }
                    result.success(null)
                }
                "download" -> {
                    val raw = args(call.arguments, 6); requireInteraction(raw)
                    val release = ClientRelease.parse(raw["release"])
                    val base = string(raw, "baseUrl"); val token = string(raw, "accessToken")
                    // Validate the URL and header before reserving the operation.
                    UpdateValidation.url(base, release)
                    val work = coordinator.beginDownload(string(raw, "sessionId"), release, string(raw, "downloadId"))
                    executor.execute {
                        try {
                            var last = 0L
                            downloader.download(base, token, release, work.file, work.cancellation) { bytes ->
                                if (bytes == release.sizeBytes || bytes - last >= 256 * 1024) { last = bytes; progress(work, bytes, "downloading") }
                            }
                            coordinator.check(work); progress(work, release.sizeBytes, "verifying")
                            coordinator.verify(work)
                            handler.post {
                                try { result.success(coordinator.finishDownload(work).packet()) }
                                catch (e: Exception) { coordinator.failed(work); error(result, e) }
                            }
                        } catch (e: Exception) { coordinator.failed(work); handler.post { error(result, e) } }
                    }
                }
                "install" -> {
                    val raw = args(call.arguments, 3); requireInteraction(raw)
                    if (!activity.packageManager.canRequestPackageInstalls()) throw UpdateFailure("installPermission")
                    val work = coordinator.beginInstall(string(raw, "sessionId"), string(raw, "id"))
                    executor.execute {
                        try {
                            verifier.verifyHash(work.file, work.release, work.cancellation)
                            coordinator.verify(work)
                            handler.post {
                                try {
                                    if (!activity.packageManager.canRequestPackageInstalls()) throw UpdateFailure("installPermission")
                                    val file = coordinator.consumeInstall(work)
                                    val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.client_updates", file)
                                    @Suppress("DEPRECATION")
                                    val intent = Intent(Intent.ACTION_INSTALL_PACKAGE).setDataAndType(uri, "application/vnd.android.package-archive")
                                        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                    intent.clipData = ClipData.newRawUri("Client update", uri)
                                    activity.startActivity(intent)
                                    // The OS dialog opening does not prove installation succeeded.
                                    result.success(mapOf("outcome" to "systemPromptOpened"))
                                } catch (e: Exception) { coordinator.failed(work); error(result, e) }
                            }
                        } catch (e: Exception) { coordinator.failed(work); handler.post { error(result, e) } }
                    }
                }
                "openInstallPermission" -> {
                    val raw = args(call.arguments, 2); requireInteraction(raw)
                    coordinator.requirePermissionAction(string(raw, "sessionId"))
                    if (permissionLaunched) throw UpdateFailure("busy")
                    permissionLaunched = true
                    try { activity.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${activity.packageName}"))) }
                    catch(e: Exception) { permissionLaunched = false; throw e }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) { error(result, e) }
    }
    private fun progress(work: UpdateWork, received: Long, phase: String) {
        handler.post { if (coordinator.current(work)) sink?.success(mapOf("sessionId" to work.sessionId,
            "downloadId" to work.id, "receivedBytes" to received, "totalBytes" to work.release.sizeBytes, "phase" to phase)) }
    }
    fun dispose() {
        if (disposed) return
        disposed = true; coordinator.dispose(); executor.shutdownNow(); sink = null
        methods.setMethodCallHandler(null); events.setStreamHandler(null)
    }
}
