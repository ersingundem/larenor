package com.ersingundem.larenor.rdp

import android.app.Activity
import android.app.Instrumentation
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.system.Os
import android.system.OsConstants
import android.util.AtomicFile
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.ersingundem.larenor.MainActivity
import io.flutter.plugin.common.FlutterException
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.StandardMethodCodec
import java.io.File
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Normal public MethodChannel acceptance for the already proven native Gateway + SAF effects.
 *
 * This test deliberately uses [RdpNativeBridge] and its product admission wrapper. It cannot run
 * to an effect while rdGateway/files remain masked and contains no capability override.
 */
@RunWith(AndroidJUnit4::class)
class RdpPackagedGatewaySafPublicBridgeAcceptanceTest {
    @Test
    fun gatewaySafPublicMethodChannelPathProvesTwoPinsNlaRdpdrDrainAndSafReadback() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val appContext = instrumentation.targetContext
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            val activity = AtomicReference<MainActivity>()
            scenario.onActivity(activity::set)
            val ownedActivity = requireNotNull(activity.get())
            awaitWindowFocus(ownedActivity)
            val client = OwnedRegisteredChannelClient(ownedActivity)

            val capabilities = client.call("capabilities", null).awaitMap()
            assertEquals(4, capabilities["schemaVersion"])
            assertEquals(RdpFreeRdpPackage.ENGINE_REVISION, capabilities["engineRevision"])
            val security = capabilities.requiredMap("security")
            val channels = capabilities.requiredMap("channels")
            // This is the reviewed production admission gate on MainActivity's registered bridge.
            // The current masked build fails here before the secret descriptor is consumed.
            assertEquals(true, security["rdGateway"])
            assertEquals(true, channels["files"])

