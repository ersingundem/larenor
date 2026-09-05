package com.ersingundem.larenor.wellbeing

import android.app.Activity
import android.app.Application
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Looper
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import androidx.health.connect.client.permission.HealthPermission
import androidx.health.connect.client.records.WeightRecord
import androidx.health.connect.client.records.BodyFatRecord
import androidx.health.connect.client.records.StepsRecord
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import kotlinx.coroutines.CompletableDeferred
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class WellbeingBridgeTest {
    private class Messenger : BinaryMessenger {
        val handlers = mutableMapOf<String, BinaryMessenger.BinaryMessageHandler?>()
        override fun send(channel: String, message: ByteBuffer?) {}
        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) {}
        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) { handlers[channel] = handler }
    }
    private class Result : MethodChannel.Result {
        var value: Any? = null
        var error: String? = null
        var replies = 0
        var missing = false
        override fun success(result: Any?) { value = result; replies++ }
        override fun error(code: String, message: String?, details: Any?) {
            error = code; replies++
            assertNull(details)
            assertFalse(message.orEmpty().contains("private"))
        }
        override fun notImplemented() { missing = true; replies++ }
    }
    private class Backend : WellbeingBackend {
        var available = "available"
        var permissions = setOf(WellbeingMetric.bodyMass)
        var pages = 0
        var permissionGate: CompletableDeferred<Set<WellbeingMetric>>? = null
        var pageGate: CompletableDeferred<WellbeingPage>? = null
        override fun availability() = available
        override suspend fun granted(): Set<WellbeingMetric> = permissionGate?.await() ?: permissions
        override suspend fun page(metric: WellbeingMetric, start: Long, end: Long, limit: Int, token: String?): WellbeingPage {
            pages++
            return pageGate?.await() ?: WellbeingPage(listOf(WellbeingMeasurement("sample", 70.0, start)), null)
        }
        override suspend fun steps(start: Long, end: Long): Long? { error("raw test must never read steps") }
    }
    private fun readArgs(): Map<String, Any> {
        val end = System.currentTimeMillis()
        return mapOf("metrics" to listOf("bodyMass"), "startMillis" to end - 86_400_000,
            "endMillis" to end, "maxRecords" to 500)
    }
    private fun pump() = Shadows.shadowOf(Looper.getMainLooper()).idle()

    @Test fun constructionAndProbeArePassiveAndSynchronousReadsDoNotRemainBusy() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().visible().windowFocusChanged(true)
        val backend = Backend()
        val bridge = WellbeingBridge(activity.get(), Messenger(), backend)
        try {
            assertEquals(0, backend.pages)
            val probe = Result()
            bridge.onMethodCall(MethodCall("probe", null), probe); pump()
            assertEquals("available", (probe.value as Map<*, *>)["availability"])
            assertEquals(0, backend.pages)
            assertNull(Shadows.shadowOf(activity.get()).nextStartedActivity)
            val blocked = Result()
            bridge.onMethodCall(MethodCall("read", readArgs()), blocked); pump()
            assertNotNull(blocked.error)
            assertEquals(0, backend.pages)
            bridge.setResumed(true)
            val noPrivateClaim = Result()
            bridge.onMethodCall(MethodCall("read", readArgs()), noPrivateClaim); pump()
            assertNotNull(noPrivateClaim.error)
            assertEquals(0, backend.pages)
            val noPrivatePermission = Result()
            bridge.onMethodCall(MethodCall("requestReadPermissions", mapOf("metrics" to listOf("steps"))), noPrivatePermission); pump()
            assertNotNull(noPrivatePermission.error)
            assertNull(Shadows.shadowOf(activity.get()).nextStartedActivity)
            bridge.onMethodCall(MethodCall("setPrivateView", true), Result())
            repeat(2) {
                val read = Result()
                bridge.onMethodCall(MethodCall("read", readArgs()), read); pump()
                assertNull(read.error)
                assertEquals("data", ((read.value as List<*>).single() as Map<*, *>)["state"])
            }
            assertEquals(2, backend.pages)
        } finally { bridge.dispose(); activity.pause().stop().destroy() }
    }

    @Test fun malformedAndUnfocusedCommandsNeverReadOrLaunchSettings() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().visible().windowFocusChanged(true)
        val backend = Backend()
        val bridge = WellbeingBridge(activity.get(), Messenger(), backend)
        try {
            bridge.setResumed(true)
            bridge.onMethodCall(MethodCall("setPrivateView", true), Result())
            val malformed = Result()
            bridge.onMethodCall(MethodCall("read", readArgs() + ("metrics" to listOf("heartRate"))), malformed)
            assertEquals("invalidData", malformed.error)
            activity.windowFocusChanged(false)
            bridge.windowFocusChanged()
            for ((method, args) in listOf("read" to readArgs(), "requestReadPermissions" to mapOf("metrics" to listOf("steps")), "openPermissionSettings" to null)) {
                val result = Result()
                bridge.onMethodCall(MethodCall(method, args), result); pump()
                assertNotNull(result.error)
            }
            assertEquals(0, backend.pages)
            assertNull(Shadows.shadowOf(activity.get()).nextStartedActivity)
        } finally { bridge.dispose(); activity.pause().stop().destroy() }
    }

    @Test fun inFlightReadCannotDuplicateAndBackgroundCancelsEveryLateValue() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().visible().windowFocusChanged(true)
        val gate = CompletableDeferred<WellbeingPage>()
        val backend = Backend().apply { pageGate = gate }
        val bridge = WellbeingBridge(activity.get(), Messenger(), backend)
        try {
            bridge.setResumed(true)
            bridge.onMethodCall(MethodCall("setPrivateView", true), Result())
            val first = Result()
            bridge.onMethodCall(MethodCall("read", readArgs()), first); pump()
            val duplicate = Result()
            bridge.onMethodCall(MethodCall("read", readArgs()), duplicate); pump()
            assertEquals(1, backend.pages)
            assertNotNull(duplicate.error)
            bridge.setResumed(false); pump()
            gate.complete(WellbeingPage(listOf(WellbeingMeasurement("private-late", 88.0, System.currentTimeMillis() - 1000)), null)); pump()
            assertNull(first.value)
            assertEquals("cancelled", first.error)
            assertEquals(1, first.replies)
        } finally { bridge.dispose(); activity.pause().stop().destroy() }
    }

    @Test fun cancellationWhilePermissionPreflightAwaitsPreventsOsPrompt() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().visible().windowFocusChanged(true)
        val gate = CompletableDeferred<Set<WellbeingMetric>>()
        val backend = Backend().apply { permissionGate = gate }
        val bridge = WellbeingBridge(activity.get(), Messenger(), backend)
        try {
            bridge.setResumed(true)
            bridge.onMethodCall(MethodCall("setPrivateView", true), Result())
            val request = Result()
            bridge.onMethodCall(MethodCall("requestReadPermissions", mapOf("metrics" to listOf("steps"))), request); pump()
            bridge.onMethodCall(MethodCall("cancel", null), Result())
            gate.complete(emptySet()); pump()
            assertNotNull(request.error)
            assertNull(Shadows.shadowOf(activity.get()).nextStartedActivity)
            assertEquals(0, backend.pages)
        } finally { bridge.dispose(); activity.pause().stop().destroy() }
    }

    @Test fun permissionTicketCarriesNoRecordsAndResultOnlyReportsActualPermissions() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().visible().windowFocusChanged(true)
        val backend = Backend().apply { permissions = emptySet() }
        val bridge = WellbeingBridge(activity.get(), Messenger(), backend)
        try {
            bridge.setResumed(true)
            bridge.onMethodCall(MethodCall("setPrivateView", true), Result())
            val request = Result()
            bridge.onMethodCall(MethodCall("requestReadPermissions", mapOf("metrics" to listOf("steps"))), request); pump()
            val intent = Shadows.shadowOf(activity.get()).nextStartedActivity
            assertEquals(WellbeingPermissionActivity::class.java.name, intent.component!!.className)
            assertEquals(setOf(WellbeingPermissionActivity.EXTRA_TICKET), intent.extras!!.keySet())
            val token = intent.getStringExtra(WellbeingPermissionActivity.EXTRA_TICKET)
            val pending = WellbeingPermissionRuntime.broker.take(token)
            assertEquals(setOf(WellbeingMetric.steps), pending!!.metrics)
            bridge.setResumed(false) // Root PIN gate may close while OS permission UI is open.
            backend.permissions = setOf(WellbeingMetric.steps)
            WellbeingPermissionRuntime.broker.finish(token); pump()
            val permissions = (request.value as Map<*, *>)["permissions"] as Map<*, *>
            assertEquals("granted", permissions["steps"])
            assertEquals("notRequested", permissions["bodyMass"])
            assertEquals(0, backend.pages)
            assertNull(Shadows.shadowOf(activity.get()).nextStartedActivity)
        } finally { bridge.dispose(); activity.pause().stop().destroy() }
    }

    @Test fun permissionActivityRejectsForgedTicketAndRationaleIgnoresExternalPayload() {
        val forged = Intent().putExtra(WellbeingPermissionActivity.EXTRA_TICKET, "forged-private-value")
        val activity = Robolectric.buildActivity(WellbeingPermissionActivity::class.java, forged).create()
        try {
            assertTrue(activity.get().isFinishing)
            assertNull(Shadows.shadowOf(activity.get()).nextStartedActivity)
        } finally { activity.destroy() }
        val privacy = Robolectric.buildActivity(WellbeingPrivacyActivity::class.java,
            Intent().putExtra("records", "private-person-weight-123.4")).setup()
        try {
            fun texts(view: View): List<String> = when (view) {
                is TextView -> listOf(view.text.toString())
                is ViewGroup -> (0 until view.childCount).flatMap { texts(view.getChildAt(it)) }
                else -> emptyList()
            }
            val shown = texts(privacy.get().window.decorView).joinToString()
            assertTrue(shown.contains("Larenor"))
            assertFalse(shown.contains("private-person-weight"))
            val pm = privacy.get().packageManager
            val packageName = privacy.get().packageName
            val permissionActivity = pm.getActivityInfo(ComponentName(packageName, WellbeingPermissionActivity::class.java.name), 0)
            assertFalse(permissionActivity.exported)
            val alias = pm.getActivityInfo(ComponentName(packageName, "$packageName.wellbeing.ViewPermissionUsageActivity"), 0)
            assertEquals("android.permission.START_VIEW_PERMISSION_USAGE", alias.permission)
            val health = pm.getPackageInfo(packageName, PackageManager.GET_PERMISSIONS).requestedPermissions.orEmpty().filter { it.startsWith("android.permission.health.") }
            assertEquals(WellbeingMetric.entries.map { it.permission }.toSet(), health.toSet())
            assertEquals(setOf(HealthPermission.getReadPermission(WeightRecord::class),
                HealthPermission.getReadPermission(BodyFatRecord::class),
                HealthPermission.getReadPermission(StepsRecord::class)), health.toSet())
        } finally { privacy.pause().stop().destroy() }
    }

    @Test fun hungPermissionStatusAndReadHaveFiniteNativeDeadlines() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().visible().windowFocusChanged(true)
        val permissionGate = CompletableDeferred<Set<WellbeingMetric>>()
        val backend = Backend().apply { this.permissionGate = permissionGate }
        val bridge = WellbeingBridge(activity.get(), Messenger(), backend)
        try {
            val status = Result()
            bridge.onMethodCall(MethodCall("probe", null), status)
            Shadows.shadowOf(Looper.getMainLooper()).idleFor(java.time.Duration.ofSeconds(11))
            assertEquals("unavailable", status.error)
            assertEquals(0, backend.pages)
            backend.permissionGate = null
            backend.pageGate = CompletableDeferred()
            bridge.setResumed(true)
            bridge.onMethodCall(MethodCall("setPrivateView", true), Result())
            val read = Result()
            bridge.onMethodCall(MethodCall("read", readArgs()), read)
            Shadows.shadowOf(Looper.getMainLooper()).idleFor(java.time.Duration.ofSeconds(29))
            assertEquals("timeout", read.error)
            assertNull(read.value)
            assertEquals(1, read.replies)
        } finally { bridge.dispose(); activity.pause().stop().destroy() }
    }

    @Test @Config(sdk = [26]) fun api26IsExplicitlyUnavailableWithoutAnyClientOrPermissionUi() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup()
        try { assertEquals("unavailableOnDevice", HealthConnectBackend(activity.get()).availability()) }
        finally { activity.pause().stop().destroy() }
    }
}
