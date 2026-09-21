package com.ersingundem.larenor

import android.content.res.Configuration
import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import androidx.media3.common.util.UnstableApi
import com.ersingundem.larenor.audio.LocalAudioBridge
import com.ersingundem.larenor.window.WindowPolicyBridge
import com.ersingundem.larenor.kiosk.KioskBridge
import com.ersingundem.larenor.kiosk.KioskPeripheralBridge
import com.ersingundem.larenor.kiosk.LauncherShortcutBridge
import com.ersingundem.larenor.updater.ClientUpdaterBridge
import com.ersingundem.larenor.wellbeing.WellbeingBridge
import com.ersingundem.larenor.vnc.VncNativeBridge
import com.ersingundem.larenor.rdp.RdpNativeBridge
import com.ersingundem.larenor.inventory.InventoryShareBridge
import com.ersingundem.larenor.notifications.LocalNotificationBridge
import com.ersingundem.larenor.game.GameStreamNativeBridge

@UnstableApi
class MainActivity : FlutterActivity() {
    private var localAudio: LocalAudioBridge? = null
    private var windowPolicy: WindowPolicyBridge? = null
    private var wellbeing: WellbeingBridge? = null
    private var kiosk: KioskBridge? = null
    private var kioskPeripherals: KioskPeripheralBridge? = null
    private var launcherShortcuts: LauncherShortcutBridge? = null
    private var updater: ClientUpdaterBridge? = null
    private var vncNative: VncNativeBridge? = null
    private var rdpNative: RdpNativeBridge? = null
    private var inventoryShare: InventoryShareBridge? = null
    private var localNotifications: LocalNotificationBridge? = null
    private var gameStreamNative: GameStreamNativeBridge? = null
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        localAudio = LocalAudioBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        windowPolicy = WindowPolicyBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        wellbeing = WellbeingBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        kiosk = KioskBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        kioskPeripherals = KioskPeripheralBridge(flutterEngine.dartExecutor.binaryMessenger)
        launcherShortcuts = LauncherShortcutBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        updater = ClientUpdaterBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        vncNative = VncNativeBridge(flutterEngine.dartExecutor.binaryMessenger)
        rdpNative = RdpNativeBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        inventoryShare = InventoryShareBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        localNotifications = LocalNotificationBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        gameStreamNative = GameStreamNativeBridge(flutterEngine.dartExecutor.binaryMessenger)
    }
    override fun onResume() {
        super.onResume()
        localAudio?.setResumed(true)
        windowPolicy?.setResumed(true)
        wellbeing?.setResumed(true)
        kiosk?.setResumed(true)
        launcherShortcuts?.setResumed(true)
        updater?.setResumed(true)
        vncNative?.setResumed(true)
        rdpNative?.setResumed(true)
        inventoryShare?.setResumed(true)
        localNotifications?.setResumed(true)
        gameStreamNative?.setResumed(true)
    }
    override fun onPause() {
        localAudio?.setResumed(false)
        windowPolicy?.setResumed(false)
        wellbeing?.setResumed(false)
        kiosk?.setResumed(false)
        launcherShortcuts?.setResumed(false)
        updater?.setResumed(false)
        vncNative?.setResumed(false)
        rdpNative?.setResumed(false)
        inventoryShare?.setResumed(false)
        localNotifications?.setResumed(false)
        gameStreamNative?.setResumed(false)
        super.onPause()
    }
    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        wellbeing?.windowFocusChanged()
        kiosk?.windowChanged()
        updater?.windowChanged()
        windowPolicy?.windowChanged()
        vncNative?.setWindowFocused(hasFocus)
        rdpNative?.setWindowFocused(hasFocus)
        inventoryShare?.windowChanged()
        localNotifications?.windowChanged()
        gameStreamNative?.setWindowFocused(hasFocus)
    }
    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        kiosk?.windowChanged()
        windowPolicy?.windowChanged()
    }
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        launcherShortcuts?.handleIntent(intent)
        localNotifications?.handleIntent(intent)
    }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        if (localNotifications?.onRequestPermissionsResult(requestCode, permissions, grantResults) == true) return
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }
    @Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
    override fun onMultiWindowModeChanged(isInMultiWindowMode: Boolean) {
        super.onMultiWindowModeChanged(isInMultiWindowMode)
        kiosk?.windowChanged()
        windowPolicy?.windowChanged()
    }
    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        inventoryShare?.dispose()
        inventoryShare = null
        gameStreamNative?.dispose()
        gameStreamNative = null
        localNotifications?.dispose()
        localNotifications = null
        rdpNative?.dispose()
        rdpNative = null
        vncNative?.dispose()
        vncNative = null
        updater?.dispose()
        updater = null
        kiosk?.dispose()
        kiosk = null
        kioskPeripherals?.dispose()
        kioskPeripherals = null
        launcherShortcuts?.dispose()
        launcherShortcuts = null
        wellbeing?.dispose()
        wellbeing = null
        windowPolicy?.dispose()
        windowPolicy = null
        localAudio?.dispose()
        localAudio = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
