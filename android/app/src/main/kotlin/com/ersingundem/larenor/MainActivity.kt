package com.ersingundem.larenor

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import androidx.media3.common.util.UnstableApi
import com.ersingundem.larenor.audio.LocalAudioBridge

@UnstableApi
class MainActivity : FlutterActivity() {
    private var localAudio: LocalAudioBridge? = null
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        localAudio = LocalAudioBridge(this, flutterEngine.dartExecutor.binaryMessenger)
    }
    override fun onResume() { super.onResume(); localAudio?.setResumed(true) }
    override fun onPause() { localAudio?.setResumed(false); super.onPause() }
    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        localAudio?.dispose()
        localAudio = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
