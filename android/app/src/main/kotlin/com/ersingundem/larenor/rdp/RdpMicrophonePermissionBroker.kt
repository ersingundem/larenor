package com.ersingundem.larenor.rdp

import android.Manifest
import android.app.Activity
import android.app.AppOpsManager
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel

/** Owns only the RDP microphone permission prompt. It never starts capture. */
internal class RdpMicrophonePermissionBroker(
    private val activity: Activity,
    private val onRevoked: () -> Unit,
    private val handler: Handler = Handler(Looper.getMainLooper()),
) {
    private data class Pending(
        val requestId: String,
        val result: MethodChannel.Result,
        val generation: Long,
    )

    private val packageName = activity.packageName
    private val appOps = activity.getSystemService(AppOpsManager::class.java)
    private var pending: Pending? = null
    private var generation = 0L
    private var deadline: Runnable? = null
    private var disposed = false
    private var focused = true
    private var grantedWhileUnfocused: Pending? = null
    private val permissionListener = AppOpsManager.OnOpChangedListener { operation, owner ->
        onAppOpChanged(operation, owner)
    }

    internal fun onAppOpChanged(operation: String, owner: String) {
        if (operation == AppOpsManager.OPSTR_RECORD_AUDIO && owner == packageName) handler.post {
            if (!disposed && !granted()) {
                grantedWhileUnfocused?.let { finishSuccess(it, false) }
                onRevoked()
            }
        }
    }

    init {
        appOps.startWatchingMode(
            AppOpsManager.OPSTR_RECORD_AUDIO,
            packageName,
            permissionListener,
        )
    }

    @Suppress("DEPRECATION")
    fun granted(): Boolean {
        if (activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) !=
            PackageManager.PERMISSION_GRANTED
        ) return false
        return when (appOps.checkOpNoThrow(
            AppOpsManager.OPSTR_RECORD_AUDIO,
            android.os.Process.myUid(),
            packageName,
        )) {
            AppOpsManager.MODE_ALLOWED,
            AppOpsManager.MODE_DEFAULT,
            AppOpsManager.MODE_FOREGROUND,
            -> true
            else -> false
        }
    }

    fun setWindowFocused(value: Boolean) {
        focused = value
        if (value) {
            grantedWhileUnfocused?.let { finishSuccess(it, granted()) }
        }
    }

    fun request(requestId: String, result: MethodChannel.Result) {
        if (disposed) {
            result.error("engineUnavailable", "RDP microphone permission unavailable", null)
            return
        }
        if (pending != null) {
            result.error("busy", "RDP microphone permission busy", null)
            return
        }
        if (granted()) {
            result.success(receipt(requestId, true))
            return
        }
        val owned = Pending(requestId, result, ++generation)
        pending = owned
        deadline = Runnable {
            if (pending === owned) finishError(owned, "timedOut")
        }.also { handler.postDelayed(it, PERMISSION_DEADLINE_MS) }
        try {
            activity.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), REQUEST_CODE)
        } catch (_: RuntimeException) {
            finishError(owned, "connectionFailed")
        }
    }

    fun cancel(requestId: String) {
        val owned = pending ?: return
        if (owned.requestId == requestId) finishError(owned, "cancelled")
    }

    fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != REQUEST_CODE) return false
        val owned = pending ?: return true
        val exactGrant = permissions.contentEquals(arrayOf(Manifest.permission.RECORD_AUDIO)) &&
            grantResults.contentEquals(intArrayOf(PackageManager.PERMISSION_GRANTED)) && granted()
        if (exactGrant && !focused) {
            grantedWhileUnfocused = owned
        } else {
            finishSuccess(owned, exactGrant)
        }
        return true
    }

    fun dispose() {
        if (disposed) return
        disposed = true
        pending?.let { finishError(it, "cancelled") }
        deadline?.let(handler::removeCallbacks)
        deadline = null
        appOps.stopWatchingMode(permissionListener)
    }

    private fun finishSuccess(owned: Pending, granted: Boolean) {
        if (pending !== owned || owned.generation != generation) return
        pending = null
        grantedWhileUnfocused = null
        deadline?.let(handler::removeCallbacks)
        deadline = null
        owned.result.success(receipt(owned.requestId, granted))
    }

    private fun finishError(owned: Pending, code: String) {
        if (pending !== owned || owned.generation != generation) return
        pending = null
        grantedWhileUnfocused = null
        deadline?.let(handler::removeCallbacks)
        deadline = null
        owned.result.error(code, "RDP microphone permission unavailable", null)
    }

    private fun receipt(requestId: String, granted: Boolean) = mapOf(
        "schemaVersion" to 4,
        "requestId" to requestId,
        "granted" to granted,
    )

    companion object {
        const val REQUEST_CODE = 41060
        private const val PERMISSION_DEADLINE_MS = 30_000L
    }
}
