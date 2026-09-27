package com.ersingundem.larenor.game

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build

/**
 * Honest integration with the separately installed Moonlight app.
 *
 * Pairing keys, host addresses and stream traffic stay inside Moonlight. This
 * provider can open its real Android playback/input surface, but deliberately
 * cannot claim that a Larenor command reached a Sunshine host. Exact command
 * execution therefore remains unsupported until a reviewed embedded runtime
 * is packaged.
 */
class MoonlightAppGameStreamEngine(
    private val context: Context,
) : GameStreamNativeEngine {
    override fun capabilities(): GameStreamNativeCapabilities {
        val revision = installedRevision() ?: return GameStreamNativeCapabilities.unavailable()
        return GameStreamNativeCapabilities(
            availability = "available",
            engineRevision = revision,
            intents = emptySet(),
            provider = PROVIDER,
            handoffOnly = true,
            inputKinds = setOf("touch", "gamepad", "keyboard", "mouse"),
        )
    }

    override fun openProvider(): GameStreamProviderLaunch {
        val revision = installedRevision() ?: gameStreamFail("providerUnavailable")
        val launch = context.packageManager.getLaunchIntentForPackage(PACKAGE)
            ?: gameStreamFail("providerUnavailable")
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        try {
            context.startActivity(launch)
        } catch (_: ActivityNotFoundException) {
            gameStreamFail("providerLaunchFailed")
        } catch (_: SecurityException) {
            gameStreamFail("providerLaunchFailed")
        }
        return GameStreamProviderLaunch(PROVIDER, revision, handoffOnly = true)
    }

    override fun execute(
        command: GameStreamNativeCommand,
        credentialHandle: String,
        callback: (GameStreamEngineReceipt?, GameStreamNativeFailure?) -> Unit,
    ) {
        callback(null, GameStreamNativeFailure("unsupported"))
    }

    override fun retire(sessionId: String) {
        // The handoff app owns its own task and stream lifecycle. Larenor never
        // force-stops another package or reports that external playback ended.
    }

    private fun installedRevision(): String? = try {
        val info = context.packageManager.getPackageInfo(PACKAGE, 0)
        val version = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.longVersionCode
        } else {
            @Suppress("DEPRECATION")
            info.versionCode.toLong()
        }
        if (version < 1 || context.packageManager.getLaunchIntentForPackage(PACKAGE) == null) null
        else "moonlight-$version"
    } catch (_: PackageManager.NameNotFoundException) {
        null
    } catch (_: SecurityException) {
        null
    }

    companion object {
        const val PACKAGE = "com.limelight"
        const val PROVIDER = "moonlight"
    }
}
