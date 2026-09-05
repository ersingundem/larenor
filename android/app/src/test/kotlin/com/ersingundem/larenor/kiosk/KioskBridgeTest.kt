package com.ersingundem.larenor.kiosk

import android.app.Activity
import android.app.Application
import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk=[35], application=Application::class)
class KioskBridgeTest {
    private class Messenger: BinaryMessenger {
        val handlers=mutableMapOf<String,BinaryMessenger.BinaryMessageHandler?>()
        override fun send(channel: String,message: ByteBuffer?) {}
        override fun send(channel: String,message: ByteBuffer?,callback: BinaryMessenger.BinaryReply?) {}
        override fun setMessageHandler(channel: String,handler: BinaryMessenger.BinaryMessageHandler?) {handlers[channel]=handler}
    }
    private class Result: MethodChannel.Result {
        var value: Any?=null;var code: String?=null;var message: String?=null;var missing=false
        override fun success(result: Any?) {value=result}
        override fun error(code: String,message: String?,details: Any?) {this.code=code;this.message=message;assertNull(details)}
        override fun notImplemented() {missing=true}
    }
    @Test fun openingAndLifecycleAreReadOnlyAndUnmanagedEntryIsDenied() {
        val activity=Robolectric.buildActivity(Activity::class.java).setup()
        val messenger=Messenger();val bridge=KioskBridge(activity.get(),messenger)
        try {
            bridge.setResumed(true);bridge.windowChanged()
            val result=Result();bridge.onMethodCall(MethodCall("snapshot",null),result)
            val map=result.value as Map<*,*>;assertEquals(11,map.size);assertEquals(false,map["deviceOwner"]);assertEquals(false,map["permitted"])
            val enter=Result();bridge.onMethodCall(MethodCall("prepare",mapOf("action" to "enter")),enter);assertEquals("denied",enter.code)
            val wipe=Result();bridge.onMethodCall(MethodCall("wipeData",null),wipe);assertTrue(wipe.missing)
            bridge.dispose();assertTrue(messenger.handlers.values.all{it==null})
            val disposed=Result();bridge.onMethodCall(MethodCall("snapshot",null),disposed);assertEquals("unavailable",disposed.code)
        } finally {bridge.dispose();activity.pause().stop().destroy()}
    }
    @Test fun ownAllowlistEntryChangesPreserveOtherPackagesAndPowerRestorePreservesFlags() {
        val activity=Robolectric.buildActivity(Activity::class.java).setup()
        val app=activity.get();val manager=app.getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager
        val admin=ComponentName(app,KioskAdminReceiver::class.java)
        assertTrue(shadowOf(manager).setDeviceOwner(admin))
        val bridge=KioskBridge(app,Messenger())
        try {
            manager.setLockTaskPackages(admin,arrayOf("approved.one","approved.two"))
            bridge.apply(KioskAction.allowApp)
            assertArrayEquals(arrayOf("approved.one","approved.two",app.packageName),manager.getLockTaskPackages(admin))
            bridge.apply(KioskAction.allowApp)
            assertEquals(3,manager.getLockTaskPackages(admin).size)
            bridge.apply(KioskAction.removeApp)
            assertArrayEquals(arrayOf("approved.one","approved.two"),manager.getLockTaskPackages(admin))
            val previous=DevicePolicyManager.LOCK_TASK_FEATURE_SYSTEM_INFO or DevicePolicyManager.LOCK_TASK_FEATURE_KEYGUARD
            manager.setLockTaskFeatures(admin,previous)
            bridge.apply(KioskAction.restorePowerMenu)
            assertEquals(previous or DevicePolicyManager.LOCK_TASK_FEATURE_GLOBAL_ACTIONS,manager.getLockTaskFeatures(admin))
        } finally {bridge.dispose();activity.pause().stop().destroy()}
    }
    @Test fun receiverIsSystemPermissionProtectedAndHasNoEnrollmentSideEffects() {
        val activity=Robolectric.buildActivity(Activity::class.java).setup()
        val app=activity.get()
        try {
            @Suppress("DEPRECATION")
            val info=app.packageManager.getReceiverInfo(ComponentName(app,KioskAdminReceiver::class.java),0)
            assertTrue(info.exported);assertEquals("android.permission.BIND_DEVICE_ADMIN",info.permission)
            val receiver=KioskAdminReceiver()
            receiver.onEnabled(app,android.content.Intent("android.app.action.DEVICE_ADMIN_ENABLED"))
            val dpm=app.getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager
            assertFalse(dpm.isDeviceOwnerApp(app.packageName));assertFalse(dpm.isLockTaskPermitted(app.packageName))
        } finally {activity.pause().stop().destroy()}
    }
}
