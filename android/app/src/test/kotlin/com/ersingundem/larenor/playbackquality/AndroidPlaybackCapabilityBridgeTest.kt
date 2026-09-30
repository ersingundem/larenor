package com.ersingundem.larenor.playbackquality

import android.app.Activity
import android.app.Application
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class AndroidPlaybackCapabilityBridgeTest {
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

    @Test
    fun nativeSnapshotContractKeepsLinkEstimateExplicitAndBounded() {
        val value = AndroidPlaybackCapabilitySnapshot(
            decoderMimeTypes = listOf("audio/eac3", "video/hevc"),
            decoderMimeTypesTruncated = false,
            displayWidthPixels = 3840,
            displayHeightPixels = 2160,
            displayHdrTypes = listOf("hdr10"),
            networkTransports = listOf("ethernet", "vpn"),
            networkValidated = true,
            networkMetered = false,
            networkDownstreamKbps = 100_000,
        ).toChannel()

        assertEquals(PLAYBACK_CAPABILITY_SCHEMA_VERSION, value["schemaVersion"])
        assertEquals(listOf("audio/eac3", "video/hevc"), value["decoderMimeTypes"])
        assertEquals(3840, value["displayWidthPixels"])
        assertEquals(listOf("hdr10"), value["displayHdrTypes"])
        assertEquals(listOf("ethernet", "vpn"), value["networkTransports"])
        assertEquals(100_000, value["networkDownstreamKbps"])
        assertFalse(value.containsKey("measuredThroughputKbps"))
        assertFalse(value.containsKey("qualityAccepted"))
    }

    @Test
    fun productionBridgeReturnsClosedBoundedSnapshotAndRetires() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup()
        val bridge = AndroidPlaybackCapabilityBridge(activity.get(), Messenger())
        try {
            val result = Result()
            bridge.onMethodCall(MethodCall("snapshot", null), result)

            assertNull(result.code)
            val raw = result.value as Map<*, *>
            assertEquals(
                setOf(
                    "schemaVersion", "decoderMimeTypes",
                    "decoderMimeTypesTruncated", "displayWidthPixels",
                    "displayHeightPixels", "displayHdrTypes",
                    "networkTransports", "networkValidated",
                    "networkMetered", "networkDownstreamKbps",
                ),
                raw.keys,
            )
            assertEquals(1, raw["schemaVersion"])
            val decoders = raw["decoderMimeTypes"] as List<*>?
            assertTrue(decoders == null || decoders.size <= MAX_DECODER_MIME_TYPES)
            assertTrue(
                decoders == null || decoders.all {
                    it is String && it == it.lowercase() && "/" in it
                },
            )
            assertTrue(
                raw["displayWidthPixels"] == null ||
                    raw["displayWidthPixels"] as Int in 1..MAX_DISPLAY_PIXELS,
            )
            assertTrue(
                raw["networkDownstreamKbps"] == null ||
                    raw["networkDownstreamKbps"] as Int in 1..MAX_DOWNSTREAM_KBPS,
            )

            val invalid = Result()
            bridge.onMethodCall(MethodCall("snapshot", emptyMap<String, Any?>()), invalid)
            assertEquals("invalidRequest", invalid.code)

            val unknown = Result()
            bridge.onMethodCall(MethodCall("acceptQuality", null), unknown)
            assertTrue(unknown.missing)

            bridge.dispose()
            val retired = Result()
            bridge.onMethodCall(MethodCall("snapshot", null), retired)
            assertEquals("bridgeDisposed", retired.code)
        } finally {
            bridge.dispose()
            activity.pause().stop().destroy()
        }
    }
}
