package com.ersingundem.larenor.rdp

import java.nio.ByteBuffer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class RdpFreeRdpEngineTest {
    @Test
    fun matchingCertificateAloneCannotPublishAnAuthenticatedSessionOrFrame() {
        val gate = RdpAuthenticatedOutputGate(PIN)
        assertTrue(gate.certificate(PIN))
        assertFalse(gate.canDeliverFrames())
        assertFalse(gate.securityDelivered())
        // Wrong credentials fail after certificate verification; no success
        // callback means the engine never sees security or a framebuffer.
        gate.close()
        assertNull(gate.connectionSucceeded())
        assertFalse(gate.canDeliverFrames())
    }

    @Test
    fun exactNativeSuccessPublishesSecurityOnceBeforeFramesAndRetirementIsFinal() {
        val rejected = RdpAuthenticatedOutputGate(PIN)
        assertFalse(rejected.certificate(OTHER_PIN))
        assertNull(rejected.connectionSucceeded())
        assertFalse(rejected.certificate(PIN))
        val gate = RdpAuthenticatedOutputGate(PIN)
        assertNull(gate.connectionSucceeded())
        assertTrue(gate.certificate(PIN))
        val evidence = requireNotNull(gate.connectionSucceeded())
        assertEquals(RdpJniSecurity("TLSv1.2", true, PIN), evidence)
        assertFalse(gate.canDeliverFrames())
        assertTrue(gate.securityDelivered())
        assertTrue(gate.canDeliverFrames())
        assertNull(gate.connectionSucceeded())
        assertFalse(gate.securityDelivered())
        gate.close()
        assertFalse(gate.canDeliverFrames())
        assertFalse(gate.certificate(PIN))
        assertNull(gate.connectionSucceeded())
    }

    @Test
    fun retirementDuringSecurityDeliveryNeverReleasesAnEarlyFrame() {
        val gate = RdpAuthenticatedOutputGate(PIN)
        assertTrue(gate.certificate(PIN))
        assertTrue(gate.connectionSucceeded() != null)
        gate.close()
        assertFalse(gate.securityDelivered())
        assertFalse(gate.canDeliverFrames())
    }

    @Test
    fun tlsNlaAndExactCertificateGateTheActiveSession() {
        for ((evidence, expected) in listOf(
            RdpJniSecurity("TLSv1.1", true, PIN) to "tlsRequired",
            RdpJniSecurity("TLSv1.3", false, PIN) to "nlaUnavailable",
            RdpJniSecurity("TLSv1.3", true, OTHER_PIN) to "certificatePinningRequired",
        )) {
            val fixture = Fixture()
            val session = fixture.open()
            fixture.operation.secure(evidence)
            assertEquals(RdpJniPhase.FAILED, session.phase)
            assertEquals(expected, session.failureCode)
            assertEquals(1, fixture.operation.closes)
            assertFalse(session.absolutePointer(1, geometry(1), .5, .5, 0))
            fixture.operation.secure(RdpJniSecurity("TLSv1.3", true, PIN))
            assertEquals(RdpJniPhase.FAILED, session.phase)
        }

        val fixture = Fixture()
        val session = fixture.open()
        fixture.operation.secure(RdpJniSecurity("TLSv1.3", true, PIN))
        assertEquals(RdpJniPhase.ACTIVE, session.phase)
        assertNull(session.failureCode)
    }

    @Test
    fun negotiatedUnicodeInputIsBoundToTheAuthenticatedSession() {
        for (supported in listOf(false, true)) {
            val fixture = Fixture(unicodeInput = supported)
            val session = fixture.active()
            assertEquals(supported, session.unicodeInputSupported)
        }
    }

    @Test
    fun remoteAudioObservationIsStagedBeforeAuthAndRequiresCompletedPlaybackEvidence() {
        val fixture = Fixture(audio = true)
        val session = fixture.open()
        fixture.operation.audio(
            RdpRemoteAudioObservation(RdpRemoteAudioState.DEVICE_OPEN, true, 0, 0),
        )
        reject("staleSession") { session.audioObservation() }

        fixture.operation.secure(RdpJniSecurity("TLSv1.3", true, PIN))
        assertEquals(RdpRemoteAudioState.DEVICE_OPEN, session.audioObservation().state)
        fixture.operation.audio(
            RdpRemoteAudioObservation(RdpRemoteAudioState.PLAYING, true, 1, 0),
        )
        assertEquals(0, session.audioObservation().completedCount)
        fixture.operation.audio(
            RdpRemoteAudioObservation(RdpRemoteAudioState.PLAYING, true, 1, 1),
        )
        assertEquals(
            RdpRemoteAudioObservation(RdpRemoteAudioState.PLAYING, true, 1, 1),
            session.audioObservation(),
        )
    }

    @Test
    fun remoteAudioLifecycleCanCloseAndReopenButRegressionOrFailureRetires() {
        val fixture = Fixture(audio = true)
        val session = fixture.active()
        fixture.operation.audio(
            RdpRemoteAudioObservation(RdpRemoteAudioState.DEVICE_OPEN, true, 0, 0),
        )
        fixture.operation.audio(
            RdpRemoteAudioObservation(RdpRemoteAudioState.PLAYING, true, 2, 1),
        )
        fixture.operation.audio(
            RdpRemoteAudioObservation(RdpRemoteAudioState.CLOSED, false, 2, 1),
        )
        fixture.operation.audio(
            RdpRemoteAudioObservation(RdpRemoteAudioState.DEVICE_OPEN, true, 2, 1),
        )
        assertEquals(RdpRemoteAudioState.DEVICE_OPEN, session.audioObservation().state)

        fixture.operation.audio(
            RdpRemoteAudioObservation(RdpRemoteAudioState.PLAYING, true, 1, 1),
        )
        assertEquals(RdpJniPhase.FAILED, session.phase)
        assertEquals("channelUnavailable", session.failureCode)
        assertEquals(1, fixture.operation.closes)

        val failedFixture = Fixture(audio = true)
        val failed = failedFixture.open()
        failedFixture.operation.audio(
            RdpRemoteAudioObservation(RdpRemoteAudioState.FAILED, false, 0, 0),
        )
        assertEquals(RdpJniPhase.FAILED, failed.phase)
        assertEquals(RdpRemoteAudioState.FAILED, failed.audioObservation().state)
    }

    @Test
    fun disabledAudioHasNoObservationOrGenericPayloadPath() {
        val fixture = Fixture()
        val session = fixture.active()
        fixture.operation.audio(
            RdpRemoteAudioObservation(RdpRemoteAudioState.DEVICE_OPEN, true, 0, 0),
        )
        reject("channelUnavailable") { session.audioObservation() }
        assertFalse(session.channel(1, RdpJniChannel.AUDIO, byteArrayOf(1)))
        assertEquals(0, fixture.operation.inputs)
    }

    @Test
    fun unsupportedUsbKeyboardUsageIsNonFatalAndDoesNotConsumeSequence() {
        val fixture = Fixture()
        val session = fixture.active()
        assertFalse(session.key(1, 0x000c00e9, true))
        assertEquals(RdpJniPhase.ACTIVE, session.phase)
        assertNull(session.failureCode)
        assertEquals(0, fixture.operation.inputs)
        assertTrue(session.key(1, 0x000700e0, true))
        assertEquals(1, fixture.operation.inputs)
        assertEquals(RdpJniPhase.ACTIVE, session.phase)
    }

    @Test
    fun framebufferAndDexResizeAreBoundedAndRequireOneFrameAck() {
        val acknowledgedFixture = Fixture()
        val acknowledged = acknowledgedFixture.active()
        acknowledgedFixture.operation.frame(frame(1, 1280, 800))
        assertTrue(acknowledged.acknowledgeFrame(1))
        assertEquals(RdpJniPhase.ACTIVE, acknowledged.phase)
        assertEquals(1, acknowledgedFixture.operation.resumes)

        val fixture = Fixture()
        val session = fixture.active()
        val first = frame(1, 1280, 800)
        fixture.operation.frame(first)
        assertEquals(RdpJniPhase.AWAITING_FRAME_ACK, session.phase)
        assertEquals(1L, session.pendingFrame?.sequence)

        val rejected = frame(2, 1280, 800)
        fixture.operation.frame(rejected)
        assertEquals("frameBackpressure", session.failureCode)
        assertTrue(rejected.closed)
        assertEquals(1, fixture.operation.closes)

        val resizeFixture = Fixture(externalDisplay = true)
        val resized = resizeFixture.active()
        assertTrue(resized.resize(1, RdpNativeDisplay(2560, 1440, 180, 180, true, true)))
        assertEquals(1, resizeFixture.operation.resizes)
        assertFalse(resized.resize(2, RdpNativeDisplay(8192, 2049, 180, 180, true, true)))
        assertEquals("displayUnavailable", resized.failureCode)
        assertEquals(1, resizeFixture.operation.resizes)
    }

    @Test
    fun pointerKeyboardImeAndChannelsRequireSequencePermissionAndLiveOwnership() {
        val fixture = Fixture(clipboard = RdpClipboardMode.CLIENT_TO_REMOTE)
        val session = fixture.active()
        fixture.operation.frame(frame(1, 1280, 800))
        assertTrue(session.acknowledgeFrame(1))
        assertTrue(session.absolutePointer(1, geometry(1), .25, .75, 1))
        assertTrue(session.key(2, 0x70004, true))
        assertTrue(session.ime(3, "İstanbul"))
        assertTrue(session.channel(4, RdpJniChannel.CLIPBOARD, "metin".encodeToByteArray()))
        assertFalse(session.channel(5, RdpJniChannel.AUDIO, byteArrayOf(1)))
        assertEquals("channelUnavailable", session.failureCode)
        assertEquals(4, fixture.operation.inputs)

        val sequenceFixture = Fixture()
        val sequenced = sequenceFixture.active()
        sequenceFixture.operation.frame(frame(1, 1280, 800))
        assertTrue(sequenced.acknowledgeFrame(1))
        assertFalse(sequenced.absolutePointer(2, geometry(1), .5, .5, 0))
        assertEquals("staleSession", sequenced.failureCode)
        assertEquals(0, sequenceFixture.operation.inputs)
    }

    @Test
    fun pointerUsesTheLastAckedCurrentGeometryAndResizeRetiresIt() {
        val pendingFixture = Fixture()
        val pending = pendingFixture.active()
        assertFalse(pending.absolutePointer(1, geometry(1), .5, .5, 0))
        assertEquals("staleSession", pending.failureCode)
        assertEquals(0, pendingFixture.operation.inputs)

        val fixture = Fixture()
        val session = fixture.active()
        fixture.operation.frame(frame(1, 1280, 800))
        assertTrue(session.acknowledgeFrame(1))
        fixture.operation.frame(frame(2, 1280, 800))
        assertTrue(session.absolutePointer(1, geometry(1), .25, .75, 0))
        assertEquals(1, fixture.operation.inputs)
        assertTrue(session.acknowledgeFrame(2))
        assertFalse(session.absolutePointer(2, geometry(1), .25, .75, 0))
        assertEquals("staleSession", session.failureCode)
        assertEquals(1, fixture.operation.inputs)

        val resizedFixture = Fixture()
        val resized = resizedFixture.active()
        resizedFixture.operation.frame(frame(1, 1280, 800))
        assertTrue(resized.acknowledgeFrame(1))
        assertTrue(resized.resize(1, RdpNativeDisplay(1024, 768, 140, 140, false, true)))
        assertFalse(resized.absolutePointer(2, geometry(1), .5, .5, 0))
        assertEquals("staleSession", resized.failureCode)
        assertEquals(0, resizedFixture.operation.inputs)
    }

    @Test
    fun transitionalFrameCannotAuthorizeWrongResizeGeometry() {
        val fixture = Fixture()
        val session = fixture.active()
        fixture.operation.frame(frame(1, 1280, 800))
        assertTrue(session.acknowledgeFrame(1))
        assertTrue(session.resize(1, RdpNativeDisplay(1024, 768, 140, 140, false, true)))
        fixture.operation.frame(frame(2, 1280, 800))
        assertTrue(session.acknowledgeFrame(2))
        assertFalse(session.absolutePointer(2, geometry(2, 1280, 800, 2), .5, .5, 0))
        assertEquals("staleSession", session.failureCode)
        assertEquals(0, fixture.operation.inputs)
    }

    @Test
    fun sameSizeScaleChangeAdvancesLayoutAndRequiresANewAck() {
        val fixture = Fixture()
        val session = fixture.active()
        fixture.operation.frame(frame(1, 1280, 800))
        assertTrue(session.acknowledgeFrame(1))
        assertTrue(session.resize(1, RdpNativeDisplay(1280, 800, 140, 140, false, true)))
        fixture.operation.frame(frame(2, 1280, 800))
        assertTrue(session.acknowledgeFrame(2))
        assertFalse(session.absolutePointer(2, geometry(2), .5, .5, 0))
        assertEquals("staleSession", session.failureCode)
        assertEquals(0, fixture.operation.inputs)

        val currentFixture = Fixture()
        val current = currentFixture.active()
        currentFixture.operation.frame(frame(1, 1280, 800))
        assertTrue(current.acknowledgeFrame(1))
        assertTrue(current.resize(1, RdpNativeDisplay(1280, 800, 140, 140, false, true)))
        currentFixture.operation.frame(frame(2, 1280, 800))
        assertTrue(current.acknowledgeFrame(2))
        assertTrue(current.absolutePointer(2, geometry(2, displayLayoutRevision = 2), .5, .5, 0))
    }

    @Test
    fun nativePointerOrResizeRejectionRetiresWithoutSequenceReplay() {
        val inputFixture = Fixture(inputAccepted = false)
        val inputSession = inputFixture.active()
        inputFixture.operation.frame(frame(1, 1280, 800))
        assertTrue(inputSession.acknowledgeFrame(1))
        assertFalse(inputSession.absolutePointer(1, geometry(1), .5, .5, 0))
        assertEquals("inputUnavailable", inputSession.failureCode)
        assertFalse(inputSession.absolutePointer(1, geometry(1), .5, .5, 0))
        assertEquals(1, inputFixture.operation.inputs)

        val resizeFixture = Fixture(resizeAccepted = false)
        val resizeSession = resizeFixture.active()
        assertFalse(resizeSession.resize(1, RdpNativeDisplay(1024, 768, 140, 140, false, true)))
        assertEquals("displayUnavailable", resizeSession.failureCode)
        assertFalse(resizeSession.resize(1, RdpNativeDisplay(1024, 768, 140, 140, false, true)))
        assertEquals(1, resizeFixture.operation.resizes)

        val oddFixture = Fixture()
        val odd = oddFixture.active()
        assertFalse(odd.resize(1, RdpNativeDisplay(1025, 768, 140, 140, false, true)))
        assertEquals("displayUnavailable", odd.failureCode)
        assertEquals(0, oddFixture.operation.resizes)

        val fixedFixture = Fixture(dynamicResize = false)
        val fixed = fixedFixture.active()
        assertFalse(fixed.resize(1, RdpNativeDisplay(1024, 768, 140, 140, false, false)))
        assertEquals("displayUnavailable", fixed.failureCode)
        assertEquals(0, fixedFixture.operation.resizes)
    }

    @Test
    fun resizeClearsGeometryBeforeNativeIoAndConcurrentInputCannotDispatch() {
        val fixture = Fixture()
        val session = fixture.active()
        fixture.operation.frame(frame(1, 1280, 800))
        assertTrue(session.acknowledgeFrame(1))
        fixture.operation.onResize = {
            assertFalse(session.absolutePointer(2, geometry(1), .5, .5, 0))
            assertEquals(0, fixture.operation.inputs)
            true
        }

        assertFalse(session.resize(1, RdpNativeDisplay(1024, 768, 140, 140, false, true)))
        assertEquals("staleSession", session.failureCode)
        assertEquals(1, fixture.operation.resizes)
        assertEquals(0, fixture.operation.inputs)
        assertFalse(session.resize(1, RdpNativeDisplay(1024, 768, 140, 140, false, true)))
        assertEquals(1, fixture.operation.resizes)
    }

    @Test
    fun ackCompletingInsideResizeCannotReinstallPriorLayoutPointerAuthority() {
        val fixture = Fixture()
        val session = fixture.active()
        fixture.operation.frame(frame(1, 1280, 800))
        assertTrue(session.acknowledgeFrame(1))
        fixture.operation.frame(frame(2, 1280, 800))
        fixture.operation.onResize = {
            assertTrue(session.acknowledgeFrame(2))
            true
        }

        assertTrue(session.resize(1, RdpNativeDisplay(1024, 768, 140, 140, false, true)))
        assertFalse(session.absolutePointer(2, geometry(2), .5, .5, 0))
        assertEquals("staleSession", session.failureCode)
        assertEquals(0, fixture.operation.inputs)
        assertEquals(1, fixture.operation.resizes)
    }

    @Test
    fun concurrentInputCannotReuseTheReservedSequence() {
        val fixture = Fixture()
        val session = fixture.active()
        fixture.operation.onInput = {
            assertFalse(session.key(1, 0x70005, true))
            true
        }

        assertFalse(session.key(1, 0x70004, true))
        assertEquals("staleSession", session.failureCode)
        assertEquals(1, fixture.operation.inputs)
        assertFalse(session.key(1, 0x70004, true))
        assertEquals(1, fixture.operation.inputs)
    }

    @Test
    fun relativePointerAndWheelRequireNegotiationAndExactAckedGeometry() {
        val unsupportedFixture = Fixture(relativePointer = false)
        val unsupported = unsupportedFixture.active()
        unsupportedFixture.operation.frame(frame(1, 1280, 800))
        assertTrue(unsupported.acknowledgeFrame(1))
        assertFalse(unsupported.relativePointer(1, geometry(1), 4, -3, 0))
        assertEquals("inputUnavailable", unsupported.failureCode)
        assertEquals(0, unsupportedFixture.operation.inputs)

        val fixture = Fixture(relativePointer = true)
        val session = fixture.active()
        fixture.operation.frame(frame(1, 1280, 800))
        assertTrue(session.acknowledgeFrame(1))
        assertTrue(session.relativePointer(1, geometry(1), Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt(), 1))
        assertTrue(session.verticalWheel(2, geometry(1), -120))
        assertEquals(
            listOf(RdpJniInput.RelativePointer::class, RdpJniInput.VerticalWheel::class),
            fixture.operation.events.map { it::class },
        )
    }

    @Test
    fun disconnectClearsFrameAndNeverReplaysInputOrReconnects() {
        val fixture = Fixture()
        val session = fixture.active()
        fixture.operation.frame(frame(1, 1280, 800))
        fixture.operation.disconnected()
        assertEquals(RdpJniPhase.FAILED, session.phase)
        assertEquals("connectionFailed", session.failureCode)
        assertNull(session.pendingFrame)
        assertEquals(1, fixture.operation.starts)
        assertEquals(1, fixture.operation.closes)
        assertFalse(session.key(1, 42, true))
        fixture.operation.secure(RdpJniSecurity("TLSv1.3", true, PIN))
        assertEquals(1, fixture.operation.starts)
    }

    @Test
    fun graphicsDuringFrameAcknowledgementWaitForConsumerResume() {
        val fixture = Fixture()
        val session = fixture.active()
        val gate = RdpFrameDeliveryGate()
        val first = frame(requireNotNull(gate.offer()), 1280, 800)
        fixture.operation.frame(first)
        fixture.operation.onAck = { sequence ->
            val accepted = gate.acknowledge(sequence)
            // A native update races the consumer's ACK while its old buffer
            // is still pending. It must remain coalesced until explicit resume.
            val premature = gate.offer()
            if (premature != null) fixture.operation.frame(frame(premature, 1280, 800))
            accepted
        }
        fixture.operation.onResume = {
            when (gate.resume()) {
                RdpFrameDeliveryGate.Resume.REJECTED -> false
                RdpFrameDeliveryGate.Resume.IDLE -> true
                RdpFrameDeliveryGate.Resume.FRAME_REQUIRED -> {
                    assertTrue(first.closed)
                    assertEquals(RdpJniPhase.ACTIVE, session.phase)
                    fixture.operation.frame(frame(requireNotNull(gate.offer()), 1280, 800))
                    true
                }
            }
        }

        assertTrue(session.acknowledgeFrame(1))
        assertEquals(0, fixture.operation.closes)
        assertNull(session.failureCode)
        assertEquals(RdpJniPhase.AWAITING_FRAME_ACK, session.phase)
        assertEquals(2L, session.pendingFrame?.sequence)
        session.close()
        gate.close()
        assertNull(gate.offer())
        assertFalse(gate.acknowledge(2))
        assertEquals(RdpFrameDeliveryGate.Resume.REJECTED, gate.resume())
    }

    @Test
    fun incorrectOrRepeatedAcknowledgementDoesNotReleaseNativeFrames() {
        val gate = RdpFrameDeliveryGate()
        assertEquals(1L, gate.offer())
        assertFalse(gate.acknowledge(2))
        assertEquals(RdpFrameDeliveryGate.Resume.REJECTED, gate.resume())
        assertNull(gate.offer())
        assertTrue(gate.acknowledge(1))
        assertFalse(gate.acknowledge(1))
        assertNull(gate.offer())
        assertEquals(RdpFrameDeliveryGate.Resume.FRAME_REQUIRED, gate.resume())
        assertEquals(2L, gate.offer())
        assertTrue(gate.acknowledge(2))
        assertEquals(RdpFrameDeliveryGate.Resume.IDLE, gate.resume())
    }

    @Test
    fun disconnectDuringAcknowledgementCannotResurrectOrResumeSession() {
        val fixture = Fixture()
        val session = fixture.active()
        val first = frame(1, 1280, 800)
        fixture.operation.frame(first)
        fixture.operation.onAck = {
            fixture.operation.disconnected()
            true
        }

        assertFalse(session.acknowledgeFrame(1))
        assertEquals(RdpJniPhase.FAILED, session.phase)
        assertEquals("connectionFailed", session.failureCode)
        assertNull(session.pendingFrame)
        assertTrue(first.closed)
        assertEquals(0, fixture.operation.resumes)
        assertEquals(1, fixture.operation.closes)
        assertFalse(session.absolutePointer(1, geometry(1), .5, .5, 0))
        assertEquals(0, fixture.operation.inputs)
    }

    @Test
    fun reviewedPackageRejectsUnprovedPeerUnicodeBeforeNativeInput() {
        val fixture = Fixture(
            capabilityMap = RdpFreeRdpPackage.capabilities(),
            unicodeInput = false,
        )
        val session = fixture.active()
        assertTrue(session.key(1, 0x70004, true))
        assertFalse(session.ime(2, "İstanbul"))
        assertEquals("inputUnavailable", session.failureCode)
        assertEquals(1, fixture.operation.inputs)
        assertEquals(1, fixture.operation.closes)
    }

    @Test
    fun reviewedPackagePreservesExactClipboardModesAcrossChannelAndNegotiation() {
        val capabilities = RdpNativeCapabilities.parse(RdpFreeRdpPackage.capabilities())
        val channels = capabilities.toChannel()["channels"] as Map<*, *>
        val security = capabilities.toChannel()["security"] as Map<*, *>
        assertEquals(listOf("disabled", "clientToRemote"), channels["clipboardModes"])
        assertEquals(true, channels["clipboard"])
        assertEquals(false, security["rdGateway"])
        assertTrue(capabilities.ime)
        try {
            Fixture(
                clipboard = RdpClipboardMode.BIDIRECTIONAL,
                capabilityMap = RdpFreeRdpPackage.capabilities(),
            ).open()
            fail("Unimplemented remote clipboard must not open a native session")
        } catch (failure: RdpNativeFailure) {
            assertEquals("clipboardUnavailable", failure.code)
        }
        val unavailable = UnavailableRdpNativeBackend().capabilities().toChannel()["channels"] as Map<*, *>
        assertEquals(emptyList<String>(), unavailable["clipboardModes"])
        assertEquals(false, unavailable["clipboard"])
    }

    private class Fixture(
        private val clipboard: RdpClipboardMode = RdpClipboardMode.DISABLED,
        private val capabilityMap: Map<String, Any?> = availableCapabilities(),
        private val unicodeInput: Boolean = true,
        private val relativePointer: Boolean = true,
        private val inputAccepted: Boolean = true,
        private val resizeAccepted: Boolean = true,
        private val externalDisplay: Boolean = false,
        private val dynamicResize: Boolean = true,
        private val audio: Boolean = false,
    ) {
        lateinit var operation: Operation
        private val runtime = object : RdpJniRuntime {
            override fun identity() = RdpFreeRdpIdentity(
                RdpFreeRdpPackage.VERSION,
                RdpFreeRdpPackage.SOURCE_COMMIT,
                RdpFreeRdpPackage.SOURCE_SHA256,
                "x86_64",
                3,
                emptySet(),
            )
            override fun capabilities() = if (!audio) capabilityMap else capabilityMap + (
                "channels" to mapOf(
                    "clipboardModes" to listOf("disabled", "clientToRemote"),
                    "audio" to true,
                    "files" to false,
                )
            )
            override fun create(
                request: RdpNativeRequest,
                plan: RdpNativeNegotiated,
                listener: RdpJniOperation.Listener,
            ) = Operation(
                listener,
                unicodeInput,
                relativePointer,
                inputAccepted,
                resizeAccepted,
            ).also { operation = it }
        }

        fun open(): RdpFreeRdpSession {
            val request = RdpNativeRequest.parse(
                request(clipboard, externalDisplay, dynamicResize, audio),
            )
            return RdpNativeAdapter(RdpFreeRdpBackend(runtime)).open(
                request,
                RdpNativeSecrets.take("secret".toCharArray(), null),
            ) as RdpFreeRdpSession
        }

        fun active(): RdpFreeRdpSession = open().also {
            operation.secure(RdpJniSecurity("TLSv1.3", true, PIN))
        }
    }

    private class Operation(
        private var listener: RdpJniOperation.Listener?,
        override val unicodeInputSupported: Boolean = true,
        override val relativePointerSupported: Boolean = true,
        private val inputAccepted: Boolean = true,
        private val resizeAccepted: Boolean = true,
    ) : RdpJniOperation {
        var starts = 0
        var closes = 0
        var inputs = 0
        val events = mutableListOf<RdpJniInput>()
        var resizes = 0
        var resumes = 0
        var onAck: ((Long) -> Boolean)? = null
        var onResume: (() -> Boolean)? = null
        var onInput: (() -> Boolean)? = null
        var onResize: (() -> Boolean)? = null
        override fun start(password: CharArray, gatewayPassword: CharArray?): Boolean {
            starts++
            return true
        }
        override fun input(sequence: Long, event: RdpJniInput): Boolean {
            inputs++
            events.add(event)
            return onInput?.invoke() ?: inputAccepted
        }
        override fun resize(sequence: Long, display: RdpNativeDisplay): Boolean {
            resizes++
            return onResize?.invoke() ?: resizeAccepted
        }
        override fun acknowledgeFrame(sequence: Long): Boolean = onAck?.invoke(sequence) ?: true
        override fun resumeFrames(): Boolean { resumes++; return onResume?.invoke() ?: true }
        override fun close() { closes++ }
        override fun detach() { listener = null }
        fun secure(value: RdpJniSecurity) { listener?.onSecurity(value) }
        fun audio(value: RdpRemoteAudioObservation) { listener?.onRemoteAudio(value) }
        fun frame(value: RdpNativeFrame) { listener?.onFrame(value) ?: value.close() }
        fun disconnected() { listener?.onDisconnected() }
    }

    companion object {
        private const val PIN = "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        private const val OTHER_PIN = "SHA256:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"

        fun availableCapabilities() = mapOf<String, Any?>(
            "schemaVersion" to 3,
            "availability" to "available",
            "engineRevision" to RdpFreeRdpPackage.ENGINE_REVISION,
            "security" to mapOf("tls" to true, "certificatePinning" to true, "nla" to true, "rdGateway" to false),
            "display" to mapOf("dynamicResolution" to true, "externalDisplay" to true, "maxWidth" to 4096, "maxHeight" to 2160, "desktopScaleFactorMin" to 100, "desktopScaleFactorMax" to 500, "deviceScaleFactors" to listOf(100, 140, 180)),
            "input" to mapOf("absolutePointer" to true, "relativePointerNegotiation" to true, "verticalWheel" to true, "keyboard" to true, "ime" to true),
            "channels" to mapOf("clipboardModes" to listOf("disabled", "clientToRemote"), "audio" to false, "files" to false),
        )

        fun request(
            clipboard: RdpClipboardMode = RdpClipboardMode.DISABLED,
            externalDisplay: Boolean = false,
            dynamicResize: Boolean = true,
            audio: Boolean = false,
        ) = mapOf<String, Any?>(
            "schemaVersion" to 3,
            "requestId" to "11111111-1111-4111-8111-111111111111",
            "targetHost" to "fixture.invalid",
            "targetPort" to 3389,
            "username" to "fixture",
            "domain" to "TEST",
            "gateway" to null,
            "certificateFingerprint" to PIN,
            "requiresNla" to true,
            "display" to mapOf("width" to 1280, "height" to 800, "desktopScaleFactor" to 180, "deviceScaleFactor" to 180, "externalDisplay" to externalDisplay, "dynamicResize" to dynamicResize),
            "keyboardLayout" to "turkishQ",
            "clipboardMode" to when (clipboard) {
                RdpClipboardMode.DISABLED -> "disabled"
                RdpClipboardMode.CLIENT_TO_REMOTE -> "clientToRemote"
                RdpClipboardMode.BIDIRECTIONAL -> "bidirectional"
            },
            "audio" to audio,
            "files" to false,
        )

        fun frame(sequence: Long, width: Int, height: Int): RdpNativeFrame {
            val bytes = ByteBuffer.allocateDirect(width * height * 4)
            return RdpNativeFrame.take(sequence, width, height, width * 4, bytes)
        }

        fun geometry(
            frameSequence: Long,
            width: Int = 1280,
            height: Int = 800,
            displayLayoutRevision: Long = 1,
        ) = RdpFreeRdpSession.DisplayedGeometry(
            frameSequence, width, height, displayLayoutRevision,
        )

        fun reject(code: String, action: () -> Unit) {
            try {
                action()
                fail("Expected $code")
            } catch (failure: RdpNativeFailure) {
                assertEquals(code, failure.code)
            }
        }
    }
}
