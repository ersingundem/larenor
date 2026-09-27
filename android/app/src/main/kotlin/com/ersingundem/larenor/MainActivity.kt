package com.ersingundem.larenor

import android.content.res.Configuration
import android.content.Intent
import android.view.KeyEvent
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
import com.ersingundem.larenor.display.DualDisplayBridge
import com.ersingundem.larenor.game.GameStreamNativeBridge
import com.ersingundem.larenor.webpanel.WebPanelRendererBridge
import com.ersingundem.larenor.webpanel.WebPanelDownloadBridge
import com.ersingundem.larenor.webpanel.WebPanelNativeEffectBridge
import com.ersingundem.larenor.kioskremote.ManagedTabletSourceBridge
import com.ersingundem.larenor.backup.CoreBackupDestinationBridge
import com.ersingundem.larenor.backup.CoreBackupSourceBridge
import com.ersingundem.larenor.camera.PersonalCameraBridge
import com.ersingundem.larenor.playbackquality.AndroidPlaybackCapabilityBridge

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
    private var dualDisplay: DualDisplayBridge? = null
    private var gameStreamNative: GameStreamNativeBridge? = null
    private var webPanelRenderer: WebPanelRendererBridge? = null
    private var webPanelDownload: WebPanelDownloadBridge? = null
    private var webPanelNativeEffects: WebPanelNativeEffectBridge? = null
    private var managedTabletSource: ManagedTabletSourceBridge? = null
    private var coreBackupDestination: CoreBackupDestinationBridge? = null
    private var coreBackupSource: CoreBackupSourceBridge? = null
    private var personalCamera: PersonalCameraBridge? = null
    private var playbackCapabilities: AndroidPlaybackCapabilityBridge? = null
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        localAudio = LocalAudioBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        windowPolicy = WindowPolicyBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        wellbeing = WellbeingBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        kiosk = KioskBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        kioskPeripherals = KioskPeripheralBridge(this, flutterEngine.dartExecutor.binaryMessenger).also {
            it.setWindowFocused(hasWindowFocus())
        }
        launcherShortcuts = LauncherShortcutBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        updater = ClientUpdaterBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        vncNative = VncNativeBridge(flutterEngine.dartExecutor.binaryMessenger)
        rdpNative = RdpNativeBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        inventoryShare = InventoryShareBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        localNotifications = LocalNotificationBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        dualDisplay = DualDisplayBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        gameStreamNative = GameStreamNativeBridge(flutterEngine.dartExecutor.binaryMessenger)
        webPanelRenderer = WebPanelRendererBridge(
            flutterEngine.dartExecutor.binaryMessenger,
            flutterEngine,
        )
        webPanelDownload = WebPanelDownloadBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        webPanelNativeEffects = WebPanelNativeEffectBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        managedTabletSource = ManagedTabletSourceBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        coreBackupDestination = CoreBackupDestinationBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        coreBackupSource = CoreBackupSourceBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        personalCamera = PersonalCameraBridge(
            this,
            flutterEngine.dartExecutor.binaryMessenger,
            flutterEngine.renderer,
        )
        playbackCapabilities = AndroidPlaybackCapabilityBridge(
            this,
            flutterEngine.dartExecutor.binaryMessenger,
        )
    }
    override fun onResume() {
        super.onResume()
        localAudio?.setResumed(true)
        windowPolicy?.setResumed(true)
        wellbeing?.setResumed(true)
        kiosk?.setResumed(true)
        kioskPeripherals?.setResumed(true)
        launcherShortcuts?.setResumed(true)
        updater?.setResumed(true)
        vncNative?.setResumed(true)
        rdpNative?.setResumed(true)
        inventoryShare?.setResumed(true)
        localNotifications?.setResumed(true)
        dualDisplay?.setResumed(true)
        gameStreamNative?.setResumed(true)
        managedTabletSource?.setResumed(true)
        webPanelNativeEffects?.setResumed(true)
        personalCamera?.setResumed(true)
    }
    override fun onPause() {
        localAudio?.setResumed(false)
        windowPolicy?.setResumed(false)
        wellbeing?.setResumed(false)
        kiosk?.setResumed(false)
        kioskPeripherals?.setResumed(false)
        launcherShortcuts?.setResumed(false)
        updater?.setResumed(false)
        vncNative?.setResumed(false)
        rdpNative?.setResumed(false)
        inventoryShare?.setResumed(false)
        localNotifications?.setResumed(false)
        dualDisplay?.setResumed(false)
        gameStreamNative?.setResumed(false)
        managedTabletSource?.setResumed(false)
        webPanelNativeEffects?.setResumed(false)
        personalCamera?.setResumed(false)
        super.onPause()
    }
    override fun onStop() {
        webPanelNativeEffects?.setStopped()
        super.onStop()
    }
    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        wellbeing?.windowFocusChanged()
        kiosk?.windowChanged()
        kioskPeripherals?.setWindowFocused(hasFocus)
        updater?.windowChanged()
        windowPolicy?.windowChanged()
        vncNative?.setWindowFocused(hasFocus)
        rdpNative?.setWindowFocused(hasFocus)
        inventoryShare?.windowChanged()
        localNotifications?.windowChanged()
        dualDisplay?.setWindowFocused(hasFocus)
        gameStreamNative?.setWindowFocused(hasFocus)
        personalCamera?.setWindowFocused(hasFocus)
    }
    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        kiosk?.windowChanged()
        windowPolicy?.windowChanged()
        dualDisplay?.configurationChanged()
    }
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        launcherShortcuts?.handleIntent(intent)
        localNotifications?.handleIntent(intent)
        kioskPeripherals?.onNewIntent(intent)
    }
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (kioskPeripherals?.onKeyEvent(event) == true) return true
        return super.dispatchKeyEvent(event)
    }
    @Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (webPanelNativeEffects?.onActivityResult(requestCode, resultCode, data) == true) return
        if (webPanelDownload?.onActivityResult(requestCode, resultCode, data) == true) return
        if (coreBackupDestination?.onActivityResult(requestCode, resultCode, data) == true) return
        if (coreBackupSource?.onActivityResult(requestCode, resultCode, data) == true) return
        super.onActivityResult(requestCode, resultCode, data)
    }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        if (kioskPeripherals?.onRequestPermissionsResult(requestCode, permissions, grantResults) == true) return
        if (personalCamera?.onRequestPermissionsResult(requestCode, permissions, grantResults) == true) return
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
        playbackCapabilities?.dispose()
        playbackCapabilities = null
        personalCamera?.dispose()
        personalCamera = null
        coreBackupSource?.dispose()
        coreBackupSource = null
        coreBackupDestination?.dispose()
        coreBackupDestination = null
        webPanelRenderer?.dispose()
        webPanelRenderer = null
        webPanelDownload?.dispose()
        webPanelDownload = null
        webPanelNativeEffects?.dispose()
        webPanelNativeEffects = null
        managedTabletSource?.dispose()
        managedTabletSource = null
        dualDisplay?.dispose()
        dualDisplay = null
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
