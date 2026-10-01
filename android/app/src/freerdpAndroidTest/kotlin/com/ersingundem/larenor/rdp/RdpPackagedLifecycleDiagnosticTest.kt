package com.ersingundem.larenor.rdp

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class RdpPackagedLifecycleDiagnosticTest {
    @Test
    fun atomicMarkerRetainsLatestFixedStageAndRemovesOnlyItsOwnedFile() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val nonce = "e".repeat(64)
        val marker = File(context.filesDir, "f62-owned-stage-$nonce")
        val unrelated = File(context.filesDir, "f62-owned-stage-unrelated")
        marker.delete()
        unrelated.writeText("keep")

        try {
            val diagnostic = OwnedLifecycleDiagnostic(
                AtomicLifecycleStorage(context, nonce),
            )
            diagnostic.enter("testInitialization")
            assertEquals("testInitialization", marker.readText())

            diagnostic.enter("initialFrameWait")
            assertEquals("initialFrameWait", marker.readText())

            diagnostic.remove()
            assertFalse(marker.exists())
            assertEquals("keep", unrelated.readText())

            val secondary = OwnedLifecycleDiagnostic(object : LifecycleStorage {
                override fun write(stage: String) {
                    throw java.io.IOException("owned diagnostic unavailable")
                }

                override fun remove() {
                    throw SecurityException("owned diagnostic unavailable")
                }
            })
            secondary.enter("providerInspection")
            secondary.remove()
        } finally {
            marker.delete()
            unrelated.delete()
        }
    }
}
