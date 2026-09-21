package com.ersingundem.larenor.kiosk

object LauncherShortcutContract {
    const val OPEN_HOME = "com.ersingundem.larenor.action.OPEN_HOME"
    const val OPEN_KIOSK = "com.ersingundem.larenor.action.OPEN_KIOSK"

    fun parse(action: String?): String? = when (action) {
        OPEN_HOME -> "home"
        OPEN_KIOSK -> "kiosk"
        else -> null
    }
}
