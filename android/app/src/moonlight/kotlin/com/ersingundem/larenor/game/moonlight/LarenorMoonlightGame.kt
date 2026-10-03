package com.ersingundem.larenor.game.moonlight

import android.content.Context
import android.content.SharedPreferences
import android.os.Bundle
import android.os.Build
import android.view.SurfaceHolder
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
    private var topResumed = false
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
        // The decor can attach after onResume. Re-check the exact lifecycle
        // when that happens; a queued callback never overrides later pause.
        window.decorView.post(::claimWhenVisible)
    }

    override fun onPause() {
        resumed = false
        retireWhenBackgrounded()
        super.onPause()
    }

    override fun onTopResumedActivityChanged(isTopResumedActivity: Boolean) {
        super.onTopResumedActivityChanged(isTopResumedActivity)
        topResumed = isTopResumedActivity
        if (isTopResumedActivity) {
            claimWhenVisible()
        } else {
            retireWhenBackgrounded()
        }
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        claimWhenVisible()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        // The upstream connection spinner owns focus until connectionStarted.
        // Activity ownership must not wait on that circular dependency.
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

    override fun surfaceCreated(holder: SurfaceHolder) {
        launchToken?.let(MoonlightForegroundLeaseRegistry::surfaceCreated)
        super.surfaceCreated(holder)
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        launchToken?.let {
            MoonlightForegroundLeaseRegistry.positiveSurfaceChanged(it, width, height)
        }
        super.surfaceChanged(holder, format, width, height)
    }

    override fun stageStarting(stage: String?) {
        launchToken?.let(MoonlightForegroundLeaseRegistry::stageStarted)
        super.stageStarting(stage)
    }

    override fun stageComplete(stage: String?) {
        launchToken?.let(MoonlightForegroundLeaseRegistry::stageCompleted)
        super.stageComplete(stage)
    }

    override fun stageFailed(stage: String?, portFlags: Int, errorCode: Int) {
        launchToken?.let(MoonlightForegroundLeaseRegistry::stageFailed)
        super.stageFailed(stage, portFlags, errorCode)
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
        val decor = window.decorView
        // API 29 introduced multi-resume. Earlier Android versions have one
        // resumed foreground Activity; newer versions require the top owner.
        val ownsForeground = Build.VERSION.SDK_INT < Build.VERSION_CODES.Q || topResumed
        if (resumed && ownsForeground && decor.isAttachedToWindow && decor.isShown &&
            !isFinishing && !isDestroyed && !claimed) {
            MoonlightForegroundLeaseRegistry.claim(token, this)
            claimed = true
        }
    }

    private fun retireWhenBackgrounded() {
        if (claimed) {
            launchToken?.let {
                MoonlightForegroundLeaseRegistry.gameHidden(it, isInPictureInPictureMode)
            }
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
