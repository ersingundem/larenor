package com.ersingundem.larenor.kiosk

import android.app.Activity
import android.app.PendingIntent
import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.nfc.NfcAdapter
import android.nfc.Tag
import android.nfc.tech.Ndef
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.print.PrintManager
import android.speech.tts.TextToSpeech
import android.util.Base64
import android.view.InputDevice
import android.view.KeyEvent
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.MessageDigest
import java.security.SecureRandom

/**
 * Local, review-only peripheral bridge.
 *
 * NFC and external HID input are armed only by an explicit Flutter request.
 * TTS and print advertise the platform workers already used by K08. QR and BLE
 * remain fail-closed until a dedicated verified worker is connected.
 */
class KioskPeripheralBridge(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, "com.ersingundem.larenor/kiosk_peripherals")
    private val handler = Handler(Looper.getMainLooper())
    private val random = SecureRandom()
    private val nfc = NfcAdapter.getDefaultAdapter(activity)
    private var disposed = false
    private var resumed = false
    private var focused = false
    private var inventoryRevision = 1
    private var inventoryDigest: String? = null
    private var pending: PendingInput? = null
    private val sequences = mutableMapOf<String, Int>()
    private val duplicateDigests = mutableMapOf<String, Pair<String, Long>>()

    init { channel.setMethodCallHandler(this) }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (disposed) {
            result.error("unavailable", "Peripheral state unavailable", null)
            return
        }
        when (call.method) {
            "capabilities" -> {
                if (call.arguments != null) invalid(result) else result.success(capabilities())
            }
            "takeNextInput" -> arm(call.arguments, result)
            else -> result.notImplemented()
        }
    }

    fun setResumed(value: Boolean) {
        resumed = value
        if (!value) cancelPending("retired")
    }

    fun setWindowFocused(value: Boolean) {
        focused = value
        if (!value) cancelPending("retired")
    }

    fun onNewIntent(intent: Intent) {
        val current = pending ?: return
        if (current.providerId != NFC_PROVIDER || !current.current()) return
        if (intent.action !in setOf(
                NfcAdapter.ACTION_NDEF_DISCOVERED,
                NfcAdapter.ACTION_TECH_DISCOVERED,
                NfcAdapter.ACTION_TAG_DISCOVERED,
            )
        ) return
        val tag = if (Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra(NfcAdapter.EXTRA_TAG, Tag::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(NfcAdapter.EXTRA_TAG) as? Tag
        } ?: return
        val message = runCatching { Ndef.get(tag)?.cachedNdefMessage }.getOrNull() ?: return
        val record = message.records.firstOrNull() ?: return
        val encoded = Base64.encodeToString(record.payload, Base64.NO_WRAP or Base64.URL_SAFE)
        if (encoded.isBlank()) return
        finish(current, "ndef:$encoded")
    }

    fun onKeyEvent(event: KeyEvent) {
        val current = pending ?: return
        if (current.providerId != USB_PROVIDER || !current.current()) return
        if (event.action != KeyEvent.ACTION_DOWN || event.repeatCount != 0) return
        val device = InputDevice.getDevice(event.deviceId) ?: return
        if (!device.isExternal || device.sources and InputDevice.SOURCE_KEYBOARD == 0) return
        if (event.isAltPressed || event.isCtrlPressed || event.isMetaPressed) {
            cancelPending("invalid_input")
            return
        }
        when (event.keyCode) {
            KeyEvent.KEYCODE_ESCAPE -> cancelPending("cancelled")
            KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_NUMPAD_ENTER -> {
                if (current.buffer.isNotEmpty()) finish(current, current.buffer.toString())
            }
            else -> {
                val code = event.unicodeChar
                if (code !in 0x20..0x7e || current.buffer.length >= 512) {
                    cancelPending("invalid_input")
                } else {
                    current.buffer.append(code.toChar())
                }
            }
        }
    }

    private fun arm(arguments: Any?, result: MethodChannel.Result) {
        val value = arguments as? Map<*, *> ?: return invalid(result)
        val expected = setOf(
            "providerId", "deviceRevision", "policyRevision", "sessionEpoch",
            "routeEpoch", "lifecycleEpoch",
        )
        if (value.size != expected.size || value.keys.any { it !is String || it !in expected }) {
            invalid(result)
            return
        }
        val providerId = value["providerId"] as? String ?: return invalid(result)
        val authorityKeys = expected - "providerId"
        val authority = authorityKeys.associateWith { key ->
            positiveInt(value[key]) ?: return invalid(result)
        }
        if (!resumed || !focused || providerId !in setOf(NFC_PROVIDER, USB_PROVIDER)) {
            result.error("unavailable", "Peripheral input unavailable", null)
            return
        }
        val provider = providerFacts().singleOrNull { it.providerId == providerId }
        if (provider == null || !provider.supported || !provider.connected || provider.permission != "notRequired") {
            result.error("unavailable", "Peripheral input unavailable", null)
            return
        }
        cancelPending("replaced")
        val pendingInput = PendingInput(providerId, authority, result)
        pending = pendingInput
        if (providerId == NFC_PROVIDER) enableNfcDispatch()
        handler.postDelayed({
            if (pending === pendingInput) cancelPending("timeout")
        }, INPUT_TIMEOUT_MS)
    }

    private fun finish(current: PendingInput, payload: String) {
        if (pending !== current || !current.current()) return
        val bytes = payload.toByteArray(Charsets.UTF_8)
        if (bytes.isEmpty() || bytes.size > current.maxPayloadBytes()) {
            cancelPending("invalid_input")
            return
        }
        val now = SystemClock.elapsedRealtime()
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes).toHex()
        val previous = duplicateDigests[current.providerId]
        if (previous != null && previous.first == digest && now - previous.second <= DUPLICATE_WINDOW_MS) {
            cancelPending("duplicate_input")
            return
        }
        duplicateDigests[current.providerId] = digest to now
        pending = null
        disableNfcDispatch()
        val sequence = (sequences[current.providerId] ?: 0) + 1
        sequences[current.providerId] = sequence
        val kind = if (current.providerId == NFC_PROVIDER) "nfc" else "usb"
        current.result.success(
            mapOf(
                "input" to mapOf(
                    "schemaVersion" to 1,
                    "eventId" to randomId(),
                    "providerId" to current.providerId,
                    "kind" to kind,
                    "capabilityRevision" to inventoryRevision,
                    "deviceRevision" to current.authority.getValue("deviceRevision"),
                    "policyRevision" to current.authority.getValue("policyRevision"),
                    "sessionEpoch" to current.authority.getValue("sessionEpoch"),
                    "routeEpoch" to current.authority.getValue("routeEpoch"),
                    "lifecycleEpoch" to current.authority.getValue("lifecycleEpoch"),
                    "sequence" to sequence,
                    "capturedAtElapsedMs" to now,
                    "payload" to payload,
                ),
                "nowElapsedMs" to SystemClock.elapsedRealtime(),
            ),
        )
    }

    private fun PendingInput.current() = pending === this && !disposed && resumed && focused

    private fun PendingInput.maxPayloadBytes() =
        if (providerId == NFC_PROVIDER) 4096 else 512

    private fun capabilities(): Map<String, Any?> {
        val facts = providerFacts()
        val digest = facts.joinToString("|") { it.digest }
        if (inventoryDigest != null && inventoryDigest != digest && inventoryRevision < Int.MAX_VALUE) {
            inventoryRevision += 1
        }
        inventoryDigest = digest
        return mapOf(
            "schemaVersion" to 1,
            "gmsAvailable" to false,
            "inventory" to mapOf(
                "schemaVersion" to 1,
                "inventoryRevision" to inventoryRevision,
                "providers" to facts.map { it.public(inventoryRevision) },
            ),
        )
    }

    private fun providerFacts(): List<ProviderFacts> {
        val manager = activity.packageManager
        val cameraSupported = manager.hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY)
        val cameraPermission = if (
            activity.checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
        ) "granted" else "unknown"
        val nfcSupported = nfc != null && manager.hasSystemFeature(PackageManager.FEATURE_NFC)
        val usbSupported = manager.hasSystemFeature(PackageManager.FEATURE_USB_HOST)
        val externalKeyboard = InputDevice.getDeviceIds().any { id ->
            InputDevice.getDevice(id)?.let { device ->
                device.isExternal && device.sources and InputDevice.SOURCE_KEYBOARD != 0
            } == true
        }
        val ttsSupported = manager.queryIntentServices(
            Intent(TextToSpeech.Engine.INTENT_ACTION_TTS_SERVICE),
            0,
        ).isNotEmpty()
        val printSupported = activity.getSystemService(Context.PRINT_SERVICE) is PrintManager
        return listOf(
            ProviderFacts("qr.camera", "qr", cameraSupported, cameraPermission, cameraSupported, 4096),
            ProviderFacts(NFC_PROVIDER, "nfc", nfcSupported, "notRequired", nfc?.isEnabled == true, 4096),
            ProviderFacts("ble.gatt", "ble", false, "unknown", false, 4096),
            ProviderFacts(USB_PROVIDER, "usb", usbSupported, "notRequired", externalKeyboard, 512),
            ProviderFacts("tts.system", "tts", ttsSupported, "notRequired", ttsSupported, 0),
            ProviderFacts("print.system", "print", printSupported, "notRequired", printSupported, 0),
        )
    }

    private fun enableNfcDispatch() {
        val adapter = nfc ?: return
        val intent = Intent(activity, activity.javaClass).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0
        runCatching {
            adapter.enableForegroundDispatch(
                activity,
                PendingIntent.getActivity(activity, NFC_REQUEST_CODE, intent, flags),
                null,
                null,
            )
        }
    }

    private fun disableNfcDispatch() {
        if (resumed) runCatching { nfc?.disableForegroundDispatch(activity) }
    }

    private fun cancelPending(reason: String) {
        val previous = pending ?: return
        pending = null
        disableNfcDispatch()
        previous.buffer.clear()
        previous.result.error(reason, "Peripheral input unavailable", null)
    }

    fun dispose() {
        if (disposed) return
        disposed = true
        cancelPending("retired")
        channel.setMethodCallHandler(null)
    }

    private fun randomId(): String = ByteArray(16).also(random::nextBytes).toHex()

    private fun invalid(result: MethodChannel.Result) {
        result.error("invalid", "Peripheral state unavailable", null)
    }

    private data class PendingInput(
        val providerId: String,
        val authority: Map<String, Int>,
        val result: MethodChannel.Result,
        val buffer: StringBuilder = StringBuilder(),
    )

    private data class ProviderFacts(
        val providerId: String,
        val kind: String,
        val supported: Boolean,
        val permission: String,
        val connected: Boolean,
        val maxPayloadBytes: Int,
    ) {
        val digest = "$providerId:$supported:$permission:$connected:$maxPayloadBytes"
        fun public(revision: Int) = mapOf(
            "providerId" to providerId,
            "kind" to kind,
            "revision" to revision,
            "supported" to supported,
            "enabledByUser" to false,
            "permission" to permission,
            "connected" to connected,
            "requiresGms" to false,
            "maxPayloadBytes" to maxPayloadBytes,
        )
    }

    private companion object {
        const val NFC_PROVIDER = "nfc.ndef"
        const val USB_PROVIDER = "usb.hid"
        const val NFC_REQUEST_CODE = 48731
        const val INPUT_TIMEOUT_MS = 15_000L
        const val DUPLICATE_WINDOW_MS = 2_000L

        fun positiveInt(value: Any?): Int? = when (value) {
            is Int -> value.takeIf { it > 0 }
            is Long -> value.takeIf { it in 1..Int.MAX_VALUE.toLong() }?.toInt()
            else -> null
        }

        fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }
    }
}
