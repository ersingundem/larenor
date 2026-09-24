package com.ersingundem.larenor.webpanel

import android.net.Uri
import androidx.webkit.JavaScriptReplyProxy
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class WebPanelNativeMessageBridgeTest {
    private class Reply : JavaScriptReplyProxy() {
        val strings = mutableListOf<String>()
        override fun postMessage(message: String) { strings += message }
        override fun postMessage(message: ByteArray) = Unit
    }

    @Test
    fun versionOnePolicyRequiresExactHttpsOriginAndClosedMethods() {
        val policy = WebPanelNativeMessagePolicy.parse(
            mapOf(
                "schemaVersion" to 1,
                "revision" to 7,
                "topOrigin" to "https://panel.invalid",
                "methods" to listOf("speak", "scanQr"),
            ),
        )
        assertEquals(7, policy.revision)
        assertEquals("https://panel.invalid", policy.topOrigin)
        assertEquals(setOf("speak", "scanQr"), policy.methods)

        listOf(
            mapOf(
                "schemaVersion" to 2,
                "revision" to 7,
                "topOrigin" to "https://panel.invalid",
                "methods" to listOf("speak"),
            ),
            mapOf(
                "schemaVersion" to 1,
                "revision" to 7,
                "topOrigin" to "http://panel.invalid",
                "methods" to listOf("speak"),
            ),
            mapOf(
                "schemaVersion" to 1,
                "revision" to 7,
                "topOrigin" to "https://panel.invalid/path",
                "methods" to listOf("speak"),
            ),
            mapOf(
                "schemaVersion" to 1,
                "revision" to 7,
                "topOrigin" to "https://panel.invalid",
                "methods" to listOf("shell"),
            ),
        ).forEach { value ->
            assertThrows(RendererRequestFailure::class.java) {
                WebPanelNativeMessagePolicy.parse(value)
            }
        }
    }

    @Test
    fun exactMainFrameForwardsBoundedStringAndReplyIsOneShot() {
        val seen = mutableListOf<WebPanelNativeMessageEvent>()
        val attachment = WebPanelNativeMessageAttachment(
            attachmentId = "0123456789abcdef0123456789abcdef",
            policy = policy(),
            dispatch = seen::add,
        )
        val reply = Reply()

        attachment.onMessage(
            "{\"schemaVersion\":1}",
            Uri.parse("https://panel.invalid"),
            mainFrame = true,
            reply = reply,
        )

        val event = seen.single()
        assertEquals("{\"schemaVersion\":1}", event.message)
        assertEquals("https://panel.invalid", event.topOrigin)
        assertTrue(attachment.reply(event.messageId, "{\"status\":\"denied\"}"))
        assertEquals(listOf("{\"status\":\"denied\"}"), reply.strings)
        assertFalse(attachment.reply(event.messageId, "{}"))
    }

    @Test
    fun iframeDowngradeForeignAndOversizeMessagesNeverDispatch() {
        val seen = mutableListOf<WebPanelNativeMessageEvent>()
        val attachment = WebPanelNativeMessageAttachment(
            attachmentId = "0123456789abcdef0123456789abcdef",
            policy = policy(),
            dispatch = seen::add,
        )
        val reply = Reply()
        attachment.onMessage("{}", Uri.parse("https://panel.invalid"), false, reply)
        attachment.onMessage("{}", Uri.parse("http://panel.invalid"), true, reply)
        attachment.onMessage("{}", Uri.parse("https://foreign.invalid"), true, reply)
        attachment.onMessage("x".repeat(8193), Uri.parse("https://panel.invalid"), true, reply)
        assertTrue(seen.isEmpty())
        assertTrue(reply.strings.isEmpty())
    }

    @Test
    fun pendingRepliesAreBoundedAndDetachRevokesLateMessages() {
        val seen = mutableListOf<WebPanelNativeMessageEvent>()
        val attachment = WebPanelNativeMessageAttachment(
            attachmentId = "0123456789abcdef0123456789abcdef",
            policy = policy(),
            dispatch = seen::add,
        )
        repeat(129) {
            attachment.onMessage(
                "{}",
                Uri.parse("https://panel.invalid"),
                true,
                Reply(),
            )
        }
        assertEquals(128, seen.size)
        val pending = seen.last().messageId
        attachment.close()
        assertFalse(attachment.reply(pending, "{}"))
        attachment.onMessage("{}", Uri.parse("https://panel.invalid"), true, Reply())
        assertEquals(128, seen.size)
    }

    private fun policy() = WebPanelNativeMessagePolicy.parse(
        mapOf(
            "schemaVersion" to 1,
            "revision" to 7,
            "topOrigin" to "https://panel.invalid",
            "methods" to listOf("speak"),
        ),
    )
}
