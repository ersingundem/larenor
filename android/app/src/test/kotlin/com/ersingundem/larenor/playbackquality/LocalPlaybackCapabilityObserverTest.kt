package com.ersingundem.larenor.playbackquality

import android.app.Activity
import android.app.Application
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class LocalPlaybackCapabilityObserverTest {
    private class Messenger : BinaryMessenger {
        override fun send(channel: String, message: ByteBuffer?) = Unit
        override fun send(
            channel: String,
            message: ByteBuffer?,
            callback: BinaryMessenger.BinaryReply?,
        ) = Unit

        override fun setMessageHandler(
            channel: String,
            handler: BinaryMessenger.BinaryMessageHandler?,
        ) = Unit
    }

    private class Result : MethodChannel.Result {
        var value: Any? = null
        var code: String? = null
        var missing = false
        override fun success(result: Any?) { value = result }
        override fun error(code: String, message: String?, details: Any?) {
            this.code = code
        }
        override fun notImplemented() { missing = true }
    }

    private val display = LocalPlaybackDisplayFacts(
        id = 2,
        modeId = 7,
        widthPixels = 2560,
        heightPixels = 1440,
        refreshRateBits = 60f.toRawBits(),
        hdrTypes = listOf("hdr10"),
    )
    private val decoders = LocalPlaybackDecoderFacts(
        mimeTypes = listOf("audio/eac3", "video/hevc"),
        truncated = false,
    )
    private val network = LocalPlaybackNetworkFacts(
        handle = 42,
        transports = listOf("wifi"),
        validated = true,
        metered = false,
        downstreamKbps = 80_000,
    )

    @Test
    fun stableCurrentFactsProduceOpaqueJsSafeRevisionsWithoutNetworkIdentity() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup()
        try {
            val observer = observer(activity.get(), owner = 11)
            val first = observer.snapshot()!!
            val second = observer.snapshot()!!

            assertEquals(first, second)
            assertTrue(first.displayRevision in 1..LOCAL_PLAYBACK_MAX_SAFE_INTEGER)
            assertTrue(first.decoderRevision in 1..LOCAL_PLAYBACK_MAX_SAFE_INTEGER)
            assertTrue(first.networkRevision in 1..LOCAL_PLAYBACK_MAX_SAFE_INTEGER)
            assertEquals(
                setOf(
                    "schemaVersion", "displayWidthPixels", "displayHeightPixels",
                    "displayRevision", "decoderMimeTypes",
                    "decoderMimeTypesTruncated", "decoderRevision",
                    "networkTransports", "networkValidated", "networkMetered",
                    "networkDownstreamKbps", "networkRevision",
                ),
                first.toChannel().keys,
            )
            assertFalse(first.toChannel().containsKey("networkHandle"))
            assertFalse(first.toChannel().containsKey("hardwareAccelerated"))
            assertFalse(first.toChannel().containsKey("hdrPlaybackVerified"))
        } finally {
            activity.pause().stop().destroy()
        }
    }

    @Test
    fun ownerOrBoundFactChangeProducesDifferentContentRevision() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup()
        try {
            val base = observer(activity.get(), owner = 11).snapshot()!!
            val successor = observer(activity.get(), owner = 12).snapshot()!!
            val replacementNetwork = observer(
                activity.get(),
                owner = 11,
                network = network.copy(handle = 43),
            ).snapshot()!!

            assertNotEquals(base.displayRevision, successor.displayRevision)
            assertNotEquals(base.decoderRevision, successor.decoderRevision)
            assertNotEquals(base.networkRevision, successor.networkRevision)
            assertNotEquals(base.networkRevision, replacementNetwork.networkRevision)
            assertEquals(base.displayRevision, replacementNetwork.displayRevision)
            assertEquals(base.decoderRevision, replacementNetwork.decoderRevision)
        } finally {
            activity.pause().stop().destroy()
        }
    }

    @Test
    fun displayOrNetworkReplacementDuringSnapshotFailsClosed() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup()
        try {
            var displayReads = 0
            val displayDrift = LocalPlaybackCapabilityObserver(
                activity = activity.get(),
                ownerGeneration = 11,
                displayReader = {
                    displayReads++
                    if (displayReads == 1) display else display.copy(modeId = 8)
                },
                decoderReader = { decoders },
                networkReader = { network },
            )
            assertNull(displayDrift.snapshot())

            var networkReads = 0
            val networkDrift = LocalPlaybackCapabilityObserver(
                activity = activity.get(),
                ownerGeneration = 11,
                displayReader = { display },
                decoderReader = { decoders },
                networkReader = {
                    networkReads++
                    if (networkReads == 1) network else network.copy(handle = 43)
                },
            )
            assertNull(networkDrift.snapshot())
        } finally {
            activity.pause().stop().destroy()
        }
    }

    @Test
    fun productionBridgeOwnsTheExactReadOnlyMethodAndRejectsArguments() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup()
        val bridge = AndroidPlaybackCapabilityBridge(activity.get(), Messenger())
        try {
            val result = Result()
            bridge.onMethodCall(
                MethodCall("localPlaybackProfileSnapshot", null),
                result,
            )
            assertFalse(result.missing)
            assertTrue(
                result.code == "capabilityUnavailable" || result.value is Map<*, *>,
            )

            val invalid = Result()
            bridge.onMethodCall(
                MethodCall("localPlaybackProfileSnapshot", emptyMap<String, Any?>()),
                invalid,
            )
            assertEquals("invalidRequest", invalid.code)
        } finally {
            bridge.dispose()
            activity.pause().stop().destroy()
        }
    }

    private fun observer(
        activity: Activity,
        owner: Long,
        network: LocalPlaybackNetworkFacts = this.network,
    ) = LocalPlaybackCapabilityObserver(
        activity = activity,
        ownerGeneration = owner,
        displayReader = { display },
        decoderReader = { decoders },
        networkReader = { network },
    )
}
