package com.ersingundem.larenor.game.moonlight

import android.content.Intent
import android.os.Looper
import android.view.View
import com.limelight.R
import com.limelight.utils.SpinnerDialog
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/** Actual packaged modal/window transfer; does not emulate a network stream. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class MoonlightForegroundWindowTest {
    @After fun clearLease() = MoonlightForegroundLeaseRegistry.clearForTest()

    @Test fun resumedTopGameClaimsItsVisibleWindowWhileOwnedSpinnerHasFocus() {
        val (activity, token) = preparedGame()
        val spinner = SpinnerDialog.displayDialog(activity, "Owned fixture", "Connecting", true)
        shadowOf(Looper.getMainLooper()).idle()
        assertFalse(activity.hasWindowFocus())
        resume(activity)
        activity.onTopResumedActivityChanged(true)
        shadowOf(Looper.getMainLooper()).idle()

        assertEquals(MoonlightLeaseState.GAME_VISIBLE, MoonlightForegroundLeaseRegistry.snapshot(token).state)
        assertEquals(0, MoonlightForegroundLeaseRegistry.outputWitnessSnapshot(token).renderedFrameCount)
        assertEquals(0, MoonlightForegroundLeaseRegistry.outputWitnessSnapshot(token).acceptedAudioWriteCount)

        // Pausing retires local ownership even before onStop, and a late UI
        // callback cannot re-claim that exact retired generation.
        activity.onTopResumedActivityChanged(false)
        pause(activity)
        spinner.dismiss()
        shadowOf(Looper.getMainLooper()).idle()
        assertTrue(MoonlightForegroundLeaseRegistry.snapshot(token).state != MoonlightLeaseState.GAME_VISIBLE)
        activity.onTopResumedActivityChanged(true)
        shadowOf(Looper.getMainLooper()).idle()
        assertTrue(MoonlightForegroundLeaseRegistry.snapshot(token).state != MoonlightLeaseState.GAME_VISIBLE)
    }

    @Test fun visibleButNonTopOrPausedGameCannotClaimTransfer() {
        val (activity, token) = preparedGame()
        resume(activity)
        activity.onTopResumedActivityChanged(false)
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals(MoonlightLeaseState.TRANSFER_PENDING, MoonlightForegroundLeaseRegistry.snapshot(token).state)
        pause(activity)
        activity.onTopResumedActivityChanged(true)
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals(MoonlightLeaseState.TRANSFER_PENDING, MoonlightForegroundLeaseRegistry.snapshot(token).state)
    }

    @Test fun topButHiddenOrFinishingGameCannotClaimTransfer() {
        val (activity, token) = preparedGame()
        activity.window.decorView.visibility = View.GONE
        resume(activity)
        activity.onTopResumedActivityChanged(true)
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals(MoonlightLeaseState.TRANSFER_PENDING, MoonlightForegroundLeaseRegistry.snapshot(token).state)
        activity.window.decorView.visibility = View.VISIBLE
        activity.finish()
        activity.onTopResumedActivityChanged(true)
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals(MoonlightLeaseState.TRANSFER_PENDING, MoonlightForegroundLeaseRegistry.snapshot(token).state)
    }

    @Test fun unattachedGameCannotClaimEvenWhenResumedAndTop() {
        val (activity, token) = preparedGame(visible = false)
        resume(activity)
        activity.onTopResumedActivityChanged(true)
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals(MoonlightLeaseState.TRANSFER_PENDING, MoonlightForegroundLeaseRegistry.snapshot(token).state)
    }

    private fun resume(activity: LarenorMoonlightGame) = lifecycle(activity, "onResume")
    private fun pause(activity: LarenorMoonlightGame) = lifecycle(activity, "onPause")

    private fun lifecycle(activity: LarenorMoonlightGame, method: String) {
        LarenorMoonlightGame::class.java.getDeclaredMethod(method).apply {
            isAccessible = true
            invoke(activity)
        }
    }

    private fun preparedGame(visible: Boolean = true): Pair<LarenorMoonlightGame, String> {
        val authority = MoonlightAuthority(
            "7".repeat(32), 1,
            MoonlightScope("1".repeat(32), "2".repeat(32), "3".repeat(32), "4".repeat(32)),
            "5".repeat(32), 1, 1, true, true, 1, 1, 1, 1,
        )
        val spec = MoonlightLaunchSpec(
            authority, "6".repeat(32), 1, "a".repeat(64), "192.0.2.1", 47989, 0,
            "Desktop", 42, "0123456789ABCDEF", "owned-fixture", "Fixture", false,
            ByteArray(512) { 1 }, 0, 60_000, 30_000,
        )
        val lease = MoonlightForegroundLeaseRegistry.issue(spec)
        val controller = Robolectric.buildActivity(LarenorMoonlightGame::class.java,
            Intent().putExtra(LarenorMoonlightGame.EXTRA_LAUNCH_TOKEN, lease.token))
        val activity = controller.get()
        // Start at the post-create window boundary: the network/media decoder
        // is not available on the JVM. Use the real packaged merge layout and
        // actual upstream SpinnerDialog rather than an alternate test layout.
        activity.setContentView(R.layout.activity_game)
        LarenorMoonlightGame::class.java.getDeclaredField("launchToken").apply {
            isAccessible = true
            set(activity, lease.token)
        }
        if (visible) controller.visible()
        return activity to lease.token
    }
}
