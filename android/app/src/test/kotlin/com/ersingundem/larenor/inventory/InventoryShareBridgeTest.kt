package com.ersingundem.larenor.inventory

import android.app.Activity
import android.app.Application
import android.content.Intent
import android.content.pm.PackageManager
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.io.File
import java.nio.ByteBuffer

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class InventoryShareBridgeTest {
    private class Messenger : BinaryMessenger {
        override fun send(channel: String, message: ByteBuffer?) {}
        override fun send(
            channel: String,
            message: ByteBuffer?,
            callback: BinaryMessenger.BinaryReply?,
        ) {}
        override fun setMessageHandler(
            channel: String,
            handler: BinaryMessenger.BinaryMessageHandler?,
        ) {}
    }

    private class Result : MethodChannel.Result {
        var value: Any? = null
        var code: String? = null
        override fun success(result: Any?) { value = result }
        override fun error(code: String, message: String?, details: Any?) {
            this.code = code
            assertEquals("Inventory export unavailable", message)
            assertNull(details)
        }
        override fun notImplemented() { code = "missing" }
    }

    @Test
    fun explicitCurrentActionSharesOneBoundedInternalSvg() {
        val controller = Robolectric.buildActivity(Activity::class.java)
            .setup().visible().windowFocusChanged(true)
        val activity = controller.get()
        val bridge = InventoryShareBridge(activity, Messenger())
        fun call(method: String, args: Any? = null) =
            Result().also { bridge.onMethodCall(MethodCall(method, args), it) }
        try {
            bridge.setResumed(true)
            assertNull(call("activateSession", mapOf("sessionId" to "inventory-session-1")).code)
            val snapshot = call("snapshot").value as Map<*, *>
            val svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 1 1\"><path fill=\"#000\" d=\"M0 0h1v1H0z\"/></svg>"
            val request = mapOf(
                "sessionId" to "inventory-session-1",
                "interactionEpoch" to snapshot["interactionEpoch"],
                "fileName" to "larenor-inventory-${"a".repeat(32)}.svg",
                "mimeType" to "image/svg+xml",
                "svg" to svg,
            )
            assertNull(call("shareSvg", request).code)
            val chooser = shadowOf(activity).nextStartedActivity
            assertEquals(Intent.ACTION_CHOOSER, chooser.action)
            val send = chooser.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)!!
            assertEquals(Intent.ACTION_SEND, send.action)
            assertEquals("image/svg+xml", send.type)
            assertTrue(send.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0)
            val uri = send.getParcelableExtra<android.net.Uri>(Intent.EXTRA_STREAM)!!
            assertEquals("content", uri.scheme)
            assertTrue(uri.path!!.startsWith("/inventory_exports/"))
            val exported = File(activity.cacheDir, "inventory_exports/share/${request["fileName"]}")
            assertEquals(svg, exported.readText())
            assertEquals("busy", call("shareSvg", request).code)

            bridge.setResumed(false)
            assertEquals("expired", call("shareSvg", request).code)
            assertNull(shadowOf(activity).nextStartedActivity)
        } finally {
            bridge.dispose()
            controller.pause().stop().destroy()
        }
    }

    @Test
    fun providerAndParserRejectPrivateTraversalActiveOrOversizedContent() {
        val controller = Robolectric.buildActivity(Activity::class.java).setup()
        val activity = controller.get()
        try {
            val provider = activity.packageManager.resolveContentProvider(
                "${activity.packageName}.inventory_exports",
                PackageManager.GET_META_DATA,
            )!!
            assertFalse(provider.exported)
            assertTrue(provider.grantUriPermissions)
            val allowed = File(activity.cacheDir, "inventory_exports/share/larenor-inventory-${"b".repeat(32)}.svg")
            allowed.parentFile!!.mkdirs()
            allowed.writeText("<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>")
            assertTrue(
                FileProvider.getUriForFile(activity, provider.authority, allowed)
                    .path!!.startsWith("/inventory_exports/"),
            )
            for (file in listOf(
                File(activity.cacheDir, "client_updates/install/private.apk"),
                File(activity.cacheDir, "outside.svg"),
            )) {
                try {
                    FileProvider.getUriForFile(activity, provider.authority, file)
                    fail("Private path was exposed")
                } catch (_: IllegalArgumentException) {}
            }

            val base = mapOf(
                "sessionId" to "inventory-session-1",
                "interactionEpoch" to 1,
                "fileName" to "larenor-inventory-${"a".repeat(32)}.svg",
                "mimeType" to "image/svg+xml",
            )
            for (bad in listOf(
                base + ("fileName" to "../private.svg") + ("svg" to "<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>"),
                base + ("svg" to "<svg xmlns=\"http://www.w3.org/2000/svg\"><script/></svg>"),
                base + ("svg" to "x".repeat(256001)),
            )) {
                try {
                    InventoryShareRequest.parse(bad)
                    fail("Unsafe export was accepted")
                } catch (_: InventoryShareFailure) {}
            }
        } finally {
            controller.pause().stop().destroy()
        }
    }
}
