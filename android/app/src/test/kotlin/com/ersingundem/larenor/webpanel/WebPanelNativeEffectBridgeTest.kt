package com.ersingundem.larenor.webpanel

import android.app.Application
import android.net.Uri
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class WebPanelNativeEffectBridgeTest {
    private val scope = effectScope()

    @Test
    fun speechRequiresExactCurrentResumedOwnerAndBoundedPayload() {
        val speech = RecordingSpeechHost()
        val runtime = WebPanelNativeEffectRuntime(speech, NoPrintHost, NoQrHost)
        runtime.setResumed(true)
        assertTrue(runtime.bind("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", scope))

        val accepted = runtime.execute(
            effectRequest(
                ownerId = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                method = "speak",
                payload = mapOf("text" to "Dinner is ready", "locale" to "en-US"),
            ),
        )
        assertEquals(NativeEffectOutcome.ACCEPTED, accepted.outcome)
        assertEquals(listOf("Dinner is ready" to "en-US"), speech.spoken)
        assertTrue(runtime.readback(accepted.receiptHandle!!, accepted.operationId))

        assertEquals(
            NativeEffectOutcome.REJECTED,
            runtime.execute(
                effectRequest(
                    ownerId = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                    method = "speak",
                    payload = mapOf("text" to "stale"),
                ),
            ).outcome,
        )
        runtime.setResumed(false)
        assertEquals(
            NativeEffectOutcome.REJECTED,
            runtime.execute(effectRequest(method = "speak", payload = mapOf("text" to "hidden"))).outcome,
        )
        runtime.setResumed(true)
        runtime.retire("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        assertEquals(
            NativeEffectOutcome.REJECTED,
            runtime.execute(effectRequest(method = "speak", payload = mapOf("text" to "retired"))).outcome,
        )
        assertEquals(2, speech.stopCalls)
    }

    @Test
    fun speechRejectsUnknownFieldsControlsAndOversizeWithoutSideEffect() {
        val speech = RecordingSpeechHost()
        val runtime = WebPanelNativeEffectRuntime(speech, NoPrintHost, NoQrHost)
        runtime.setResumed(true)
        runtime.bind("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", scope)

        for (payload in listOf(
            mapOf("text" to "ok", "token" to "private"),
            mapOf("text" to "line\nsecret"),
            mapOf("text" to "x".repeat(501)),
            mapOf("text" to "ok", "locale" to "en-us"),
        )) {
            assertEquals(
                NativeEffectOutcome.REJECTED,
                runtime.execute(effectRequest(method = "speak", payload = payload)).outcome,
            )
        }
        assertTrue(speech.spoken.isEmpty())
    }

    @Test
    fun replacementAndAuthorityRevisionRetireOldSpeechBeforeDispatch() {
        val speech = RecordingSpeechHost()
        val runtime = WebPanelNativeEffectRuntime(speech, NoPrintHost, NoQrHost)
        runtime.setResumed(true)
        runtime.bind("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", scope)
        assertTrue(
            runtime.bind(
                "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                scope.copy(policyRevision = 8),
            ),
        )
        assertFalse(runtime.readback("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "cccccccccccccccccccccccccccccccc"))
        assertEquals(
            NativeEffectOutcome.REJECTED,
            runtime.execute(effectRequest(method = "speak", payload = mapOf("text" to "old"))).outcome,
        )
        assertEquals(1, speech.stopCalls)
    }

    @Test
    fun printUsesOpaqueHandleAndOneVisibleBoundedPdfPicker() {
        val printer = RecordingPrintHost()
        val runtime = WebPanelNativeEffectRuntime(RecordingSpeechHost(), printer, NoQrHost)
        runtime.setResumed(true)
        runtime.bind("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", scope)

        val accepted = runtime.execute(
            effectRequest(
                method = "printDocument",
                payload = mapOf("documentHandle" to "monthly-report", "title" to "Monthly report"),
            ),
        )
        assertEquals(NativeEffectOutcome.ACCEPTED, accepted.outcome)
        assertEquals(listOf(Triple("monthly-report", "Monthly report", accepted.operationId)), printer.requests)
        assertEquals(
            NativeEffectOutcome.REJECTED,
            runtime.execute(
                effectRequest(
                    method = "printDocument",
                    payload = mapOf("documentHandle" to "content://private.invalid/report.pdf"),
                ),
            ).outcome,
        )
        runtime.setResumed(false)
        assertEquals(1, printer.cancelCalls)
    }

    @Test
    fun printSelectionAllowsOnlyBoundedContentPdfWithMagic() {
        assertTrue(
            WebPanelPrintSelection.valid(
                Uri.parse("content://documents.example/document/42"),
                "application/pdf",
                25L * 1024 * 1024,
                byteArrayOf(0x25, 0x50, 0x44, 0x46, 0x2d),
            ),
        )
        for ((uri, mime, size, magic) in listOf(
            arrayOf("https://private.invalid/report.pdf", "application/pdf", 20L, byteArrayOf(0x25, 0x50, 0x44, 0x46, 0x2d)),
            arrayOf("content://documents.example/document/42?token=private", "application/pdf", 20L, byteArrayOf(0x25, 0x50, 0x44, 0x46, 0x2d)),
            arrayOf("content://documents.example/document/42", "text/html", 20L, byteArrayOf(0x25, 0x50, 0x44, 0x46, 0x2d)),
            arrayOf("content://documents.example/document/42", "application/pdf", 25L * 1024 * 1024 + 1, byteArrayOf(0x25, 0x50, 0x44, 0x46, 0x2d)),
            arrayOf("content://documents.example/document/42", "application/pdf", 20L, byteArrayOf(0x3c, 0x68, 0x74, 0x6d, 0x6c)),
        )) {
            assertFalse(WebPanelPrintSelection.valid(Uri.parse(uri as String), mime as String, size as Long, magic as ByteArray))
        }
    }
}

private class RecordingSpeechHost : WebPanelSpeechHost {
    val spoken = mutableListOf<Pair<String, String?>>()
    var stopCalls = 0
    override fun speak(text: String, locale: String?, receipt: String): Boolean {
        spoken += text to locale
        return true
    }
    override fun stop() { stopCalls++ }
    override fun close() = Unit
}

private object NoPrintHost : WebPanelPrintHost {
    override fun print(handle: String, title: String?, receipt: String): Boolean = false
    override fun cancel() = Unit
    override fun close() = Unit
}

private class RecordingPrintHost : WebPanelPrintHost {
    val requests = mutableListOf<Triple<String, String?, String>>()
    var cancelCalls = 0
    override fun print(handle: String, title: String?, receipt: String): Boolean {
        requests += Triple(handle, title, receipt)
        return true
    }
    override fun cancel() { cancelCalls++ }
    override fun close() = Unit
}

private object NoQrHost : WebPanelQrHost {
    override fun scan(formats: Set<String>, receipt: String): Boolean = false
    override fun cancel() = Unit
    override fun close() = Unit
}

private fun effectScope() = WebPanelEffectScope(
    coreId = "11111111111111111111111111111111",
    homeId = "22222222222222222222222222222222",
    accountId = "member-1",
    sessionFamily = "33333333333333333333333333333333",
    sourceId = "dashboard.tile",
    sourceRevision = 4,
    policyRevision = 7,
    routeEpoch = 2,
    lifecycleEpoch = 2,
    topOrigin = "https://panel.example",
)

private fun effectRequest(
    ownerId: String = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    method: String,
    payload: Map<String, Any?>,
) = WebPanelEffectRequest(
    ownerId = ownerId,
    operationId = "cccccccccccccccccccccccccccccccc",
    method = method,
    payload = payload,
    scope = effectScope(),
)
