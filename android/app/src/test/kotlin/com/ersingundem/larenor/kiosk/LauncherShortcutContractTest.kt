package com.ersingundem.larenor.kiosk

import org.junit.Assert.*
import org.junit.Test

class LauncherShortcutContractTest {
    @Test fun onlyClosedLauncherActionsReachFlutter() {
        assertEquals("home", LauncherShortcutContract.parse(LauncherShortcutContract.OPEN_HOME))
        assertEquals("kiosk", LauncherShortcutContract.parse(LauncherShortcutContract.OPEN_KIOSK))
        for (foreign in listOf(null, "", "android.intent.action.VIEW", "${LauncherShortcutContract.OPEN_HOME}.evil")) {
            assertNull(LauncherShortcutContract.parse(foreign))
        }
    }
}
