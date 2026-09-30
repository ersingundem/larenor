package com.ersingundem.larenor.display

import android.app.Activity
import android.app.Application
import android.graphics.SurfaceTexture
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.os.Looper
import android.view.Surface
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class AndroidDualDisplayHostTest {
    @Test
    fun actualDisplayManagerHotplugResizeAndRemovalAdvanceExactTopology() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val host = AndroidDualDisplayHost(activity) { it.displayId in 1..63 }
        val listener = object : DisplayManager.DisplayListener {
            override fun onDisplayAdded(displayId: Int) = host.refresh()
            override fun onDisplayChanged(displayId: Int) = host.refresh()
            override fun onDisplayRemoved(displayId: Int) = host.refresh()
        }
        host.listen(listener)
        var texture: SurfaceTexture? = null
        var surface: Surface? = null
        var virtual: VirtualDisplay? = null
        try {
            val baseline = host.topology()
            assertEquals(1, baseline.surfaces.size)
            assertTrue(baseline.surfaces.single().primary)

            val manager = activity.getSystemService(DisplayManager::class.java)
            texture = SurfaceTexture(0)
            surface = Surface(texture)
            val created = manager.createVirtualDisplay(
                "Larenor test display",
                1920,
                1080,
                160,
                surface,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_PUBLIC or
                    DisplayManager.VIRTUAL_DISPLAY_FLAG_PRESENTATION,
            )
            virtual = created
            shadowOf(Looper.getMainLooper()).idle()
            val externalId = created.display.displayId
            val attached = host.topology()
            val first = attached.surfaces.single { it.displayId == externalId }
            assertTrue(attached.revision > baseline.revision)
            assertEquals(1920, first.widthPixels)
            assertEquals(1080, first.heightPixels)

            created.resize(1280, 720, 240)
            shadowOf(Looper.getMainLooper()).idle()
            val resized = host.topology()
            val second = resized.surfaces.single { it.displayId == externalId }
            assertTrue(resized.revision > attached.revision)
            assertTrue(second.generation > first.generation)
            assertEquals(1280, second.widthPixels)
            assertEquals(720, second.heightPixels)

            created.release()
            shadowOf(Looper.getMainLooper()).idle()
            val removed = host.topology()
            assertTrue(removed.revision > resized.revision)
            assertNull(removed.surfaces.singleOrNull { it.displayId == externalId })
        } finally {
            virtual?.release()
            surface?.release()
            texture?.release()
            host.stopListening(listener)
            host.dispose()
            activity.finish()
        }
    }
}
