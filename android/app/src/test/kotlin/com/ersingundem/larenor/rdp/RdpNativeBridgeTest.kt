package com.ersingundem.larenor.rdp

import android.app.AppOpsManager
import android.app.Application
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class RdpNativeBridgeTest {
    private class Messenger : BinaryMessenger {
        override fun send(channel: String, message: ByteBuffer?) = Unit
        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) = Unit
        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) = Unit
    }

    private class Result : MethodChannel.Result {
        @Volatile var value: Any? = null
        @Volatile var error: String? = null
        @Volatile var done = false
        override fun success(result: Any?) { value = result; done = true }
        override fun error(code: String, message: String?, details: Any?) { error = code; done = true }
        override fun notImplemented() { error = "missing"; done = true }
    }

    private class Sink : EventChannel.EventSink {
        override fun success(event: Any?) = Unit
        override fun error(code: String, message: String?, details: Any?) = Unit
        override fun endOfStream() = Unit
    }

    private class ClipboardRuntime(
        private val advertisedCapabilities: Map<String, Any?>,
    ) : RdpJniRuntime {
        val inputs = mutableListOf<ByteArray>()
        val allInputs = mutableListOf<RdpJniInput>()
        private lateinit var listener: RdpJniOperation.Listener

        override fun identity() = RdpFreeRdpIdentity(
            RdpFreeRdpPackage.VERSION,
            RdpFreeRdpPackage.SOURCE_COMMIT,
            RdpFreeRdpPackage.SOURCE_SHA256,
            "x86_64",
            5,
            emptySet(),
        )

        override fun capabilities() = advertisedCapabilities

        override fun create(
            request: RdpNativeRequest,
            plan: RdpNativeNegotiated,
            listener: RdpJniOperation.Listener,
        ) = object : RdpJniOperation {
            init { this@ClipboardRuntime.listener = listener }
            override val unicodeInputSupported = true
            override val relativePointerSupported = true
            override fun start(password: CharArray, gatewayPassword: CharArray?): Boolean {
                listener.onSecurity(RdpJniSecurity("TLSv1.2", true, PIN))
                return true
            }

            override fun input(sequence: Long, event: RdpJniInput): Boolean {
                allInputs += event
                if (event is RdpJniInput.Key) return true
                if (event !is RdpJniInput.Channel) return true
                val clipboard = event
                if (clipboard.kind != RdpJniChannel.CLIPBOARD) return false
                inputs += clipboard.payload.copyOf()
                return true
            }

            override fun resize(sequence: Long, display: RdpNativeDisplay) = true
            override fun acknowledgeFrame(sequence: Long) = true
            override fun close() = Unit
            override fun detach() = Unit
        }

        fun frame(sequence: Long, width: Int = 1280, height: Int = 800) {
            listener.onFrame(
                RdpNativeFrame.take(
                    sequence,
                    width,
                    height,
                    width * 4,
                    ByteBuffer.allocateDirect(width * height * 4),
                ),
            )
        }

        fun audio(observation: RdpRemoteAudioObservation) {
            listener.onRemoteAudio(observation)
        }

        fun microphone(observation: RdpMicrophoneCaptureObservation) {
            listener.onMicrophoneCapture(observation)
        }
    }

    private class OpenClipboardBridge(
        val bridge: RdpNativeBridge,
        val runtime: ClipboardRuntime,
        val activity: org.robolectric.android.controller.ActivityController<android.app.Activity>,
    ) : AutoCloseable {
        override fun close() {
            bridge.dispose()
            activity.pause().stop().destroy()
        }
    }

    @Test
    fun productAdmissionRejectsBothGatewayProbesBeforeCompiledRuntimeAndWipesPassword() {
        val inspections = AtomicInteger()
        val compiled = ClipboardRuntime(availableCapabilities())
        val runtime = object : RdpJniRuntime by compiled {
            override fun capabilities() = availableCapabilities() + mapOf(
                "security" to mapOf(
                    "tls" to true, "certificatePinning" to true, "nla" to true,
                    "rdGateway" to true,
                ),
            )
            override fun inspectGateway(
                targetHost: String, targetPort: Int, targetUsername: String,
                gateway: RdpJniGatewayEndpoint,
            ): RdpJniCertificateProbeOperation {
                inspections.incrementAndGet()
                throw AssertionError("Unadmitted probe reached compiled runtime")
            }
            override fun inspectTargetThroughGateway(
                targetHost: String, targetPort: Int, targetUsername: String,
                targetDomain: String, gateway: RdpNativeGateway, gatewayPassword: CharArray,
            ): RdpJniCertificateProbeOperation {
                inspections.incrementAndGet()
                throw AssertionError("Unadmitted probe reached compiled runtime")
            }
        }
        val activity = Robolectric.buildActivity(android.app.Activity::class.java).setup().visible()
            .windowFocusChanged(true)
        val bridge = RdpNativeBridge(activity.get(), Messenger(), runtime)
        try {
            bridge.setResumed(true)
            bridge.onListen(REQUEST_ID, Sink())
            val activated = Result()
            bridge.onMethodCall(MethodCall("activate", mapOf("requestId" to REQUEST_ID)), activated)
            assertNull(activated.error)
            val peer = mapOf("host" to "fixture.invalid", "port" to 443, "username" to "fixture")
            val gatewayResult = Result()
            bridge.onMethodCall(MethodCall("inspectGateway", mapOf(
                "schemaVersion" to 6, "requestId" to REQUEST_ID,
                "target" to peer, "gateway" to (peer + ("domain" to "TEST")),
            )), gatewayResult)
            assertEquals("gatewayUnavailable", gatewayResult.error)
            val password = "private-gateway-password".encodeToByteArray()
            val targetResult = Result()
            bridge.onMethodCall(MethodCall("inspectTargetThroughGateway", mapOf(
                "schemaVersion" to 6, "requestId" to REQUEST_ID,
                "target" to (peer + ("domain" to "TEST")),
                "gateway" to (peer + mapOf("domain" to "TEST", "certificateFingerprint" to PIN)),
                "gatewayPassword" to password,
            )), targetResult)
            assertEquals("gatewayUnavailable", targetResult.error)
            assertTrue(password.all { it == 0.toByte() })
            assertEquals(0, inspections.get())
        } finally {
            bridge.dispose()
            activity.pause().stop().destroy()
        }
    }

    @Test
    fun blockedOpenRejectsSecondNetworkJobAndClosesSecretBuffers() {
        val started = CountDownLatch(1)
        val release = CountDownLatch(1)
        val creates = AtomicInteger()
        val capturedPassword = AtomicReference<CharArray>()
        val runtime = object : RdpJniRuntime {
            override fun identity() = RdpFreeRdpIdentity(
                RdpFreeRdpPackage.VERSION,
                RdpFreeRdpPackage.SOURCE_COMMIT,
                RdpFreeRdpPackage.SOURCE_SHA256,
                "x86_64",
                5,
                emptySet(),
            )

            override fun capabilities() = availableCapabilities()

            override fun create(
                request: RdpNativeRequest,
                plan: RdpNativeNegotiated,
                listener: RdpJniOperation.Listener,
            ): RdpJniOperation {
                creates.incrementAndGet()
                return object : RdpJniOperation {
                    override fun start(password: CharArray, gatewayPassword: CharArray?): Boolean {
                        capturedPassword.set(password)
                        started.countDown()
                        release.await(2, TimeUnit.SECONDS)
                        return true
                    }
                    override fun input(sequence: Long, event: RdpJniInput) = true
                    override fun resize(sequence: Long, display: RdpNativeDisplay) = true
                    override fun acknowledgeFrame(sequence: Long) = true
                    override fun close() = Unit
                    override fun detach() = Unit
                }
            }
        }
        val activity = Robolectric.buildActivity(android.app.Activity::class.java).setup().visible()
            .windowFocusChanged(true)
        val bridge = RdpNativeBridge(activity.get(), Messenger(), runtime)
        try {
            bridge.setResumed(true)
            bridge.onListen(REQUEST_ID, Sink())
            val activated = Result()
            bridge.onMethodCall(MethodCall("activate", mapOf("requestId" to REQUEST_ID)), activated)
            assertNull(activated.error)

            val password = "secret".encodeToByteArray()
            val gatewayPassword = ByteArray(0)
            val opening = Result()
            bridge.onMethodCall(MethodCall("open", mapOf(
                "schemaVersion" to 4,
                "request" to request(), "requestId" to REQUEST_ID,
                "password" to password, "gatewayPassword" to gatewayPassword,
            )), opening)
            assertTrue(started.await(1, TimeUnit.SECONDS))
            assertTrue(password.all { it == 0.toByte() })
            assertTrue(gatewayPassword.all { it == 0.toByte() })

            val competing = Result()
            bridge.onMethodCall(MethodCall("inspect", mapOf(
                "targetHost" to "fixture.invalid", "targetPort" to 3389, "username" to "fixture",
            )), competing)
            assertEquals("busy", competing.error)
            assertEquals(1, creates.get())

            release.countDown()
            await(opening)
            assertNull(opening.error)
            assertTrue(capturedPassword.get().all { it == '\u0000' })
        } finally {
            release.countDown()
            bridge.dispose()
            activity.pause().stop().destroy()
        }
    }

    @Test
    fun clipboardChannelUsesExactOwnedWireAndWipesCallerBytes() {
        openClipboardBridge(RdpClipboardMode.CLIENT_TO_REMOTE).use { fixture ->
            val payload = "Merhaba dünya\n\tpanoya".encodeToByteArray()
            val expected = payload.copyOf()
            val result = Result()

            fixture.bridge.onMethodCall(MethodCall("input", clipboardInput(payload)), result)

            assertNull(result.error)
            assertEquals(listOf(expected.toList()), fixture.runtime.inputs.map(ByteArray::toList))
            assertTrue(payload.all { it == 0.toByte() })
        }
    }

    @Test
    fun cancelledBlockedOpenCannotPublishToReplacementEventOwner() {
        assertBlockedOpenRetires { bridge ->
            bridge.onCancel(REQUEST_ID)
            bridge.onListen(FOREIGN_REQUEST_ID, Sink())
        }
    }

    @Test
    fun focusRestoreCannotReviveBlockedOpenOrDispatchInput() {
        assertBlockedOpenRetires { bridge ->
            bridge.setWindowFocused(false)
            bridge.setWindowFocused(true)
        }
    }

    private fun assertBlockedOpenRetires(retire: (RdpNativeBridge) -> Unit) {
        val started = CountDownLatch(1)
        val release = CountDownLatch(1)
        val closes = AtomicInteger()
        val inputs = AtomicInteger()
        val publishedEvents = AtomicInteger()
        val capturedSecret = AtomicReference<CharArray>()
        val runtime = object : RdpJniRuntime {
            override fun identity() = RdpFreeRdpIdentity(
                RdpFreeRdpPackage.VERSION, RdpFreeRdpPackage.SOURCE_COMMIT,
                RdpFreeRdpPackage.SOURCE_SHA256, "x86_64", 5, emptySet(),
            )
            override fun capabilities() = availableCapabilities()
            override fun create(
                request: RdpNativeRequest,
                plan: RdpNativeNegotiated,
                listener: RdpJniOperation.Listener,
            ) = object : RdpJniOperation {
                override fun start(password: CharArray, gatewayPassword: CharArray?): Boolean {
                    capturedSecret.set(password)
                    listener.onSecurity(RdpJniSecurity("TLSv1.2", true, PIN))
                    started.countDown()
                    check(release.await(2, TimeUnit.SECONDS))
                    return true
                }
                override fun input(sequence: Long, event: RdpJniInput): Boolean {
                    inputs.incrementAndGet()
                    return true
                }
                override fun resize(sequence: Long, display: RdpNativeDisplay) = true
                override fun acknowledgeFrame(sequence: Long) = true
                override fun close() { closes.incrementAndGet() }
                override fun detach() = Unit
            }
        }
        val activity = Robolectric.buildActivity(android.app.Activity::class.java).setup().visible()
            .windowFocusChanged(true)
        val bridge = RdpNativeBridge(activity.get(), Messenger(), runtime)
        try {
            bridge.setResumed(true)
            bridge.onListen(REQUEST_ID, object : EventChannel.EventSink {
                override fun success(event: Any?) { publishedEvents.incrementAndGet() }
                override fun error(code: String, message: String?, details: Any?) { publishedEvents.incrementAndGet() }
                override fun endOfStream() { publishedEvents.incrementAndGet() }
            })
            val opening = Result()
            val bytes = "private-target".encodeToByteArray()
            bridge.onMethodCall(MethodCall("open", mapOf(
                "schemaVersion" to 4, "request" to request(), "requestId" to REQUEST_ID,
                "password" to bytes, "gatewayPassword" to ByteArray(0),
            )), opening)
            assertTrue(started.await(1, TimeUnit.SECONDS))
            assertTrue(bytes.all { it == 0.toByte() })
            retire(bridge)
            release.countDown()
            await(opening)
            assertEquals("staleSession", opening.error)
            assertTrue(closes.get() >= 1)
            assertEquals(0, publishedEvents.get())
            val input = Result()
            bridge.onMethodCall(MethodCall("input", clipboardInput("private".encodeToByteArray())), input)
            await(input)
            assertEquals("staleSession", input.error)
            assertEquals(0, inputs.get())
            assertTrue(capturedSecret.get().all { it == '\u0000' })
        } finally {
            release.countDown()
            bridge.dispose()
            activity.pause().stop().destroy()
        }
    }

    @Test
    fun openPublishesNegotiatedUnicodeAndUnsupportedKeyIsNonFatal() {
        openClipboardBridge(RdpClipboardMode.DISABLED).use { fixture ->
            val unsupported = Result()
            fixture.bridge.onMethodCall(MethodCall("input", mapOf(
                "schemaVersion" to 4,
                "requestId" to REQUEST_ID,
                "sequence" to 1L,
                "kind" to "key",
                "physicalKey" to 0x000c00e9L,
                "down" to true,
            )), unsupported)
            assertNull(unsupported.error)
            assertEquals(false, unsupported.value)

            val supported = Result()
            fixture.bridge.onMethodCall(MethodCall("input", mapOf(
                "schemaVersion" to 4,
                "requestId" to REQUEST_ID,
                "sequence" to 1L,
                "kind" to "key",
                "physicalKey" to 0x00070004L,
                "down" to true,
            )), supported)
            assertNull(supported.error)
            assertNull(supported.value)
        }
    }

    @Test
    fun pointerWireRequiresTheExactAcknowledgedFrameAndLayoutTuple() {
        openClipboardBridge(RdpClipboardMode.DISABLED).use { fixture ->
            fixture.runtime.frame(1)
            val ack = Result()
            fixture.bridge.onMethodCall(MethodCall("ackFrame", mapOf(
                "schemaVersion" to 4,
                "requestId" to REQUEST_ID,
                "frameSequence" to 1L,
            )), ack)
            assertNull(ack.error)

            val accepted = Result()
            fixture.bridge.onMethodCall(MethodCall("input", mapOf(
                "schemaVersion" to 4,
                "requestId" to REQUEST_ID,
                "sequence" to 1L,
                "kind" to "absolutePointer",
                "frameSequence" to 1L,
                "width" to 1280,
                "height" to 800,
                "displayLayoutRevision" to 1L,
                "x" to .25,
                "y" to .75,
                "buttons" to 1,
            )), accepted)
            assertNull(accepted.error)
            assertEquals(
                RdpJniInput.AbsolutePointer(1280, 800, .25, .75, 1),
                fixture.runtime.allInputs.last(),
            )
        }

        openClipboardBridge(RdpClipboardMode.DISABLED).use { fixture ->
            fixture.runtime.frame(1)
            val ack = Result()
            fixture.bridge.onMethodCall(MethodCall("ackFrame", mapOf(
                "schemaVersion" to 4,
                "requestId" to REQUEST_ID,
                "frameSequence" to 1L,
            )), ack)
            assertNull(ack.error)
            val stale = Result()
            fixture.bridge.onMethodCall(MethodCall("input", mapOf(
                "schemaVersion" to 4,
                "requestId" to REQUEST_ID,
                "sequence" to 1L,
                "kind" to "verticalWheel",
                "frameSequence" to 1L,
                "width" to 1280,
                "height" to 800,
                "displayLayoutRevision" to 2L,
                "wheelDelta" to 120,
            )), stale)
            assertEquals("staleSession", stale.error)
            assertTrue(fixture.runtime.allInputs.isEmpty())
        }
    }

    @Test
    fun audioObservationIsExactCurrentForegroundReadOnlyAndNeedsCompletionForProof() {
        openClipboardBridge(RdpClipboardMode.DISABLED, audio = true).use { fixture ->
            val pending = Result()
            fixture.bridge.onMethodCall(MethodCall("audioObservation", mapOf(
                "schemaVersion" to 4,
                "requestId" to REQUEST_ID,
            )), pending)
            assertNull(pending.error)
            assertEquals(
                mapOf(
                    "schemaVersion" to 4,
                    "requestId" to REQUEST_ID,
                    "state" to "pending",
                    "deviceOpen" to false,
                    "acceptedCount" to 0L,
                    "completedCount" to 0L,
                ),
                pending.value,
            )

            fixture.runtime.audio(
                RdpRemoteAudioObservation(RdpRemoteAudioState.DEVICE_OPEN, true, 0, 0),
            )
            fixture.runtime.audio(
                RdpRemoteAudioObservation(RdpRemoteAudioState.PLAYING, true, 1, 0),
            )
            val acceptedOnly = Result()
            fixture.bridge.onMethodCall(MethodCall("audioObservation", mapOf(
                "schemaVersion" to 4,
                "requestId" to REQUEST_ID,
            )), acceptedOnly)
            assertNull(acceptedOnly.error)
            @Suppress("UNCHECKED_CAST")
            val acceptedMap = acceptedOnly.value as Map<String, Any>
            assertEquals("playing", acceptedMap["state"])
            assertEquals(0L, acceptedMap["completedCount"])

            fixture.runtime.audio(
                RdpRemoteAudioObservation(RdpRemoteAudioState.PLAYING, true, 1, 1),
            )
            val observed = Result()
            fixture.bridge.onMethodCall(MethodCall("audioObservation", mapOf(
                "schemaVersion" to 4,
                "requestId" to REQUEST_ID,
            )), observed)
            @Suppress("UNCHECKED_CAST")
            val observedMap = observed.value as Map<String, Any>
            assertEquals(1L, observedMap["completedCount"])

            val foreign = Result()
            fixture.bridge.onMethodCall(MethodCall("audioObservation", mapOf(
                "schemaVersion" to 4,
                "requestId" to FOREIGN_REQUEST_ID,
            )), foreign)
            assertEquals("staleSession", foreign.error)
            assertEquals(0, fixture.runtime.allInputs.size)
        }
    }

    @Test
    fun disabledOrBackgroundAudioObservationFailsWithoutDispatchOrReplay() {
        openClipboardBridge(RdpClipboardMode.DISABLED).use { fixture ->
            val unavailable = Result()
            fixture.bridge.onMethodCall(MethodCall("audioObservation", mapOf(
                "schemaVersion" to 4,
                "requestId" to REQUEST_ID,
            )), unavailable)
            assertEquals("channelUnavailable", unavailable.error)

            val stillCurrent = Result()
            fixture.bridge.onMethodCall(MethodCall("input", mapOf(
                "schemaVersion" to 4,
                "requestId" to REQUEST_ID,
                "sequence" to 1L,
                "kind" to "key",
                "physicalKey" to 0x00070004L,
                "down" to true,
            )), stillCurrent)
            assertNull(stillCurrent.error)
            assertEquals(1, fixture.runtime.allInputs.size)

            fixture.bridge.setWindowFocused(false)
            val background = Result()
            fixture.bridge.onMethodCall(MethodCall("audioObservation", mapOf(
                "schemaVersion" to 4,
                "requestId" to REQUEST_ID,
            )), background)
            assertEquals("foregroundRequired", background.error)
            assertEquals(1, fixture.runtime.allInputs.size)
        }
    }

    @Test
    fun microphonePermissionIsExplicitCancellableAndPromptFocusLossIsNotAReceipt() {
        val activity = Robolectric.buildActivity(android.app.Activity::class.java).setup().visible()
            .windowFocusChanged(true)
        val bridge = RdpNativeBridge(activity.get(), Messenger(), ClipboardRuntime(
            availableCapabilities(microphone = true),
        ))
        try {
            bridge.setResumed(true)
            bridge.onListen(REQUEST_ID, Sink())
            val requested = Result()
            bridge.onMethodCall(MethodCall("requestMicrophonePermission", mapOf(
                "schemaVersion" to 4,
                "requestId" to REQUEST_ID,
            )), requested)
            assertEquals(false, requested.done)
            val permission = Shadows.shadowOf(activity.get()).lastRequestedPermission
            assertArrayEquals(arrayOf(android.Manifest.permission.RECORD_AUDIO), permission.requestedPermissions)
            assertEquals(RdpMicrophonePermissionBroker.REQUEST_CODE, permission.requestCode)

            bridge.setWindowFocused(false)
            bridge.setResumed(false)
            assertEquals(false, requested.done)
            Shadows.shadowOf(activity.get().application).grantPermissions(
                android.Manifest.permission.RECORD_AUDIO,
            )
            assertTrue(bridge.onRequestPermissionsResult(
                RdpMicrophonePermissionBroker.REQUEST_CODE,
                arrayOf(android.Manifest.permission.RECORD_AUDIO),
                intArrayOf(android.content.pm.PackageManager.PERMISSION_GRANTED),
            ))
            assertEquals(false, requested.done)
            bridge.setResumed(true)
            bridge.setWindowFocused(true)
            assertEquals(mapOf(
                "schemaVersion" to 4,
                "requestId" to REQUEST_ID,
                "granted" to true,
            ), requested.value)

            Shadows.shadowOf(activity.get().application).denyPermissions(
                android.Manifest.permission.RECORD_AUDIO,
            )
            val backgrounded = Result()
            bridge.onMethodCall(MethodCall("requestMicrophonePermission", mapOf(
                "schemaVersion" to 4,
                "requestId" to REQUEST_ID,
            )), backgrounded)
            bridge.setStopped()
            assertEquals("cancelled", backgrounded.error)

            Shadows.shadowOf(activity.get().application).denyPermissions(
                android.Manifest.permission.RECORD_AUDIO,
            )
            val pending = Result()
            bridge.onMethodCall(MethodCall("requestMicrophonePermission", mapOf(
                "schemaVersion" to 4,
                "requestId" to REQUEST_ID,
            )), pending)
            val cancelled = Result()
            bridge.onMethodCall(MethodCall("cancelMicrophonePermission", mapOf(
                "schemaVersion" to 4,
                "requestId" to REQUEST_ID,
            )), cancelled)
            assertEquals("cancelled", pending.error)
            assertNull(cancelled.error)
            assertNull(cancelled.value)
            assertTrue(bridge.onRequestPermissionsResult(
                RdpMicrophonePermissionBroker.REQUEST_CODE,
                arrayOf(android.Manifest.permission.RECORD_AUDIO),
                intArrayOf(android.content.pm.PackageManager.PERMISSION_GRANTED),
            ))
            assertEquals("cancelled", pending.error)

            val password = "secret".encodeToByteArray()
            val gatewayPassword = "private".encodeToByteArray()
            val missing = Result()
            bridge.onMethodCall(MethodCall("open", mapOf(
                "schemaVersion" to 4,
                "request" to request(microphone = true),
                "requestId" to REQUEST_ID,
                "password" to password,
                "gatewayPassword" to gatewayPassword,
            )), missing)
            assertEquals("microphonePermissionRequired", missing.error)
            assertTrue(password.all { it == 0.toByte() })
            assertTrue(gatewayPassword.all { it == 0.toByte() })
        } finally {
            bridge.dispose()
            activity.pause().stop().destroy()
        }
    }

    @Test
    fun microphonePermissionRevocationObservesOnlyOwnedRecordAudioAppOp() {
        val activity = Robolectric.buildActivity(android.app.Activity::class.java).setup().visible()
            .windowFocusChanged(true)
        Shadows.shadowOf(activity.get().application).grantPermissions(
            android.Manifest.permission.RECORD_AUDIO,
        )
        val revocations = AtomicInteger()
        val broker = RdpMicrophonePermissionBroker(activity.get(), revocations::incrementAndGet)
        try {
            Shadows.shadowOf(activity.get().application).denyPermissions(
                android.Manifest.permission.RECORD_AUDIO,
            )
            broker.onAppOpChanged(AppOpsManager.OPSTR_CAMERA, activity.get().packageName)
            broker.onAppOpChanged(AppOpsManager.OPSTR_RECORD_AUDIO, "foreign.invalid")
            Shadows.shadowOf(Looper.getMainLooper()).idle()
            assertEquals(0, revocations.get())

            broker.onAppOpChanged(
                AppOpsManager.OPSTR_RECORD_AUDIO,
                activity.get().packageName,
            )
            Shadows.shadowOf(Looper.getMainLooper()).idle()
            assertEquals(1, revocations.get())

            broker.dispose()
            broker.onAppOpChanged(
                AppOpsManager.OPSTR_RECORD_AUDIO,
                activity.get().packageName,
            )
            Shadows.shadowOf(Looper.getMainLooper()).idle()
            assertEquals(1, revocations.get())
        } finally {
            broker.dispose()
            activity.pause().stop().destroy()
        }
    }

    @Test
    fun microphoneObservationNeedsPermissionExactOwnerAndActualSubmission() {
        openClipboardBridge(
            RdpClipboardMode.DISABLED,
            microphone = true,
        ).use { fixture ->
            fixture.runtime.microphone(RdpMicrophoneCaptureObservation(
                RdpMicrophoneCaptureState.OPENED, true, 0, 0,
            ))
            fixture.runtime.microphone(RdpMicrophoneCaptureObservation(
                RdpMicrophoneCaptureState.CAPTURED, true, 1, 0,
            ))
            val captured = Result()
            fixture.bridge.onMethodCall(MethodCall("microphoneObservation", mapOf(
                "schemaVersion" to 4,
                "requestId" to REQUEST_ID,
            )), captured)
            assertEquals(mapOf(
                "schemaVersion" to 4,
                "requestId" to REQUEST_ID,
                "state" to "captured",
                "deviceOpen" to true,
                "capturedCount" to 1L,
                "acceptedCount" to 0L,
            ), captured.value)

            fixture.runtime.microphone(RdpMicrophoneCaptureObservation(
                RdpMicrophoneCaptureState.SENT, true, 1, 1,
            ))
            val sent = Result()
            fixture.bridge.onMethodCall(MethodCall("microphoneObservation", mapOf(
                "schemaVersion" to 4,
                "requestId" to REQUEST_ID,
            )), sent)
            @Suppress("UNCHECKED_CAST")
            assertEquals(1L, (sent.value as Map<String, Any>)["acceptedCount"])

            val foreign = Result()
            fixture.bridge.onMethodCall(MethodCall("microphoneObservation", mapOf(
                "schemaVersion" to 4,
                "requestId" to FOREIGN_REQUEST_ID,
            )), foreign)
            assertEquals("staleSession", foreign.error)

            Shadows.shadowOf(fixture.activity.get().application).denyPermissions(
                android.Manifest.permission.RECORD_AUDIO,
            )
            val revoked = Result()
            fixture.bridge.onMethodCall(MethodCall("microphoneObservation", mapOf(
                "schemaVersion" to 4,
                "requestId" to REQUEST_ID,
            )), revoked)
            assertEquals("staleSession", revoked.error)
        }
    }

    @Test
    fun clipboardChannelRejectsDisabledMalformedOversizeUnknownStaleAndBackgroundWithoutDispatch() {
        fun rejected(
            mode: RdpClipboardMode = RdpClipboardMode.CLIENT_TO_REMOTE,
            payload: ByteArray = "private".encodeToByteArray(),
            sequence: Long = 1,
            channel: String = "clipboard",
            requestId: String = REQUEST_ID,
            background: Boolean = false,
            expectedCode: String,
        ) {
            openClipboardBridge(mode).use { fixture ->
                if (background) fixture.bridge.setWindowFocused(false)
                val result = Result()
                fixture.bridge.onMethodCall(
                    MethodCall("input", clipboardInput(payload, sequence, channel, requestId)),
                    result,
                )
                assertEquals(expectedCode, result.error)
                assertTrue(payload.all { it == 0.toByte() })
                assertTrue(fixture.runtime.inputs.isEmpty())
            }
        }

        rejected(mode = RdpClipboardMode.DISABLED, expectedCode = "channelUnavailable")
        rejected(payload = byteArrayOf(0xc3.toByte(), 0x28), expectedCode = "invalidRequest")
        rejected(payload = byteArrayOf('a'.code.toByte(), 0, 'b'.code.toByte()), expectedCode = "invalidRequest")
        rejected(payload = ByteArray(RdpFreeRdpSession.MAX_CHANNEL_BYTES + 1) { 1 }, expectedCode = "invalidRequest")
        rejected(channel = "audio", expectedCode = "invalidRequest")
        rejected(requestId = FOREIGN_REQUEST_ID, expectedCode = "staleSession")
        rejected(sequence = 2, expectedCode = "staleSession")
        rejected(background = true, expectedCode = "foregroundRequired")
    }

    private fun openClipboardBridge(
        mode: RdpClipboardMode,
        audio: Boolean = false,
        microphone: Boolean = false,
    ): OpenClipboardBridge {
        val runtime = ClipboardRuntime(availableCapabilities(audio, microphone))
        val activity = Robolectric.buildActivity(android.app.Activity::class.java).setup().visible()
            .windowFocusChanged(true)
        if (microphone) Shadows.shadowOf(activity.get().application).grantPermissions(
            android.Manifest.permission.RECORD_AUDIO,
        )
        val bridge = RdpNativeBridge(activity.get(), Messenger(), runtime)
        bridge.setResumed(true)
        bridge.onListen(REQUEST_ID, Sink())
        val activated = Result()
        bridge.onMethodCall(MethodCall("activate", mapOf("requestId" to REQUEST_ID)), activated)
        assertNull(activated.error)
        val opened = Result()
        bridge.onMethodCall(MethodCall("open", mapOf(
            "schemaVersion" to 4,
            "request" to request(mode, audio, microphone), "requestId" to REQUEST_ID,
            "password" to "secret".encodeToByteArray(), "gatewayPassword" to ByteArray(0),
        )), opened)
        await(opened)
        assertNull(opened.error)
        assertEquals(
            mapOf(
                "schemaVersion" to 4,
                "unicodeTextInput" to true,
                "relativePointer" to true,
            ),
            opened.value,
        )
        return OpenClipboardBridge(bridge, runtime, activity)
    }

    private fun clipboardInput(
        payload: ByteArray,
        sequence: Long = 1,
        channel: String = "clipboard",
        requestId: String = REQUEST_ID,
    ) = mapOf<String, Any?>(
        "schemaVersion" to 4,
        "requestId" to requestId,
        "sequence" to sequence,
        "kind" to "channel",
        "channel" to channel,
        "payload" to payload,
    )

    private fun await(result: Result) {
        repeat(400) {
            Shadows.shadowOf(Looper.getMainLooper()).idle()
            if (result.done) return
            Thread.sleep(5)
        }
        throw AssertionError("Timed out waiting for RDP bridge result")
    }

    private fun availableCapabilities(
        audio: Boolean = false,
        microphone: Boolean = false,
    ) = mapOf<String, Any?>(
        "schemaVersion" to 4,
        "availability" to "available",
        "engineRevision" to RdpFreeRdpPackage.ENGINE_REVISION,
        "security" to mapOf(
            "tls" to true, "certificatePinning" to true, "nla" to true, "rdGateway" to false,
        ),
        "display" to mapOf(
            "dynamicResolution" to true, "externalDisplay" to true,
            "maxWidth" to 4096, "maxHeight" to 2160, "desktopScaleFactorMin" to 100, "desktopScaleFactorMax" to 500, "deviceScaleFactors" to listOf(100, 140, 180),
        ),
        "input" to mapOf("absolutePointer" to true, "relativePointerNegotiation" to true, "verticalWheel" to true, "keyboard" to true, "ime" to true),
        "channels" to mapOf(
            "clipboardModes" to listOf("disabled", "clientToRemote"),
            "audio" to audio,
            "microphone" to microphone,
            "files" to false,
        ),
    )

    private fun request(
        mode: RdpClipboardMode = RdpClipboardMode.DISABLED,
        audio: Boolean = false,
        microphone: Boolean = false,
    ) = mapOf<String, Any?>(
        "schemaVersion" to 4,
        "requestId" to REQUEST_ID,
        "targetHost" to "fixture.invalid",
        "targetPort" to 3389,
        "username" to "fixture",
        "domain" to "TEST",
        "gateway" to null,
        "certificateFingerprint" to PIN,
        "requiresNla" to true,
        "display" to mapOf(
            "width" to 1280, "height" to 800, "desktopScaleFactor" to 180, "deviceScaleFactor" to 180,
            "externalDisplay" to false, "dynamicResize" to true,
        ),
        "keyboardLayout" to "turkishQ",
        "clipboardMode" to when (mode) {
            RdpClipboardMode.DISABLED -> "disabled"
            RdpClipboardMode.CLIENT_TO_REMOTE -> "clientToRemote"
            RdpClipboardMode.BIDIRECTIONAL -> "bidirectional"
        },
        "audio" to audio,
        "microphone" to microphone,
        "files" to false,
    )

    companion object {
        private const val REQUEST_ID = "11111111-1111-4111-8111-111111111111"
        private const val FOREIGN_REQUEST_ID = "22222222-2222-4222-8222-222222222222"
        private const val PIN = "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    }
}
