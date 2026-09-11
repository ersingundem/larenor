package com.ersingundem.larenor.vnc

import java.io.ByteArrayOutputStream
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class VncSyntheticRfbParserTest {
    @Test
    fun versionSecurityAndServerInitStayChunkSafeAndStrict() {
        val parser = VncSyntheticRfbParser()
        assertTrue(parser.accept("RFB 003.".encodeToByteArray()).isEmpty())
        val version = parser.accept("008\n".encodeToByteArray()).single() as VncRfbOutbound
        assertArrayEquals("RFB 003.008\n".encodeToByteArray(), version.bytes)

        val selected = parser.accept(byteArrayOf(2, 2, 19)).single() as VncRfbOutbound
        assertArrayEquals(byteArrayOf(19), selected.bytes)
        assertEquals(VncRfbPhase.VENCRYPT_HANDOFF, parser.phase)

        val clientInit = parser.markSecureAuthenticated().single() as VncRfbOutbound
        assertArrayEquals(byteArrayOf(1), clientInit.bytes)
        val serverInit = serverInit(1280, 800, "synthetic")
        assertTrue(parser.accept(serverInit.copyOfRange(0, 13)).isEmpty())
        val readyEvents = parser.accept(serverInit.copyOfRange(13, serverInit.size))
        val ready = readyEvents.filterIsInstance<VncRfbReady>().single()
        assertEquals(1280, ready.width)
        assertEquals(800, ready.height)
        assertEquals(3, readyEvents.filterIsInstance<VncRfbOutbound>().size)
        assertEquals(VncRfbPhase.ACTIVE, parser.phase)
    }

    @Test
    fun rawFramebufferUpdatesAreBoundedSequencedAndConvertedToRgba() {
        val parser = activeParser(width = 4, height = 2)
        val update = frameUpdate(
            x = 1,
            y = 0,
            width = 2,
            height = 1,
            wirePixels = byteArrayOf(
                0xff.toByte(), 0, 0, 0,
                0, 0x80.toByte(), 0xff.toByte(), 0,
            ),
        )
        assertTrue(parser.accept(update.copyOfRange(0, update.size - 3)).isEmpty())
        val first = parser.accept(update.copyOfRange(update.size - 3, update.size))
            .single() as VncRfbFrame
        assertEquals(1L, first.sequence)
        assertEquals(8, first.wireByteLength)
        assertArrayEquals(
            byteArrayOf(
                0xff.toByte(), 0, 0, 0xff.toByte(),
                0, 0x80.toByte(), 0xff.toByte(), 0xff.toByte(),
            ),
            first.rectangles.single().rgba,
        )

        val second = parser.accept(update).single() as VncRfbFrame
        assertEquals(2L, second.sequence)
    }

    @Test
    fun unsupportedOrOversizedProtocolInputFailsClosed() {
        val wrongVersion = VncSyntheticRfbParser()
        assertFailure("rfbVersionUnavailable") {
            wrongVersion.accept("RFB 003.007\n".encodeToByteArray())
        }
        assertEquals(VncRfbPhase.FAILED, wrongVersion.phase)
        assertEquals("VncRfbFailure(rfbVersionUnavailable)", wrongVersion.failure.toString())

        val missingSecureType = VncSyntheticRfbParser()
        missingSecureType.accept("RFB 003.008\n".encodeToByteArray())
        assertFailure("securityUnavailable") {
            missingSecureType.accept(byteArrayOf(2, 1, 2))
        }

        val oversized = activeParser(width = 8192, height = 8192)
        assertFailure("frameTooLarge") {
            oversized.accept(frameHeader(width = 3000, height = 2000))
        }
        assertEquals(0, oversized.bufferedByteCount)

        val outside = activeParser(width = 4, height = 2)
        assertFailure("malformedFrame") {
            outside.accept(frameUpdate(3, 0, 2, 1, ByteArray(8)))
        }
    }

    @Test
    fun cancellationAndBackgroundLossWipePendingBytesWithoutRestart() {
        val parser = VncSyntheticRfbParser()
        parser.accept("RFB 003.".encodeToByteArray())
        assertEquals(8, parser.bufferedByteCount)
        parser.setForeground(false)
        assertEquals(VncRfbPhase.CANCELLED, parser.phase)
        assertEquals(0, parser.bufferedByteCount)
        parser.cancel()
        assertFailure("cancelled") {
            parser.accept("008\n".encodeToByteArray())
        }
        assertFailure("cancelled") { parser.markSecureAuthenticated() }
    }

    private fun activeParser(width: Int, height: Int): VncSyntheticRfbParser {
        val parser = VncSyntheticRfbParser()
        parser.accept("RFB 003.008\n".encodeToByteArray())
        parser.accept(byteArrayOf(1, 19))
        parser.markSecureAuthenticated()
        parser.accept(serverInit(width, height, "fixture"))
        return parser
    }

    private fun serverInit(width: Int, height: Int, name: String): ByteArray {
        val output = ByteArrayOutputStream()
        output.u16(width)
        output.u16(height)
        output.write(byteArrayOf(
            32, 24, 0, 1,
            0, 0xff.toByte(), 0, 0xff.toByte(), 0, 0xff.toByte(),
            0, 8, 16, 0, 0, 0,
        ))
        val bytes = name.encodeToByteArray()
        output.u32(bytes.size)
        output.write(bytes)
        return output.toByteArray()
    }

    private fun frameUpdate(
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        wirePixels: ByteArray,
    ): ByteArray = ByteArrayOutputStream().apply {
        write(byteArrayOf(0, 0))
        u16(1)
        u16(x)
        u16(y)
        u16(width)
        u16(height)
        u32(0)
        write(wirePixels)
    }.toByteArray()

    private fun frameHeader(width: Int, height: Int): ByteArray =
        frameUpdate(0, 0, width, height, byteArrayOf())

    private fun assertFailure(code: String, action: () -> Unit) {
        val failure = runCatching(action).exceptionOrNull() as VncRfbFailure
        assertEquals(code, failure.code)
        assertTrue(failure.message.orEmpty().contains("desktop").not())
    }

    private fun ByteArrayOutputStream.u16(value: Int) {
        write(byteArrayOf((value ushr 8).toByte(), value.toByte()))
    }

    private fun ByteArrayOutputStream.u32(value: Int) {
        write(byteArrayOf(
            (value ushr 24).toByte(),
            (value ushr 16).toByte(),
            (value ushr 8).toByte(),
            value.toByte(),
        ))
    }
}
