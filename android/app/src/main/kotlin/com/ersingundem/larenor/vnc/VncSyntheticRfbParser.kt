package com.ersingundem.larenor.vnc

import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets

enum class VncRfbPhase {
    VERSION,
    SECURITY_TYPES,
    VENCRYPT_HANDOFF,
    SERVER_INIT,
    ACTIVE,
    CANCELLED,
    FAILED,
}

class VncRfbFailure(val code: String) : RuntimeException("Synthetic RFB input rejected") {
    override fun toString() = "VncRfbFailure($code)"
}

sealed interface VncRfbEvent

class VncRfbOutbound(bytes: ByteArray) : VncRfbEvent {
    val bytes = bytes.copyOf()
}

data class VncRfbReady(val width: Int, val height: Int) : VncRfbEvent

class VncRfbRectangle(
    val x: Int,
    val y: Int,
    val width: Int,
    val height: Int,
    rgba: ByteArray,
) {
    val rgba = rgba.copyOf()
}

class VncRfbFrame(
    val sequence: Long,
    rectangles: List<VncRfbRectangle>,
    val wireByteLength: Int,
) : VncRfbEvent {
    val rectangles = rectangles.toList()
}

/**
 * In-memory RFB 3.8 characterization fixture.
 *
 * This class has no socket, DNS, TLS, credential, or JNI dependency. A future
 * transport may feed it only after owning those boundaries independently.
 */
class VncSyntheticRfbParser {
    var phase = VncRfbPhase.VERSION
        private set
    var failure: VncRfbFailure? = null
        private set
    val bufferedByteCount: Int get() = pending.size

    private var pending = ByteArray(0)
    private var framebufferWidth = 0
    private var framebufferHeight = 0
    private var nextFrameSequence = 1L
    private var pendingFrameSequence: Long? = null

    fun accept(bytes: ByteArray): List<VncRfbEvent> {
        ensureOpen()
        return try {
            if (bytes.isEmpty()) reject("malformedProtocol")
            if (phase == VncRfbPhase.VENCRYPT_HANDOFF) reject("securityUnavailable")
            if (phase == VncRfbPhase.ACTIVE && pendingFrameSequence != null) {
                reject("frameBackpressure")
            }
            append(bytes)
            val events = mutableListOf<VncRfbEvent>()
            while (true) {
                val progressed = when (phase) {
                    VncRfbPhase.VERSION -> parseVersion()?.let(events::add) != null
                    VncRfbPhase.SECURITY_TYPES -> parseSecurityTypes()?.let(events::add) != null
                    VncRfbPhase.VENCRYPT_HANDOFF -> false
                    VncRfbPhase.SERVER_INIT -> parseServerInit()?.let(events::addAll) != null
                    VncRfbPhase.ACTIVE -> parseFramebufferUpdate()?.let(events::add) != null
                    VncRfbPhase.CANCELLED,
                    VncRfbPhase.FAILED,
                    -> false
                }
                if (!progressed) break
            }
            events
        } catch (error: VncRfbFailure) {
            failClosed(error)
        } catch (_: Exception) {
            failClosed(VncRfbFailure("malformedProtocol"))
        }
    }

    fun markSecureAuthenticated(): List<VncRfbEvent> {
        ensureOpen()
        return try {
            if (phase != VncRfbPhase.VENCRYPT_HANDOFF || pending.isNotEmpty()) {
                reject("securityUnavailable")
            }
            phase = VncRfbPhase.SERVER_INIT
            listOf(VncRfbOutbound(byteArrayOf(1)))
        } catch (error: VncRfbFailure) {
            failClosed(error)
        }
    }

    fun setForeground(foreground: Boolean) {
        if (!foreground) cancel()
    }

    fun acknowledgeFrame(sequence: Long): VncRfbOutbound {
        ensureOpen()
        return try {
            if (phase != VncRfbPhase.ACTIVE || pendingFrameSequence != sequence) {
                reject("staleFrame")
            }
            pendingFrameSequence = null
            VncRfbOutbound(framebufferRequest(framebufferWidth, framebufferHeight, incremental = true))
        } catch (error: VncRfbFailure) {
            failClosed(error)
        }
    }

    fun cancel() {
        if (phase == VncRfbPhase.CANCELLED || phase == VncRfbPhase.FAILED) return
        wipePending()
        framebufferWidth = 0
        framebufferHeight = 0
        pendingFrameSequence = null
        phase = VncRfbPhase.CANCELLED
    }

    private fun parseVersion(): VncRfbEvent? {
        if (pending.size < VERSION.size) return null
        if (!pending.copyOfRange(0, VERSION.size).contentEquals(VERSION)) {
            reject("rfbVersionUnavailable")
        }
        consume(VERSION.size)
        phase = VncRfbPhase.SECURITY_TYPES
        return VncRfbOutbound(VERSION)
    }