            val descriptor = OwnedDescriptor.load(appContext)
            val uploadName = "upload-" + descriptor.nonce.take(16) + ".bin"
            val outboundName = "outbound-" + descriptor.nonce.take(16) + ".bin"
            val upload = ("Larenor-F62-Gateway-upload:" + descriptor.nonce)
                .toByteArray(StandardCharsets.US_ASCII)
            val outbound = ("Larenor-F62-Gateway-outbound:" + descriptor.nonce)
                .toByteArray(StandardCharsets.US_ASCII)
            assertEquals(91, upload.size)
            assertEquals(93, outbound.size)
            assertEquals(descriptor.expectedUploadSha256, upload.sha256())
            assertEquals(descriptor.expectedOutboundSha256, outbound.sha256())
            val tree = RdpOwnedSafDocumentsProvider.reset(
                instrumentation.context,
                uploadName,
                upload,
            )
            upload.fill(0)
            outbound.fill(0)
            try {
                val direct = client.call(
                    "inspect",
                    mapOf(
                        "targetHost" to descriptor.targetHost,
                        "targetPort" to descriptor.targetPort,
                        "username" to descriptor.targetUsername,
                    ),
                )
                assertEquals("connectionFailed", direct.awaitError(20))

                client.listen(SESSION_REQUEST_ID)
                client.call(
                    "activate",
                    mapOf("schemaVersion" to 6, "requestId" to SESSION_REQUEST_ID),
                ).awaitNull()

                val gatewayRequest = gatewayInspection(descriptor)
                val gateway = client.call("inspectGateway", gatewayRequest).awaitMap(20)
                assertEquals("gateway", gateway["kind"])
                assertEquals(descriptor.gatewayPin, gateway["certificateFingerprint"])

                val probePassword = descriptor.gatewayPassword.utf8()
                val target = client.call(
                    "inspectTargetThroughGateway",
                    mapOf(
                        "schemaVersion" to 6,
                        "requestId" to SESSION_REQUEST_ID,
                        "target" to mapOf(
                            "host" to descriptor.targetHost,
                            "port" to descriptor.targetPort,
                            "username" to descriptor.targetUsername,
                            "domain" to descriptor.targetDomain,
                        ),
                        "gateway" to mapOf(
                            "host" to descriptor.gatewayHost,
                            "port" to descriptor.gatewayPort,
                            "username" to descriptor.gatewayUsername,
                            "domain" to descriptor.gatewayDomain,
                            "certificateFingerprint" to descriptor.gatewayPin,
                        ),
                        "gatewayPassword" to probePassword,
                    ),
                ).awaitMap(20)
                assertTrue(probePassword.all { it == 0.toByte() })
                assertEquals("target", target["kind"])
                assertEquals(descriptor.targetPin, target["certificateFingerprint"])

                val authority = authority(descriptor.nonce)
                instrumentation.context.grantUriPermission(
                    ownedActivity.packageName,
                    tree,
                    REQUIRED_PICKER_FLAGS,
                )
                val picker = Instrumentation.ActivityMonitor(
                    IntentFilter(Intent.ACTION_OPEN_DOCUMENT_TREE),
                    Instrumentation.ActivityResult(
                        Activity.RESULT_OK,
                        Intent().setData(tree).addFlags(REQUIRED_PICKER_FLAGS),
                    ),
                    true,
                )
                instrumentation.addMonitor(picker)
                val selected = try {
                    client.call(
                        "selectFileTransferTree",
                        mapOf(
                            "schemaVersion" to 5,
                            "requestId" to SELECT_REQUEST_ID,
                            "authority" to authority,
                        ),
                    ).awaitMap(10)
                } finally {
                    instrumentation.removeMonitor(picker)
                }
                assertEquals(1, picker.hits)
                assertState(selected, "prepared")
                assertPersistedReadWriteGrant(ownedActivity, tree)
                val grantId = selected.requiredString("grantId")
                val grantRevision = selected.requiredLong("grantRevision")

                assertState(
                    client.call(
                        "activateFileTransferGrant",
                        grantRequest(ACTIVATE_REQUEST_ID, authority, grantId, grantRevision),
                    ).awaitMap(),
                    "active",
                )
                val prepared = client.call(
                    "prepareFileTransfer",
                    transferPrepare(authority, grantId, grantRevision),
                ).awaitMap(40)
                assertState(prepared, "prepared")
                val transferId = prepared.requiredString("transferId")

                val targetPassword = descriptor.targetPassword.utf8()
                val gatewayPassword = descriptor.gatewayPassword.utf8()
                val opened = client.call(
                    "open",
                    mapOf(
                        "schemaVersion" to 6,
                        "requestId" to SESSION_REQUEST_ID,
                        "password" to targetPassword,
                        "gatewayPassword" to gatewayPassword,
                        "request" to sessionRequest(descriptor, transferId),
                    ),
                ).awaitMap(40)
                assertTrue(targetPassword.all { it == 0.toByte() })
                assertTrue(gatewayPassword.all { it == 0.toByte() })
                assertEquals(6, opened["schemaVersion"])

                val frameSequence = client.awaitPendingFrameSequence(30)
                client.call(
                    "ackFrame",
                    mapOf(
                        "schemaVersion" to 6,
                        "requestId" to SESSION_REQUEST_ID,
                        "frameSequence" to frameSequence,
                    ),
                ).awaitNull()

                // Test-only mirror observation is a causal phase barrier, never the accepted file
                // effect. Acceptance still requires host witness + sealed/save/provider readback.
                assertHostSideMirrorOutbound(
                    File(
                        ownedActivity.noBackupFilesDir,
                        "rdp-saf-mirrors-v1/$transferId/root/FromRemote/$outboundName",
                    ),
                    descriptor.expectedOutboundSha256,
                )

                val drained = client.call(
                    "drainFileTransfer",
                    transferLifecycle(
                        DRAIN_REQUEST_ID, authority, grantId, grantRevision, transferId,
                    ),
                ).awaitMap(40)
                assertState(drained, "sealed")
                val saved = client.call(
                    "saveReceivedFiles",
                    transferLifecycle(
                        SAVE_REQUEST_ID, authority, grantId, grantRevision, transferId,
                    ),
                ).awaitMap(40)
                assertState(saved, "saved")
                val readback = RdpOwnedSafDocumentsProvider.assertProviderReadback(
                    instrumentation.context,
                    outboundName,
                    descriptor.expectedOutboundSha256,
                )

                val retired = client.call(
                    "retireFileTransferGrant",
                    grantRequest(RETIRE_REQUEST_ID, authority, grantId, grantRevision),
                ).awaitMap()
                assertState(retired, "retired")
                assertGrantRetired(ownedActivity, tree)

                client.cancelEvents(SESSION_REQUEST_ID)
                // Production disposal is not swallowed. The exact bridge session and SAF
                // coordinator retire; the process owner must become acquirable after the
                // asynchronous native/manager drain before the claim is written.
                client.disposeProductionBridgeAndProveOwnersReleased()

                writeOwnedWitness(
                    appContext,
                    descriptor,
                    directTargetBlocked = true,
                    gatewayPinMatched = true,
                    targetPinMatched = true,
                    frameAcknowledged = true,
                    nativeDrainConfirmed = true,
                    safReadbackSha256 = readback,
                    ownersRetired = true,
                )
            } finally {
                descriptor.close()
                runCatching {
                    instrumentation.context.revokeUriPermission(tree, REQUIRED_ACCESS_FLAGS)
                }
            }
        }
    }

    private fun gatewayInspection(descriptor: OwnedDescriptor): Map<String, Any> = mapOf(
        "schemaVersion" to 6,
        "requestId" to SESSION_REQUEST_ID,
        "target" to mapOf(
            "host" to descriptor.targetHost,
            "port" to descriptor.targetPort,
            "username" to descriptor.targetUsername,
        ),
        "gateway" to mapOf(
            "host" to descriptor.gatewayHost,
            "port" to descriptor.gatewayPort,
            "username" to descriptor.gatewayUsername,
            "domain" to descriptor.gatewayDomain,
        ),
    )

    private fun sessionRequest(descriptor: OwnedDescriptor, transferId: String): Map<String, Any?> =
        mapOf(
            "schemaVersion" to 6,
            "requestId" to SESSION_REQUEST_ID,
            "targetHost" to descriptor.targetHost,
            "targetPort" to descriptor.targetPort,
            "username" to descriptor.targetUsername,
            "domain" to descriptor.targetDomain,
            "gateway" to mapOf(
                "host" to descriptor.gatewayHost,
                "port" to descriptor.gatewayPort,
                "username" to descriptor.gatewayUsername,
                "domain" to descriptor.gatewayDomain,
                "certificateFingerprint" to descriptor.gatewayPin,
            ),
            "certificateFingerprint" to descriptor.targetPin,
            "requiresNla" to true,
            "display" to mapOf(
                "width" to 1024,
                "height" to 768,
                "desktopScaleFactor" to 100,
                "deviceScaleFactor" to 100,
                "externalDisplay" to false,
                "dynamicResize" to false,
            ),
            "keyboardLayout" to "us",
            "clipboardMode" to "disabled",
            "audio" to false,
            "microphone" to false,
            "files" to true,
            "sessionRevision" to SESSION_REVISION,
            "fileTransfer" to mapOf("transferId" to transferId),
        )

    private fun transferPrepare(authority: Map<String, Any>, grantId: String, revision: Long) =
        mapOf(
            "schemaVersion" to 6,
            "requestId" to PREPARE_REQUEST_ID,
            "authority" to authority,
            "grantId" to grantId,
            "grantRevision" to revision,
            "sessionRequestId" to SESSION_REQUEST_ID,
            "sessionRevision" to SESSION_REVISION,
        )

    private fun transferLifecycle(
        requestId: String,
        authority: Map<String, Any>,
        grantId: String,
        revision: Long,
        transferId: String,
    ) = transferPrepare(authority, grantId, revision).toMutableMap().apply {
        this["requestId"] = requestId
        this["transferId"] = transferId
    }

    private fun grantRequest(
        requestId: String,
        authority: Map<String, Any>,
        grantId: String,
        revision: Long,
    ) = mapOf(
        "schemaVersion" to 5,
        "requestId" to requestId,
        "authority" to authority,
        "grantId" to grantId,
        "expectedGrantRevision" to revision,
    )

    private fun authority(nonce: String): Map<String, Any> = mapOf(
        "schemaVersion" to 5,
        "namespaceDigest" to ("namespace:$nonce").sha256(),
        "profileRef" to ("profile:$nonce").sha256(),
        "profileRevision" to 1L,
    )

    private fun assertHostSideMirrorOutbound(file: File, expectedSha256: String) {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(30)
        while (System.nanoTime() < deadline) {
            if (file.isFile && file.length() == 93L && file.sha256() == expectedSha256) return
            Thread.sleep(25)
        }
        throw AssertionError("owned outbound mirror effect was not observed")
    }

    private fun assertPersistedReadWriteGrant(context: Context, tree: Uri) {
        val permission = context.contentResolver.persistedUriPermissions.single { it.uri == tree }
        assertTrue(permission.isReadPermission)
        assertTrue(permission.isWritePermission)
    }

    private fun assertGrantRetired(context: Context, tree: Uri) {
        assertFalse(context.contentResolver.persistedUriPermissions.any { it.uri == tree })
    }

    private fun assertState(value: Map<*, *>, state: String) {
        assertEquals(state, value["state"])
    }

    private fun writeOwnedWitness(
        context: Context,
        descriptor: OwnedDescriptor,
        directTargetBlocked: Boolean,
        gatewayPinMatched: Boolean,
        targetPinMatched: Boolean,
        frameAcknowledged: Boolean,
        nativeDrainConfirmed: Boolean,
        safReadbackSha256: String,
        ownersRetired: Boolean,
    ) {
        val file = File(context.filesDir, "f62-owned-gateway-saf-public-witness-${descriptor.nonce}.json")
        require(!file.exists())
        val value = JSONObject().apply {
            put("schemaVersion", 2)
            put("nonce", descriptor.nonce)
            put("testClass", RdpPackagedGatewaySafPublicBridgeAcceptanceTest::class.java.name)
            put("testName", POSITIVE_TEST_NAME)
            put("tests", 1)
            put("failures", 0)
            put("errors", 0)
            put("skipped", 0)
            put("directTargetBlocked", directTargetBlocked)
            put("gatewayPinMatched", gatewayPinMatched)
            put("targetPinMatched", targetPinMatched)
            put("frameAcknowledged", frameAcknowledged)
            put("nativeDrainConfirmed", nativeDrainConfirmed)
            put("safReadbackSha256", safReadbackSha256)
            put("ownersRetired", ownersRetired)
        }.toString().toByteArray(StandardCharsets.US_ASCII)
        val atomic = AtomicFile(file)
        val output = atomic.startWrite()
        try {
            Os.fchmod(output.fd, 0x180)
            output.write(value)
            output.fd.sync()
            atomic.finishWrite(output)
        } catch (failure: Exception) {
            atomic.failWrite(output)
            throw failure
        } finally {
            value.fill(0)
        }
    }

    private fun onMain(block: () -> Unit) {
        InstrumentationRegistry.getInstrumentation().runOnMainSync(block)
    }

    private fun awaitWindowFocus(activity: MainActivity) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10)
        while (System.nanoTime() < deadline) {
            instrumentation.waitForIdleSync()
            if (activity.hasWindowFocus()) return
            Thread.sleep(25)
        }
        throw AssertionError("production activity did not gain focus")
    }

    private inner class OwnedRegisteredChannelClient(private val activity: MainActivity) {
        private val bridge: RdpNativeBridge = registeredBridge(activity)
        private val methods = registeredHandler(activity, RdpNativeBridge.METHODS)
        private val events = registeredHandler(activity, RdpNativeBridge.EVENTS)

        fun call(method: String, arguments: Any?): PendingCall {
            val result = PendingCall()
            onMain {
                val request = StandardMethodCodec.INSTANCE
                    .encodeMethodCall(MethodCall(method, arguments))
                    .also { it.flip() }
                methods.onMessage(
                    request,
                ) { reply -> result.complete(reply) }
            }
            return result
        }

        fun listen(requestId: String) {
            eventControl("listen", requestId)
        }

        fun cancelEvents(requestId: String) {
            eventControl("cancel", requestId)
        }

        fun disposeProductionBridgeAndProveOwnersReleased() {
            val transfersField = RdpNativeBridge::class.java.getDeclaredField("safTransfers").apply {
                isAccessible = true
            }
            val transfers = requireNotNull(transfersField.get(bridge))
            val ownerField = transfers.javaClass.getDeclaredField("processOwner").apply {
                isAccessible = true
            }
            val owner = requireNotNull(ownerField.get(transfers))
            val tryAcquire = owner.javaClass.getDeclaredMethod("tryAcquire", Any::class.java).apply {
                isAccessible = true
            }
            val release = owner.javaClass.getDeclaredMethod("release", Any::class.java).apply {
                isAccessible = true
            }
            onMain { bridge.dispose() }
            val disposedField = RdpNativeBridge::class.java.getDeclaredField("disposed").apply {
                isAccessible = true
            }
            if (disposedField.get(bridge) != true) {
                throw AssertionError("production bridge did not retire")
            }
            val probeToken = Any()
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(6)
            while (System.nanoTime() < deadline) {
                if (tryAcquire.invoke(owner, probeToken) == true) {
                    release.invoke(owner, probeToken)
                    return
                }
                Thread.sleep(25)
            }
            throw AssertionError("production SAF owner did not retire")
        }

        private fun eventControl(method: String, requestId: String) {
            val result = PendingCall()
            onMain {
                val request = StandardMethodCodec.INSTANCE
                    .encodeMethodCall(MethodCall(method, requestId))
                    .also { it.flip() }
                events.onMessage(
                    request,
                ) { reply -> result.complete(reply) }
            }
            result.awaitNull()
        }

        fun awaitPendingFrameSequence(seconds: Long): Long {
            val sessionField = RdpNativeBridge::class.java.getDeclaredField("session").apply {
                isAccessible = true
            }
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(seconds)
            while (System.nanoTime() < deadline) {
                val current = sessionField.get(bridge) as? RdpFreeRdpSession
                current?.pendingFrame?.let { return it.sequence }
                Thread.sleep(25)
            }
            throw AssertionError("owned initial frame timeout")
        }
    }

    private fun registeredBridge(activity: MainActivity): RdpNativeBridge {
        val field = MainActivity::class.java.getDeclaredField("rdpNative").apply {
            isAccessible = true
        }
        return field.get(activity) as? RdpNativeBridge
            ?: throw AssertionError("production RDP bridge missing")
    }

    private fun registeredHandler(
        activity: MainActivity,
        channel: String,
    ): io.flutter.plugin.common.BinaryMessenger.BinaryMessageHandler {
        val engineMethod = io.flutter.embedding.android.FlutterActivity::class.java
            .getDeclaredMethod("getFlutterEngine").apply { isAccessible = true }
        val engine = engineMethod.invoke(activity) as? io.flutter.embedding.engine.FlutterEngine
            ?: throw AssertionError("production Flutter engine missing")
        val wrapper = engine.dartExecutor.binaryMessenger
        if (wrapper.javaClass.name != DEFAULT_BINARY_MESSENGER) {
            throw AssertionError("production binary messenger identity changed")
        }
        val messengerField = wrapper.javaClass.getDeclaredField("messenger").apply {
            isAccessible = true
        }
        val messenger = messengerField.get(wrapper)
            ?: throw AssertionError("production Dart messenger missing")
        if (messenger.javaClass.name != DART_MESSENGER) {
            throw AssertionError("production Dart messenger identity changed")
        }
        val handlersField = messenger.javaClass.getDeclaredField("messageHandlers").apply {
            isAccessible = true
        }
        val lockField = messenger.javaClass.getDeclaredField("handlersLock").apply {
            isAccessible = true
        }
        val handlers = handlersField.get(messenger) as? Map<*, *>
            ?: throw AssertionError("production channel registry missing")
        val lock = lockField.get(messenger)
            ?: throw AssertionError("production channel registry lock missing")
        val info = synchronized(lock) { handlers[channel] }
            ?: throw AssertionError("production channel handler missing")
        val handlerField = info.javaClass.getDeclaredField("handler").apply { isAccessible = true }
        return handlerField.get(info) as? io.flutter.plugin.common.BinaryMessenger.BinaryMessageHandler
            ?: throw AssertionError("production channel handler malformed")
    }

    private class PendingCall {
        private val latch = CountDownLatch(1)
        @Volatile private var value: Any? = null
        @Volatile private var error: String? = null

        fun complete(reply: ByteBuffer?) {
            try {
                value = if (reply == null) null else {
                    val readable = reply.duplicate()
                    if (readable.position() <= 0) {
                        throw AssertionError("owned reply envelope is empty")
                    }
                    readable.flip()
                    StandardMethodCodec.INSTANCE.decodeEnvelope(readable)
                }
            } catch (failure: FlutterException) {
                error = failure.code
            } finally {
                latch.countDown()
            }
        }

        fun awaitMap(seconds: Long = 10): Map<*, *> {
            assertTrue("owned method timeout", latch.await(seconds, TimeUnit.SECONDS))
            error?.let { throw AssertionError("owned method rejected: $it") }
            return value as? Map<*, *> ?: throw AssertionError("owned receipt malformed")
        }

        fun awaitNull(seconds: Long = 10) {
            assertTrue("owned method timeout", latch.await(seconds, TimeUnit.SECONDS))
            error?.let { throw AssertionError("owned method rejected: $it") }
            assertEquals(null, value)
        }

        fun awaitError(seconds: Long = 10): String {
            assertTrue("owned method timeout", latch.await(seconds, TimeUnit.SECONDS))
            return error ?: throw AssertionError("owned error was not observed")
        }
    }

    private data class OwnedDescriptor(
        val nonce: String,
        val gatewayHost: String,
        val gatewayPort: Int,
        val gatewayUsername: String,
        val gatewayPassword: CharArray,
        val gatewayDomain: String,
        val gatewayPin: String,
        val targetHost: String,
        val targetPort: Int,
        val targetUsername: String,
        val targetDomain: String,
        val targetPassword: CharArray,
        val targetPin: String,
        val expectedUploadSha256: String,
        val expectedOutboundSha256: String,
    ) : AutoCloseable {
        override fun close() {
            gatewayPassword.fill('\u0000')
            targetPassword.fill('\u0000')
        }

        companion object {
            private val HEX_64 = Regex("^[0-9a-f]{64}$")
            private val PIN = Regex("^SHA256:[A-Za-z0-9+/]{43}$")
            private val KEYS = setOf(
                "schemaVersion", "nonce", "sourceSha256", "testSha256",
                "fixtureSourceSha256", "targetPatchSha256", "targetSourceManifestSha256",
                "gatewayHost", "gatewayPort", "gatewayUsername", "gatewayPassword", "gatewayDomain",
                "gatewayPin", "targetHost", "targetPort", "targetUsername", "targetDomain",
                "targetPassword", "targetPin", "expectedUploadSha256", "expectedOutboundSha256",
            )

            fun load(context: Context): OwnedDescriptor {
                val arguments = InstrumentationRegistry.getArguments()
                val nonce = requireNotNull(arguments.getString("rdpGatewaySafNonce"))
                val sourceSha256 = requireNotNull(arguments.getString("rdpGatewaySafSourceSha256"))
                val testSha256 = requireNotNull(arguments.getString("rdpGatewaySafTestSha256"))
                require(HEX_64.matches(nonce) && HEX_64.matches(sourceSha256) && HEX_64.matches(testSha256))
                val file = File(context.filesDir, "f62-owned-gateway-saf-$nonce.json")
                val bytes = readOwned(file)
                require(file.delete() && !file.exists())
                try {
                    val json = JSONObject(String(bytes, StandardCharsets.UTF_8))
                    require(json.keys().asSequence().toSet() == KEYS)
                    require(json.getInt("schemaVersion") == 1)
                    require(json.getString("nonce") == nonce)
                    require(json.getString("sourceSha256") == sourceSha256)
                    require(json.getString("testSha256") == testSha256)
                    listOf(
                        "fixtureSourceSha256", "targetPatchSha256", "targetSourceManifestSha256",
                        "expectedUploadSha256", "expectedOutboundSha256",
                    ).forEach { require(HEX_64.matches(json.getString(it))) }
                    val gatewayPin = json.getString("gatewayPin")
                    val targetPin = json.getString("targetPin")
                    require(PIN.matches(gatewayPin) && PIN.matches(targetPin))
                    return OwnedDescriptor(
                        nonce,
                        json.getString("gatewayHost"),
                        json.getInt("gatewayPort").also { require(it in 1..65535) },
                        json.getString("gatewayUsername"),
                        json.getString("gatewayPassword").toCharArray(),
                        json.getString("gatewayDomain"),
                        gatewayPin,
                        json.getString("targetHost"),
                        json.getInt("targetPort").also { require(it in 1..65535) },
                        json.getString("targetUsername"),
                        json.getString("targetDomain"),
                        json.getString("targetPassword").toCharArray(),
                        targetPin,
                        json.getString("expectedUploadSha256"),
                        json.getString("expectedOutboundSha256"),
                    ).also {
                        require(it.gatewayPassword.isNotEmpty() && it.targetPassword.isNotEmpty())
                    }
                } finally {
                    bytes.fill(0)
                }
            }

            private fun readOwned(file: File): ByteArray {
                val descriptor = Os.open(
                    file.absolutePath,
                    OsConstants.O_RDONLY or OsConstants.O_CLOEXEC or OsConstants.O_NOFOLLOW,
                    0,
                )
                return try {
                    val stat = Os.fstat(descriptor)
                    require(stat.st_mode and OsConstants.S_IFMT == OsConstants.S_IFREG)
                    require(stat.st_mode and 0x1ff == 0x180)
                    require(stat.st_uid == android.os.Process.myUid())
                    require(stat.st_nlink == 1L && stat.st_size in 1..4096)
                    FileInputStream(descriptor).use { stream ->
                        val result = ByteArray(stat.st_size.toInt())
                        var offset = 0
                        while (offset < result.size) {
                            val count = stream.read(result, offset, result.size - offset)
                            require(count > 0)
                            offset += count
                        }
                        require(stream.read() == -1)
                        result
                    }
                } finally {
                    runCatching { Os.close(descriptor) }
                }
            }
        }
    }

    private fun CharArray.utf8(): ByteArray =
        StandardCharsets.UTF_8.encode(java.nio.CharBuffer.wrap(this)).let { buffer ->
            ByteArray(buffer.remaining()).also { buffer.get(it) }
        }

    private fun File.sha256(): String = inputStream().use { input ->
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(4096)
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            digest.update(buffer, 0, count)
        }
        buffer.fill(0)
        digest.digest().hex()
    }

    private fun String.sha256() = toByteArray(StandardCharsets.UTF_8).sha256()
    private fun ByteArray.sha256() = MessageDigest.getInstance("SHA-256").digest(this).hex()
    private fun ByteArray.hex() = joinToString("") { "%02x".format(it) }
    private fun Map<*, *>.requiredString(key: String) = requireNotNull(this[key] as? String)
    private fun Map<*, *>.requiredMap(key: String) =
        this[key] as? Map<*, *> ?: throw AssertionError("owned map malformed")
    private fun Map<*, *>.requiredLong(key: String): Long = when (val value = this[key]) {
        is Int -> value.toLong()
        is Long -> value
        else -> error("invalid private receipt")
    }

    companion object {
        private const val DEFAULT_BINARY_MESSENGER =
            "io.flutter.embedding.engine.dart.DartExecutor\$DefaultBinaryMessenger"
        private const val DART_MESSENGER =
            "io.flutter.embedding.engine.dart.DartMessenger"
        private const val POSITIVE_TEST_NAME =
            "gatewaySafPublicMethodChannelPathProvesTwoPinsNlaRdpdrDrainAndSafReadback"
        private const val SELECT_REQUEST_ID = "62736271-0000-4000-8000-000000000001"
        private const val ACTIVATE_REQUEST_ID = "62736271-0000-4000-8000-000000000002"
        private const val PREPARE_REQUEST_ID = "62736271-0000-4000-8000-000000000003"
        private const val SESSION_REQUEST_ID = "62736271-0000-4000-8000-000000000004"
        private const val DRAIN_REQUEST_ID = "62736271-0000-4000-8000-000000000005"
        private const val SAVE_REQUEST_ID = "62736271-0000-4000-8000-000000000006"
        private const val RETIRE_REQUEST_ID = "62736271-0000-4000-8000-000000000007"
        private const val SESSION_REVISION = 2L
        private const val REQUIRED_ACCESS_FLAGS =
            Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        private const val REQUIRED_PICKER_FLAGS = REQUIRED_ACCESS_FLAGS or
            Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
            Intent.FLAG_GRANT_PREFIX_URI_PERMISSION
    }
}
