package com.ersingundem.larenor.game.moonlight

import android.content.Context
import android.content.SharedPreferences
import android.os.Bundle
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.view.KeyEvent
import android.view.MotionEvent
import com.limelight.Game
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream

/** The actual upstream MediaCodec/audio/input activity behind an opaque launch token. */
class LarenorMoonlightGame : Game() {
    private var launchToken: String? = null
    private var scoped: MoonlightScopedContext? = null
    private var resumed = false
    private var focused = false
    private var claimed = false
    override fun onCreate(savedInstanceState: Bundle?) {
        val token = intent?.getStringExtra(EXTRA_LAUNCH_TOKEN)
            ?: throw MoonlightRuntimeFailure("foreground_required")
        val spec = MoonlightForegroundLeaseRegistry.resolveForLaunch(token)
        @Suppress("DEPRECATION")
        requireLaunchDisplay(spec.displayId, windowManager.defaultDisplay.displayId)
        launchToken = token
        scoped = MoonlightScopedContext.create(applicationContext, spec.authority.scope)
        intent.apply {
            removeExtra(EXTRA_LAUNCH_TOKEN)
            putExtra(Game.EXTRA_HOST, spec.host)
            putExtra(Game.EXTRA_PORT, spec.port)
            putExtra(Game.EXTRA_HTTPS_PORT, spec.httpsPort)
            putExtra(Game.EXTRA_APP_NAME, spec.appName)
            putExtra(Game.EXTRA_APP_ID, spec.appId)
            putExtra(Game.EXTRA_UNIQUEID, spec.uniqueId)
            putExtra(Game.EXTRA_PC_UUID, spec.computerUuid)
            putExtra(Game.EXTRA_PC_NAME, spec.computerName)
            putExtra(Game.EXTRA_APP_HDR, spec.supportsHdr)
            putExtra(Game.EXTRA_SERVER_CERT, spec.serverCertificate.copyOf())
        }
        secureMoonlightWindow(this)
        try {
            super.onCreate(savedInstanceState)
        } catch (failure: Throwable) {
            MoonlightForegroundLeaseRegistry.gameDestroyed(token)
            throw failure
        }
    }

    override fun setContentView(layoutResID: Int) {
        // Moonlight's activity_game root is <merge>. Activity/PhoneWindow must
        // attach it; manually inflating with attachToRoot=false always fails.
        super.setContentView(layoutResID)
        val content = window.decorView.findViewById<ViewGroup>(android.R.id.content)
        secureMoonlightSurfaces(content)
    }

    override fun onResume() {
        super.onResume()
        resumed = true
        claimWhenVisible()
    }

    override fun onPause() {
        resumed = false
        super.onPause()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        focused = hasFocus
        claimWhenVisible()
    }

    override fun dispatchTouchEvent(event: MotionEvent): Boolean {
        launchToken?.let(MoonlightForegroundLeaseRegistry::inputActivity)
        return super.dispatchTouchEvent(event)
    }

    override fun dispatchGenericMotionEvent(event: MotionEvent): Boolean {
        launchToken?.let(MoonlightForegroundLeaseRegistry::inputActivity)
        return super.dispatchGenericMotionEvent(event)
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        launchToken?.let(MoonlightForegroundLeaseRegistry::inputActivity)
        return super.dispatchKeyEvent(event)
    }

    override fun connectionStarted() {
        launchToken?.let(MoonlightForegroundLeaseRegistry::connectionStarted)
        super.connectionStarted()
    }

    override fun connectionTerminated(errorCode: Int) {
        launchToken?.let(MoonlightForegroundLeaseRegistry::connectionTerminated)
        super.connectionTerminated(errorCode)
    }

    override fun onConnectionStopStarted() {
        launchToken?.let(MoonlightForegroundLeaseRegistry::connectionStopStarted)
    }

    override fun onConnectionStopCompleted() {
        launchToken?.let(MoonlightForegroundLeaseRegistry::connectionStopped)
    }

    override fun onVideoFrameRendered(presentationTimeUs: Long, renderTimeNanos: Long) {
        launchToken?.let(MoonlightForegroundLeaseRegistry::videoFrameRendered)
    }

    override fun onAudioPcmWritten(requestedSamples: Int, writtenSamples: Int) {
        launchToken?.let {
            MoonlightForegroundLeaseRegistry.audioPcmWritten(
                it,
                requestedSamples,
                writtenSamples,
            )
        }
    }

    override fun onStop() {
        launchToken?.let {
            MoonlightForegroundLeaseRegistry.gameHidden(it, isInPictureInPictureMode)
        }
        super.onStop()
    }

    override fun onDestroy() {
        launchToken?.let {
            runCatching { MoonlightForegroundLeaseRegistry.gameDestroyed(it) }
        }
        scoped = null
        super.onDestroy()
    }

    private fun claimWhenVisible() {
        val token = launchToken ?: return
        if (resumed && focused && !claimed) {
            MoonlightForegroundLeaseRegistry.claim(token, this)
            claimed = true
        }
    }

    override fun getFilesDir(): File = scoped?.filesDir ?: super.getFilesDir()
    override fun getNoBackupFilesDir(): File = scoped?.noBackupFilesDir ?: super.getNoBackupFilesDir()
    override fun openFileInput(name: String): FileInputStream = scoped?.openFileInput(name) ?: super.openFileInput(name)
    override fun openFileOutput(name: String, mode: Int): FileOutputStream =
        scoped?.openFileOutput(name, mode) ?: super.openFileOutput(name, mode)
    override fun deleteFile(name: String): Boolean = scoped?.deleteFile(name) ?: super.deleteFile(name)
    override fun getFileStreamPath(name: String): File = scoped?.getFileStreamPath(name) ?: super.getFileStreamPath(name)
    override fun getSharedPreferences(name: String, mode: Int): SharedPreferences =
        scoped?.getSharedPreferences(name, mode) ?: super.getSharedPreferences(name, mode)

    companion object {
        const val EXTRA_LAUNCH_TOKEN = "com.ersingundem.larenor.game.moonlight.LAUNCH_TOKEN"
    }
}

internal fun secureMoonlightWindow(activity: android.app.Activity) {
    activity.window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
}

internal fun requireLaunchDisplay(expectedDisplayId: Int, actualDisplayId: Int) {
    if (expectedDisplayId != actualDisplayId) throw MoonlightRuntimeFailure("foreground_required")
}

internal fun secureMoonlightSurfaces(view: View) {
    if (view is SurfaceView) {
        view.setSecure(true)
    }
    if (view is ViewGroup) {
        repeat(view.childCount) { secureMoonlightSurfaces(view.getChildAt(it)) }
    }
}