    private fun parseSecurityTypes(): VncRfbEvent? {
        if (pending.isEmpty()) return null
        val count = unsigned(pending[0])
        if (count !in 1..MAX_SECURITY_TYPES) reject("securityUnavailable")
        if (pending.size < count + 1) return null
        var supportsVencrypt = false
        for (index in 1..count) {
            if (unsigned(pending[index]) == VENCRYPT_SECURITY_TYPE) supportsVencrypt = true
        }
        if (!supportsVencrypt) reject("securityUnavailable")
        consume(count + 1)
        if (pending.isNotEmpty()) reject("malformedProtocol")
        phase = VncRfbPhase.VENCRYPT_HANDOFF
        return VncRfbOutbound(byteArrayOf(VENCRYPT_SECURITY_TYPE.toByte()))
    }

    private fun parseServerInit(): List<VncRfbEvent>? {
        if (pending.size < SERVER_INIT_FIXED_BYTES) return null
        val nameLength = unsigned32(pending, 20)
        if (nameLength > MAX_SERVER_NAME_BYTES) reject("malformedProtocol")
        val totalLength = SERVER_INIT_FIXED_BYTES + nameLength.toInt()
        if (pending.size < totalLength) return null

        val width = unsigned16(pending, 0)
        val height = unsigned16(pending, 2)
        if (width !in 1..MAX_DIMENSION || height !in 1..MAX_DIMENSION ||
            width.toLong() * height > MAX_PIXELS
        ) {
            reject("frameTooLarge")
        }
        if (unsigned(pending[4]) != 32 || unsigned(pending[5]) != 24 ||
            unsigned(pending[6]) != 0 || unsigned(pending[7]) != 1 ||
            unsigned16(pending, 8) != 255 || unsigned16(pending, 10) != 255 ||
            unsigned16(pending, 12) != 255 || unsigned(pending[14]) != 0 ||
            unsigned(pending[15]) != 8 || unsigned(pending[16]) != 16 ||
            pending.sliceArray(17..19).any { it.toInt() != 0 }
        ) {
            reject("framebufferUnavailable")
        }
        validateServerName(pending.copyOfRange(SERVER_INIT_FIXED_BYTES, totalLength))
        consume(totalLength)
        framebufferWidth = width
        framebufferHeight = height
        phase = VncRfbPhase.ACTIVE
        return listOf(
            VncRfbReady(width, height),
            VncRfbOutbound(setPixelFormat()),
            VncRfbOutbound(setRawEncoding()),
            VncRfbOutbound(framebufferRequest(width, height, incremental = false)),
        )
    }

    private fun parseFramebufferUpdate(): VncRfbEvent? {
        if (pending.size < FRAMEBUFFER_UPDATE_HEADER_BYTES) return null
        if (unsigned(pending[0]) != 0 || unsigned(pending[1]) != 0) {
            reject("malformedFrame")
        }
        val rectangleCount = unsigned16(pending, 2)
        if (rectangleCount !in 1..MAX_RECTANGLES) reject("malformedFrame")

        var cursor = FRAMEBUFFER_UPDATE_HEADER_BYTES
        var wireBytes = 0L
        val descriptors = ArrayList<RectangleDescriptor>(rectangleCount)
        repeat(rectangleCount) {
            if (pending.size - cursor < RECTANGLE_HEADER_BYTES) return null
            val x = unsigned16(pending, cursor)
            val y = unsigned16(pending, cursor + 2)
            val width = unsigned16(pending, cursor + 4)
            val height = unsigned16(pending, cursor + 6)
            val encoding = signed32(pending, cursor + 8)
            if (width == 0 || height == 0 || encoding != RAW_ENCODING ||
                x.toLong() + width > framebufferWidth ||
                y.toLong() + height > framebufferHeight
            ) {
                reject("malformedFrame")
            }
            val byteLength = width.toLong() * height * BYTES_PER_PIXEL
            wireBytes += byteLength
            if (byteLength > MAX_FRAME_BYTES || wireBytes > MAX_FRAME_BYTES) {
                reject("frameTooLarge")
            }
            cursor += RECTANGLE_HEADER_BYTES
            if (byteLength > pending.size - cursor) return null
            descriptors += RectangleDescriptor(x, y, width, height, cursor, byteLength.toInt())
            cursor += byteLength.toInt()
        }

        val rectangles = descriptors.map { descriptor ->
            val rgba = ByteArray(descriptor.byteLength)
            var source = descriptor.pixelOffset
            var destination = 0
            while (destination < rgba.size) {
                rgba[destination] = pending[source]
                rgba[destination + 1] = pending[source + 1]
                rgba[destination + 2] = pending[source + 2]
                rgba[destination + 3] = 0xff.toByte()
                source += BYTES_PER_PIXEL
                destination += BYTES_PER_PIXEL
            }
            VncRfbRectangle(
                descriptor.x,
                descriptor.y,
                descriptor.width,
                descriptor.height,
                rgba,
            ).also { rgba.fill(0) }
        }
        consume(cursor)
        val sequence = nextFrameSequence++
        pendingFrameSequence = sequence
        return VncRfbFrame(sequence, rectangles, wireBytes.toInt())
    }

