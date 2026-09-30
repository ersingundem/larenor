package com.ersingundem.larenor.speech

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognitionSupport
import android.speech.RecognitionSupportCallback
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

/** Device-local STT/TTS only. Never records files, uploads audio or executes commands. */
interface LocalSpeechHost {
    fun available(): Boolean
    fun recognize(locale: String, completed: (String?, String?) -> Unit)
    fun speak(locale: String, text: String, completed: (String?) -> Unit)
    fun stop()
}

class AndroidLocalSpeechHost(private val activity: Activity) : LocalSpeechHost {
    private val handler = Handler(Looper.getMainLooper())
    private var recognizer: SpeechRecognizer? = null
    private var tts: TextToSpeech? = null
    private var epoch = 0

    override fun available() = Build.VERSION.SDK_INT >= 31 &&
        SpeechRecognizer.isOnDeviceRecognitionAvailable(activity)

    override fun recognize(locale: String, completed: (String?, String?) -> Unit) {
        stop()
        val generation = epoch
        if (!available()) { completed(null, "modelUnavailable"); return }
        val engine = SpeechRecognizer.createOnDeviceSpeechRecognizer(activity)
        recognizer = engine
        fun finish(text: String?, code: String?) {
            if (generation != epoch) return
            stop()
            completed(text, code)
        }
        engine.setRecognitionListener(object : RecognitionListener {
            override fun onReadyForSpeech(params: Bundle?) {}
            override fun onBeginningOfSpeech() {}
            override fun onRmsChanged(rmsdB: Float) {}
            override fun onBufferReceived(buffer: ByteArray?) {} // Discard audio buffers.
            override fun onEndOfSpeech() {}
            override fun onPartialResults(partialResults: Bundle?) {} // Only final transcripts.
            override fun onEvent(eventType: Int, params: Bundle?) {}
            override fun onError(error: Int) = finish(null, when (error) {
                SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "permissionDenied"
                SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED,
                SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE -> "modelUnavailable"
                SpeechRecognizer.ERROR_NO_MATCH,
                SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "noSpeech"
                else -> "unavailable"
            })
            override fun onResults(results: Bundle?) {
                val text = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                    ?.firstOrNull()?.trim()
                if (text == null || !validText(text)) finish(null, "invalidTranscript")
                else finish(text, null)
            }
        })
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
            .putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            .putExtra(RecognizerIntent.EXTRA_LANGUAGE, locale)
            .putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
            .putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, false)
            .putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
        if (Build.VERSION.SDK_INT >= 33) {
            engine.checkRecognitionSupport(intent, activity.mainExecutor, object : RecognitionSupportCallback {
                override fun onSupportResult(support: RecognitionSupport) {
                    if (generation != epoch) return
                    try {
                        val installed = support.installedOnDeviceLanguages.any { it.equals(locale, true) }
                        if (!installed) finish(null, "modelUnavailable")
                        else engine.startListening(intent)
                    } catch (_: RuntimeException) { finish(null, "unavailable") }
                }
                override fun onError(error: Int) = finish(null, "modelUnavailable")
            })
        } else engine.startListening(intent)
    }

    override fun speak(locale: String, text: String, completed: (String?) -> Unit) {
        stop()
        val generation = epoch
        fun finish(code: String?) {
            if (generation != epoch) return
            stop()
            completed(code)
        }
        // Posting handles an init failure callback occurring during construction.
        tts = TextToSpeech(activity.applicationContext) { status -> handler.post {
            if (generation != epoch) return@post
            val engine = tts
            if (status != TextToSpeech.SUCCESS || engine == null) {
                finish("voiceUnavailable"); return@post
            }
            try {
            val language = Locale.forLanguageTag(locale)
            val voice = engine.voices?.filter {
                !it.isNetworkConnectionRequired &&
                    it.features?.contains(TextToSpeech.Engine.KEY_FEATURE_NOT_INSTALLED) != true &&
                    it.locale.language == language.language && it.locale.country == language.country
            }?.sortedBy { it.name }?.firstOrNull()
            if (voice == null || engine.setVoice(voice) != TextToSpeech.SUCCESS) {
                finish("voiceUnavailable"); return@post
            }
            engine.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                override fun onStart(utteranceId: String?) {}
                override fun onDone(utteranceId: String?) { handler.post { finish(null) } }
                @Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
                override fun onError(utteranceId: String?) { handler.post { finish("unavailable") } }
                override fun onError(utteranceId: String?, errorCode: Int) {
                    handler.post { finish("unavailable") }
                }
            })
            if (engine.speak(text, TextToSpeech.QUEUE_FLUSH, Bundle(), "larenor-local-preview") != TextToSpeech.SUCCESS) {
                finish("unavailable")
            }
            } catch (_: RuntimeException) { finish("unavailable") }
        } }
    }

    override fun stop() {
        epoch++
        val previous = recognizer
        recognizer = null
        runCatching { previous?.cancel() }
        runCatching { previous?.destroy() }
        val voice = tts
        tts = null
        runCatching { voice?.stop() }
        runCatching { voice?.shutdown() }
    }

    companion object {
        fun validText(text: String) = text.isNotBlank() && text.length <= 256 &&
            text.none { Character.isISOControl(it) || Character.getType(it) == Character.FORMAT.toInt() }
    }
}

