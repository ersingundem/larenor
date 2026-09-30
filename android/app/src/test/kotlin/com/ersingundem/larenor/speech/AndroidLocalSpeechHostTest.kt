package com.ersingundem.larenor.speech

import android.app.Activity
import android.app.Application
import android.content.Intent
import android.os.Bundle
import android.os.Looper
import android.speech.RecognitionSupport
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.speech.tts.TextToSpeech
import android.speech.tts.Voice
import java.util.Locale
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows
import org.robolectric.annotation.Config
import org.robolectric.annotation.Implementation
import org.robolectric.annotation.Implements
import org.robolectric.shadows.ShadowSpeechRecognizer
import org.robolectric.shadows.ShadowSpeechRecognizerProxy
import org.robolectric.shadows.ShadowTextToSpeech

@Implements(
    className = "android.speech.SpeechRecognizerProxy",
    isInAndroidSdk = false,
)
class ThrowingStartSpeechRecognizer : ShadowSpeechRecognizerProxy() {
    @Implementation
    override fun startListening(recognizerIntent: Intent) {
        throw IllegalStateException("synthetic provider failure")
    }
}

@Implements(TextToSpeech::class)
class ThrowingVoiceTextToSpeech : ShadowTextToSpeech() {
    @Implementation
    override fun setVoice(voice: Voice): Int {
        throw IllegalStateException("synthetic voice failure")
    }
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class AndroidLocalSpeechHostTest {
    @Before fun reset() {
        ShadowSpeechRecognizer.reset()
        ShadowTextToSpeech.reset()
    }

    @After fun clean() {
        ShadowSpeechRecognizer.reset()
        ShadowTextToSpeech.reset()
    }

    @Test fun recognitionRequiresAnInstalledOnDeviceLanguageAndPinsOfflineIntent() {
        ShadowSpeechRecognizer.setIsOnDeviceRecognitionAvailable(true)
        val controller = Robolectric.buildActivity(Activity::class.java).setup()
        val host = AndroidLocalSpeechHost(controller.get())
        var value: String? = null
        var failure: String? = null
        try {
            host.recognize("tr-TR") { text, code -> value = text; failure = code }
            val engine = ShadowSpeechRecognizer.getLatestSpeechRecognizer()
            val shadow = Shadows.shadowOf(engine) as ShadowSpeechRecognizer
            shadow.triggerSupportResult(RecognitionSupport.Builder()
                .addInstalledOnDeviceLanguage("tr-TR")
                .addOnlineLanguage("en-US")
                .build())
            Shadows.shadowOf(Looper.getMainLooper()).idle()

            val intent = shadow.lastRecognizerIntent
            assertEquals(RecognizerIntent.ACTION_RECOGNIZE_SPEECH, intent.action)
            assertEquals("tr-TR", intent.getStringExtra(RecognizerIntent.EXTRA_LANGUAGE))
            assertTrue(intent.getBooleanExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, false))
            assertFalse(intent.getBooleanExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true))
            assertEquals(1, intent.getIntExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 0))

