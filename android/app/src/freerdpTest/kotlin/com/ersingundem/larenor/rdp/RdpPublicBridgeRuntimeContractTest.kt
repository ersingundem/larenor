package com.ersingundem.larenor.rdp

import android.app.Application
import io.flutter.embedding.engine.FlutterJNI
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.StandardMethodCodec
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class RdpPublicBridgeRuntimeContractTest {
    @Test
    fun pinnedFlutterMessengerWrapperResolvesRegisteredHandlerUnderItsActualLock() {
        val dartClass = Class.forName(DART_MESSENGER)
        val dartConstructor = dartClass.getDeclaredConstructor(FlutterJNI::class.java).apply {
            isAccessible = true
        }
        val dart = dartConstructor.newInstance(FlutterJNI()) as BinaryMessenger
        val expected = BinaryMessenger.BinaryMessageHandler { _, _ -> }
        dart.setMessageHandler(CHANNEL, expected)

        val wrapperClass = Class.forName(DEFAULT_BINARY_MESSENGER)
        val wrapperConstructor = wrapperClass.getDeclaredConstructor(dartClass).apply {
            isAccessible = true
        }
        val wrapper = wrapperConstructor.newInstance(dart)

        assertSame(expected, registeredHandler(wrapper, CHANNEL))
    }

    @Test
    fun pinnedStandardMethodCodecRequiresReadableRequestAndReplyBuffers() {
        val codec = StandardMethodCodec.INSTANCE
        val encodedCall = codec.encodeMethodCall(MethodCall("capabilities", null))
        assertEquals(encodedCall.limit(), encodedCall.position())
        encodedCall.flip()
        assertEquals("capabilities", codec.decodeMethodCall(encodedCall).method)

        val encodedReply = codec.encodeSuccessEnvelope(mapOf("schemaVersion" to 4))
        assertEquals(encodedReply.limit(), encodedReply.position())
        encodedReply.flip()
        assertEquals(mapOf("schemaVersion" to 4), codec.decodeEnvelope(encodedReply))
    }

    private fun registeredHandler(wrapper: Any, channel: String): BinaryMessenger.BinaryMessageHandler {
        assertEquals(DEFAULT_BINARY_MESSENGER, wrapper.javaClass.name)
        val messengerField = wrapper.javaClass.getDeclaredField("messenger").apply {
            isAccessible = true
        }
        val messenger = requireNotNull(messengerField.get(wrapper))
        assertEquals(DART_MESSENGER, messenger.javaClass.name)
        val handlersField = messenger.javaClass.getDeclaredField("messageHandlers").apply {
            isAccessible = true
        }
        val lockField = messenger.javaClass.getDeclaredField("handlersLock").apply {
            isAccessible = true
        }
        val handlers = handlersField.get(messenger) as Map<*, *>
        val lock = requireNotNull(lockField.get(messenger))
        val info = synchronized(lock) { handlers[channel] }
        val handlerField = requireNotNull(info).javaClass.getDeclaredField("handler").apply {
            isAccessible = true
        }
        return handlerField.get(info) as BinaryMessenger.BinaryMessageHandler
    }

    companion object {
        private const val CHANNEL = "com.ersingundem.larenor/rdp"
        private const val DEFAULT_BINARY_MESSENGER =
            "io.flutter.embedding.engine.dart.DartExecutor\$DefaultBinaryMessenger"
        private const val DART_MESSENGER =
            "io.flutter.embedding.engine.dart.DartMessenger"
    }
}