    private fun append(bytes: ByteArray) {
        val nextSize = pending.size.toLong() + bytes.size
        if (nextSize > MAX_BUFFER_BYTES) reject("frameTooLarge")
        val next = ByteArray(nextSize.toInt())
        pending.copyInto(next)
        bytes.copyInto(next, pending.size)
        pending.fill(0)
        pending = next
    }

    private fun consume(length: Int) {
        if (length !in 0..pending.size) reject("malformedProtocol")
        val remaining = pending.copyOfRange(length, pending.size)
        pending.fill(0)
        pending = remaining
    }

    private fun validateServerName(bytes: ByteArray) {
        try {
            val decoder = StandardCharsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
            val name = decoder.decode(ByteBuffer.wrap(bytes))
            if (name.any { it.code < 32 || it.code == 127 }) reject("malformedProtocol")
        } catch (error: VncRfbFailure) {
            throw error
        } catch (_: Exception) {
            reject("malformedProtocol")
        } finally {
            bytes.fill(0)
        }
    }

    private fun ensureOpen() {
        when (phase) {
            VncRfbPhase.CANCELLED -> throw VncRfbFailure("cancelled")
            VncRfbPhase.FAILED -> throw failure ?: VncRfbFailure("malformedProtocol")
            else -> Unit
        }
    }

    private fun reject(code: String): Nothing = throw VncRfbFailure(code)

    private fun failClosed(error: VncRfbFailure): Nothing {
        wipePending()
        framebufferWidth = 0
        framebufferHeight = 0
        pendingFrameSequence = null
        failure = error
        phase = VncRfbPhase.FAILED
        throw error
    }

    private fun wipePending() {
        pending.fill(0)
        pending = ByteArray(0)
    }

    private data class RectangleDescriptor(
        val x: Int,
        val y: Int,
        val width: Int,
        val height: Int,
        val pixelOffset: Int,
        val byteLength: Int,
    )

    companion object {
        private val VERSION = "RFB 003.008\n".encodeToByteArray()
        private const val VENCRYPT_SECURITY_TYPE = 19
        private const val RAW_ENCODING = 0
        private const val BYTES_PER_PIXEL = 4
        private const val MAX_SECURITY_TYPES = 32
        private const val MAX_SERVER_NAME_BYTES = 4096L
        private const val MAX_DIMENSION = 8192
        private const val MAX_PIXELS = 33_554_432L
        private const val MAX_FRAME_BYTES = 16L * 1024 * 1024
        private const val MAX_BUFFER_BYTES = MAX_FRAME_BYTES + 4096
        private const val MAX_RECTANGLES = 256
        private const val SERVER_INIT_FIXED_BYTES = 24
        private const val FRAMEBUFFER_UPDATE_HEADER_BYTES = 4
        private const val RECTANGLE_HEADER_BYTES = 12

        private fun unsigned(value: Byte) = value.toInt() and 0xff

        private fun unsigned16(bytes: ByteArray, offset: Int): Int =
            unsigned(bytes[offset]) shl 8 or unsigned(bytes[offset + 1])

        private fun unsigned32(bytes: ByteArray, offset: Int): Long =
            (unsigned(bytes[offset]).toLong() shl 24) or
                (unsigned(bytes[offset + 1]).toLong() shl 16) or
                (unsigned(bytes[offset + 2]).toLong() shl 8) or
                unsigned(bytes[offset + 3]).toLong()

        private fun signed32(bytes: ByteArray, offset: Int): Int =
            (unsigned(bytes[offset]) shl 24) or
                (unsigned(bytes[offset + 1]) shl 16) or
                (unsigned(bytes[offset + 2]) shl 8) or
                unsigned(bytes[offset + 3])

        private fun setPixelFormat() = byteArrayOf(
            0, 0, 0, 0,
            32, 24, 0, 1,
            0, 0xff.toByte(), 0, 0xff.toByte(), 0, 0xff.toByte(),
            0, 8, 16, 0, 0, 0,
        )

        private fun setRawEncoding() = byteArrayOf(2, 0, 0, 1, 0, 0, 0, 0)

        private fun framebufferRequest(width: Int, height: Int, incremental: Boolean) =
            byteArrayOf(
                3, (if (incremental) 1 else 0).toByte(), 0, 0, 0, 0,
                (width ushr 8).toByte(), width.toByte(),
                (height ushr 8).toByte(), height.toByte(),
            )
    }
}