            shadow.triggerOnResults(Bundle().apply {
                putStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION, arrayListOf("  ışığı aç  "))
            })
            assertEquals("ışığı aç", value)
            assertNull(failure)
            assertTrue(shadow.isDestroyed)
        } finally {
            host.stop()
            controller.pause().stop().destroy()
        }
    }

    @Test fun onlineOnlyRecognitionLanguageIsRejectedBeforeListening() {
        ShadowSpeechRecognizer.setIsOnDeviceRecognitionAvailable(true)
        val controller = Robolectric.buildActivity(Activity::class.java).setup()
        val host = AndroidLocalSpeechHost(controller.get())
        var failure: String? = null
        try {
            host.recognize("en-US") { _, code -> failure = code }
            val shadow = Shadows.shadowOf(
                ShadowSpeechRecognizer.getLatestSpeechRecognizer(),
            ) as ShadowSpeechRecognizer
            shadow.triggerSupportResult(RecognitionSupport.Builder()
                .addOnlineLanguage("en-US")
                .addInstalledOnDeviceLanguage("tr-TR")
                .build())
            Shadows.shadowOf(Looper.getMainLooper()).idle()
            assertEquals("modelUnavailable", failure)
            assertNull(shadow.lastRecognizerIntent)
            assertTrue(shadow.isDestroyed)
        } finally {
            host.stop()
            controller.pause().stop().destroy()
        }
    }

    @Test @Config(shadows = [ThrowingStartSpeechRecognizer::class])
    fun asyncRecognitionProviderFailureIsTerminalAndDestroysTheEngine() {
        ShadowSpeechRecognizer.setIsOnDeviceRecognitionAvailable(true)
        val controller = Robolectric.buildActivity(Activity::class.java).setup()
        val host = AndroidLocalSpeechHost(controller.get())
        var calls = 0
        var failure: String? = null
        try {
            host.recognize("en-US") { _, code -> calls++; failure = code }
            val shadow = Shadows.shadowOf(
                ShadowSpeechRecognizer.getLatestSpeechRecognizer(),
            ) as ShadowSpeechRecognizer
            shadow.triggerSupportResult(RecognitionSupport.Builder()
                .addInstalledOnDeviceLanguage("en-US")
                .build())
            Shadows.shadowOf(Looper.getMainLooper()).idle()
            assertEquals("unavailable", failure)
            assertEquals(1, calls)
            assertTrue(shadow.isDestroyed)
        } finally {
            host.stop()
            controller.pause().stop().destroy()
        }
    }

    @Test fun textToSpeechSelectsAnInstalledNonNetworkVoiceAndWaitsForDone() {
        val network = Voice(
            "en-network", Locale.US, Voice.QUALITY_HIGH, Voice.LATENCY_NORMAL,
            true, emptySet(),
        )
        val missing = Voice(
            "en-missing", Locale.US, Voice.QUALITY_HIGH, Voice.LATENCY_NORMAL,
            false, setOf(TextToSpeech.Engine.KEY_FEATURE_NOT_INSTALLED),
        )
        val local = Voice(
            "en-local", Locale.US, Voice.QUALITY_NORMAL, Voice.LATENCY_NORMAL,
            false, emptySet(),
        )
        ShadowTextToSpeech.addVoice(network)
        ShadowTextToSpeech.addVoice(missing)
        ShadowTextToSpeech.addVoice(local)
        val controller = Robolectric.buildActivity(Activity::class.java).setup()
        val host = AndroidLocalSpeechHost(controller.get())
        var calls = 0
        var failure: String? = "pending"
        try {
            host.speak("en-US", "Local preview") { code -> calls++; failure = code }
            val engine = ShadowTextToSpeech.getLastTextToSpeechInstance()
            val shadow = Shadows.shadowOf(engine) as ShadowTextToSpeech
            shadow.onInitListener.onInit(TextToSpeech.SUCCESS)
            Shadows.shadowOf(Looper.getMainLooper()).idle()
            assertEquals(local, shadow.currentVoice)
            assertEquals("Local preview", shadow.lastSpokenText)
            assertEquals(1, calls)
            assertNull(failure)
            assertTrue(shadow.isShutdown)
        } finally {
            host.stop()
            controller.pause().stop().destroy()
        }
    }

    @Test fun networkOrUninstalledVoicesNeverProduceSpeech() {
        ShadowTextToSpeech.addVoice(Voice(
            "tr-network", Locale.forLanguageTag("tr-TR"), Voice.QUALITY_HIGH,
            Voice.LATENCY_NORMAL, true, emptySet(),
        ))
        ShadowTextToSpeech.addVoice(Voice(
            "tr-missing", Locale.forLanguageTag("tr-TR"), Voice.QUALITY_HIGH,
            Voice.LATENCY_NORMAL, false,
            setOf(TextToSpeech.Engine.KEY_FEATURE_NOT_INSTALLED),
        ))
        val controller = Robolectric.buildActivity(Activity::class.java).setup()
        val host = AndroidLocalSpeechHost(controller.get())
        var failure: String? = null
        try {
            host.speak("tr-TR", "Yerel önizleme") { failure = it }
            val shadow = Shadows.shadowOf(
                ShadowTextToSpeech.getLastTextToSpeechInstance(),
            ) as ShadowTextToSpeech
            shadow.onInitListener.onInit(TextToSpeech.SUCCESS)
            Shadows.shadowOf(Looper.getMainLooper()).idle()
            assertEquals("voiceUnavailable", failure)
            assertNull(shadow.lastSpokenText)
            assertTrue(shadow.isShutdown)
        } finally {
            host.stop()
            controller.pause().stop().destroy()
        }
    }

    @Test @Config(shadows = [ThrowingVoiceTextToSpeech::class])
    fun asyncVoiceProviderFailureIsTerminalAndShutsDownTheEngine() {
        ShadowTextToSpeech.addVoice(Voice(
            "en-local", Locale.US, Voice.QUALITY_NORMAL, Voice.LATENCY_NORMAL,
            false, emptySet(),
        ))
        val controller = Robolectric.buildActivity(Activity::class.java).setup()
        val host = AndroidLocalSpeechHost(controller.get())
        var calls = 0
        var failure: String? = null
        try {
            host.speak("en-US", "Local preview") { code -> calls++; failure = code }
            val shadow = Shadows.shadowOf(
                ShadowTextToSpeech.getLastTextToSpeechInstance(),
            ) as ShadowTextToSpeech
            shadow.onInitListener.onInit(TextToSpeech.SUCCESS)
            Shadows.shadowOf(Looper.getMainLooper()).idle()
            assertEquals("unavailable", failure)
            assertEquals(1, calls)
            assertNull(shadow.lastSpokenText)
            assertTrue(shadow.isShutdown)
        } finally {
            host.stop()
            controller.pause().stop().destroy()
        }
    }
}
