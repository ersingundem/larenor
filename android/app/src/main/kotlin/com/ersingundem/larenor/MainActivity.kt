package com.ersingundem.larenor

import android.content.res.Configuration
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import androidx.media3.common.util.UnstableApi
import com.ersingundem.larenor.audio.LocalAudioBridge
import com.ersingundem.larenor.window.WindowPolicyBridge
import com.ersingundem.larenor.wellbeing.WellbeingBridge

@UnstableApi
class MainActivity : FlutterActivity() {
    private var localAudio: LocalAudioBridge? = null
    private var windowPolicy: WindowPolicyBridge? = null
    private var wellbeing: WellbeingBridge? = null
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        localAudio = LocalAudioBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        windowPolicy = WindowPolicyBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        wellbeing = WellbeingBridge(this, flutterEngine.dartExecutor.binaryMessenger)
    }
    override fun onResume() {
        super.onResume()
        localAudio?.setResumed(true)
        windowPolicy?.setResumed(true)
        wellbeing?.setResumed(true)
    }
    override fun onPause() {
        localAudio?.setResumed(false)
        windowPolicy?.setResumed(false)
        wellbeing?.setResumed(false)
        super.onPause()
    }
    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        wellbeing?.windowFocusChanged()
        windowPolicy?.windowChanged()
    }
    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        windowPolicy?.windowChanged()
    }
    @Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
    override fun onMultiWindowModeChanged(isInMultiWindowMode: Boolean) {
        super.onMultiWindowModeChanged(isInMultiWindowMode)
        windowPolicy?.windowChanged()
    }
    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        wellbeing?.dispose()
        wellbeing = null
        windowPolicy?.dispose()
        windowPolicy = null
        localAudio?.dispose()
        localAudio = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