class LocalSpeechBridge(
    private val activity: Activity,
    messenger: BinaryMessenger,
    private val host: LocalSpeechHost = AndroidLocalSpeechHost(activity),
    private val focused: () -> Boolean = { activity.window.decorView.hasWindowFocus() },
) : MethodChannel.MethodCallHandler {
    companion object {
        const val CHANNEL = "com.ersingundem.larenor/local_speech"
        const val REQUEST_MICROPHONE = 41059
        private val LOCALES = setOf("en-US", "tr-TR")
    }
    private val methods = MethodChannel(messenger, CHANNEL)
    private val handler = Handler(Looper.getMainLooper())
    private var resumed = false
    private var disposed = false
    private var epoch = 0
    private var pending: MethodChannel.Result? = null
    private var permission: MethodChannel.Result? = null
    private var deadline: Runnable? = null
    private fun interactive() = resumed && !disposed && !activity.isFinishing && focused()
    private fun granted() = activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
    private fun fail(result: MethodChannel.Result, code: String) = result.error(code, "Local speech is unavailable.", null)
    init { methods.setMethodCallHandler(this) }

    fun setResumed(value: Boolean) {
        resumed = value
        if (!value) cancel("cancelled")
    }
    fun windowChanged() {
        if (!focused() && permission == null) cancel("cancelled")
    }
    private fun cancel(code: String) {
        epoch++
        deadline?.let(handler::removeCallbacks); deadline = null
        host.stop()
        val result = pending; pending = null
        val prompt = permission; permission = null
        result?.let { fail(it, code) }; prompt?.let { fail(it, code) }
    }
    private fun finish(generation: Int, text: String?, code: String?) {
        if (generation != epoch) return
        val result = pending ?: return
        pending = null
        deadline?.let(handler::removeCallbacks); deadline = null
        epoch++
        host.stop()
        if (!interactive()) fail(result, "cancelled")
        else if (code != null) fail(result, code)
        else result.success(mapOf("schemaVersion" to 1, "onDevice" to true, "text" to text))
    }
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (disposed) { fail(result, "unavailable"); return }
        try {
            when (call.method) {
                "probe" -> {
                    require(call.arguments == null)
                    result.success(mapOf("schemaVersion" to 1, "onDeviceAvailable" to host.available(), "microphoneGranted" to granted()))
                }
                "cancel" -> { require(call.arguments == null); cancel("cancelled"); result.success(null) }
                "requestPermission" -> {
                    require(call.arguments == null)
                    if (!interactive()) { fail(result, "cancelled"); return }
                    if (permission != null || pending != null) { fail(result, "busy"); return }
                    if (granted()) result.success(true)
                    else {
                        permission = result
                        deadline = Runnable { cancel("timeout") }.also { handler.postDelayed(it, 30_000) }
                        activity.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), REQUEST_MICROPHONE)
                    }
                }
                "recognize", "speak" -> {
                    val body = call.arguments as? Map<*, *> ?: throw IllegalArgumentException()
                    require(body.keys == if (call.method == "recognize") setOf("locale") else setOf("locale", "text"))
                    val locale = body["locale"] as? String ?: throw IllegalArgumentException()
                    require(locale in LOCALES)
                    val text = if (call.method == "speak") body["text"] as? String else null
                    if (call.method == "speak") require(text != null && AndroidLocalSpeechHost.validText(text))
                    if (!interactive()) { fail(result, "cancelled"); return }
                    if (permission != null || pending != null) { fail(result, "busy"); return }
                    if (call.method == "recognize" && !granted()) { fail(result, "permissionDenied"); return }
                    if (call.method == "recognize" && !host.available()) { fail(result, "modelUnavailable"); return }
                    pending = result
                    val generation = ++epoch
                    deadline = Runnable { cancel("timeout") }.also { handler.postDelayed(it, 30_000) }
                    if (call.method == "recognize") host.recognize(locale) { value, code ->
                        finish(generation, value, if (code == null && (value == null || !AndroidLocalSpeechHost.validText(value))) "invalidTranscript" else code)
                    } else host.speak(locale, text!!) { finish(generation, null, it) }
                }
                else -> result.notImplemented()
            }
        } catch (_: IllegalArgumentException) {
            val owned = pending === result || permission === result
            cancel("invalidRequest")
            if (!owned) fail(result, "invalidRequest")
        } catch (_: RuntimeException) {
            val owned = pending === result || permission === result
            cancel("unavailable")
            if (!owned) fail(result, "unavailable")
        }
    }
    fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray): Boolean {
        if (requestCode != REQUEST_MICROPHONE) return false
        val result = permission ?: return true
        permission = null
        deadline?.let(handler::removeCallbacks); deadline = null
        val allowed = permissions.contentEquals(arrayOf(Manifest.permission.RECORD_AUDIO)) &&
            grantResults.contentEquals(intArrayOf(PackageManager.PERMISSION_GRANTED))
        // Permission result itself never starts recording; a fresh user gesture is required.
        result.success(allowed)
        return true
    }
    fun dispose() { if (!disposed) { cancel("cancelled"); disposed = true; methods.setMethodCallHandler(null) } }
}
