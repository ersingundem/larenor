package com.ersingundem.larenor.updater

import android.app.Activity
import android.app.Application
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.content.pm.Signature
import android.content.pm.SigningInfo
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
@Config(sdk=[35], application=Application::class)
class ClientUpdaterBridgeTest {
    private class Messenger: BinaryMessenger {
        override fun send(channel: String, message: ByteBuffer?) {}
        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) {}
        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {}
    }
    private class Result: MethodChannel.Result {
        var value: Any? = null; var code: String? = null
        override fun success(result: Any?) { value = result }
        override fun error(code: String, message: String?, details: Any?) { this.code = code; assertEquals("Client update unavailable", message); assertNull(details) }
        override fun notImplemented() { code = "missing" }
    }
    @Test fun nativeEpochRejectsQueuedPermissionAfterPauseResumeButFreshActionWorksOnce() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().visible().windowFocusChanged(true)
        val app = activity.get()
        val signing = SigningInfo(); shadowOf(signing).setSignatures(arrayOf(Signature("aa".repeat(32))))
        val info = PackageInfo().apply { packageName = app.packageName; longVersionCode = 19; versionName = "1.9"; signingInfo = signing }
        shadowOf(app.packageManager).installPackage(info)
        val bridge = ClientUpdaterBridge(app, Messenger())
        fun call(method: String, args: Any? = null): Result = Result().also { bridge.onMethodCall(MethodCall(method, args), it) }
        try {
            bridge.setResumed(true)
            assertNull(call("activateSession", mapOf("sessionId" to "synthetic-session-one")).code)
            val first = call("snapshot").value as Map<*, *>
            assertEquals(10, first.size); assertEquals(true, first["supported"])
            bridge.setResumed(false); bridge.setResumed(true)
            val stale = mapOf("sessionId" to "synthetic-session-one", "interactionEpoch" to first["interactionEpoch"])
            assertEquals("expired", call("openInstallPermission", stale).code)
            assertNull(shadowOf(app).nextStartedActivity)
            val current = call("snapshot").value as Map<*, *>
            val fresh = mapOf("sessionId" to "synthetic-session-one", "interactionEpoch" to current["interactionEpoch"])
            assertNull(call("openInstallPermission", fresh).code)
            val launched = shadowOf(app).nextStartedActivity
            assertEquals(android.provider.Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, launched.action)
            assertEquals("package:${app.packageName}", launched.data.toString())
            assertEquals("busy", call("openInstallPermission", fresh).code)
            assertNull(shadowOf(app).nextStartedActivity)
            assertEquals("expired", call("openInstallPermission", fresh + ("sessionId" to "wrong-old-session")).code)
            // DeX can keep both Activities resumed. A focus roundtrip is enough
            // to permit a new explicit settings action, never an automatic one.
            activity.windowFocusChanged(false); bridge.windowChanged()
            activity.windowFocusChanged(true); bridge.windowChanged()
            assertNull(shadowOf(app).nextStartedActivity)
            val afterFocus = call("snapshot").value as Map<*, *>
            assertEquals("expired", call("openInstallPermission", fresh).code)
            assertNull(call("openInstallPermission", fresh + ("interactionEpoch" to afterFocus["interactionEpoch"])).code)
            assertEquals(android.provider.Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, shadowOf(app).nextStartedActivity.action)
        } finally { bridge.dispose(); activity.pause().stop().destroy() }
    }
    @Test fun fileProviderExposesOnlyVerifiedDirectoryAndIsNotExported() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup()
        val app = activity.get()
        try {
            val provider = app.packageManager.resolveContentProvider("${app.packageName}.client_updates", PackageManager.GET_META_DATA)!!
            assertFalse(provider.exported); assertTrue(provider.grantUriPermissions)
            val verified = File(app.cacheDir, "client_updates/install/00000000-0000-4000-8000-000000000000.apk")
            verified.parentFile!!.mkdirs(); verified.writeText("synthetic")
            val uri = FileProvider.getUriForFile(app, provider.authority, verified)
            assertEquals("content", uri.scheme); assertTrue(uri.path!!.startsWith("/verified_updates/"))
            for (path in listOf("client_updates/incoming/not-verified.part", "shared_prefs/private.xml", "outside.apk")) {
                try { FileProvider.getUriForFile(app, provider.authority, File(app.cacheDir, path)); fail("Unverified/private path was exposed") }
                catch (_: IllegalArgumentException) {}
            }
            val packageInfo = app.packageManager.getPackageInfo(app.packageName, PackageManager.GET_PERMISSIONS)
            assertEquals(true, packageInfo.requestedPermissions?.contains("android.permission.REQUEST_INSTALL_PACKAGES"))
        } finally { activity.pause().stop().destroy() }
    }
}
