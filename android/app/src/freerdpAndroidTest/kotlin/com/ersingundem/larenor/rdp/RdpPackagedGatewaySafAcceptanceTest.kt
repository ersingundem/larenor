package com.ersingundem.larenor.rdp

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.system.Os
import android.system.OsConstants
import android.util.AtomicFile
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.ersingundem.larenor.MainActivity
import com.ersingundem.larenor.rdp.packaged.RdpPackagedRuntime
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Separate owned acceptance for Gateway TLS/NLA plus a real SAF-backed RDPDR round trip.
 * Product feature admission remains masked until the host and client receipts are joined.
 */
@RunWith(AndroidJUnit4::class)
class RdpPackagedGatewaySafAcceptanceTest {
    @Test
    fun gatewaySafProvesTwoHopPinsNlaAndRdpdrRoundTripAfterExplicitDrain() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val appContext = instrumentation.targetContext
        val descriptor = OwnedDescriptor.load(appContext)
        val uploadName = "upload-" + descriptor.nonce.take(16) + ".bin"
        val outboundName = "outbound-" + descriptor.nonce.take(16) + ".bin"
        val upload = ("Larenor-F62-Gateway-upload:" + descriptor.nonce).toByteArray(StandardCharsets.US_ASCII)
        val outbound = ("Larenor-F62-Gateway-outbound:" + descriptor.nonce).toByteArray(StandardCharsets.US_ASCII)
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

        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            val activity = AtomicReference<MainActivity>()
            scenario.onActivity(activity::set)
            val ownedActivity = requireNotNull(activity.get())
            val grantHost = OwnedGrantHost(instrumentation.context, ownedActivity, tree)
            val grantStore = RdpSafGrantStore(ownedActivity)
            val grants = RdpSafGrantBroker(grantHost, grantStore)
            val transferStoreRoot = File(ownedActivity.noBackupFilesDir, "rdp-saf-transfers-v1")
            val currentSession = AtomicReference<RdpNativeSession?>()
            val transfers = RdpSafTransferCoordinator(
                ownedActivity,
                grants,
                foreground = { true },
                clearSession = { session -> currentSession.compareAndSet(session, null) },
            )
            try {
                onMain {
                    grants.setResumed(true)
                    grants.setWindowFocused(true)
                }
                val authority = authority(descriptor.nonce)
                val selected = OwnedResult()
                onMain {
                    grants.select(
                        mapOf(
                            "schemaVersion" to 5,
                            "requestId" to SELECT_REQUEST_ID,
                            "authority" to authority,
                        ),
                        selected,
                    )
                    grantHost.deliver(requireNotNull(grantHost.requestCode), grants)
                }
                val preparedGrant = selected.awaitMap()
                assertState(preparedGrant, "prepared")
                assertPersistedReadWriteGrant(ownedActivity, tree)
                val grantId = preparedGrant.requiredString("grantId")
                val grantRevision = preparedGrant.requiredLong("grantRevision")

                val activated = OwnedResult()
                onMain {
                    grants.activate(
                        grantRequest(ACTIVATE_REQUEST_ID, authority, grantId, grantRevision),
                        activated,
                    )
                }
                assertState(activated.awaitMap(), "active")
                assertPrivateDirectory(requireNotNull(grantStore.fileForTest.parentFile))
                assertPrivateFile(grantStore.fileForTest)

                val preparedTransfer = OwnedResult()
                onMain {
                    transfers.prepare(
                        transferPrepare(authority, grantId, grantRevision),
                        preparedTransfer,
                    )
                }
                val transferReceipt = preparedTransfer.awaitMap(40)
                assertState(transferReceipt, "prepared")
                val transferId = transferReceipt.requiredString("transferId")

                val runtime = RdpPackagedRuntime(ownedActivity)
                assertTrue(RdpFreeRdpPackage.verify(runtime.identity()))
                assertDirectTargetBlocked(runtime, descriptor)

                val gatewayProbe = runtime.inspectGateway(
                    descriptor.targetHost,
                    descriptor.targetPort,
                    descriptor.targetUsername,
                    RdpJniGatewayEndpoint(
                        descriptor.gatewayHost,
                        descriptor.gatewayPort,
                        descriptor.gatewayUsername,
                        descriptor.gatewayDomain,
                    ),
                )
                val gatewayEvidence = runProbe(gatewayProbe)
                assertEquals(descriptor.gatewayPin, gatewayEvidence.certificateFingerprint)

                val gatewayProbePassword = descriptor.gatewayPassword.copyOf()
                val targetProbe = runtime.inspectTargetThroughGateway(
                    descriptor.targetHost,
                    descriptor.targetPort,
                    descriptor.targetUsername,
                    descriptor.targetDomain,
                    descriptor.gateway(),
                    gatewayProbePassword,
                )
                assertTrue(gatewayProbePassword.all { it == '\u0000' })
                val targetEvidence = runProbe(targetProbe)
                assertEquals(descriptor.targetPin, targetEvidence.certificateFingerprint)

                val request = sessionRequest(descriptor, transferId, files = true)
                val endpoint = requireNotNull(transfers.endpointForOpen(request))
                val mirrorRoot = File(endpoint.canonicalRoot)
                assertPrivateDirectory(mirrorRoot.parentFile?.parentFile ?: error("missing mirror base"))
                assertPrivateDirectory(requireNotNull(mirrorRoot.parentFile))
                assertPrivateDirectory(mirrorRoot)
                assertPrivateDirectory(File(mirrorRoot, RdpSafDocumentsAdapter.TO_REMOTE))
                assertPrivateDirectory(File(mirrorRoot, RdpSafDocumentsAdapter.FROM_REMOTE))
                assertPrivateFile(File(mirrorRoot, "${RdpSafDocumentsAdapter.TO_REMOTE}/$uploadName"))
                assertPrivateDirectory(transferStoreRoot)
                assertPrivateFile(File(transferStoreRoot, "journal.enc"))
                val security = CountDownLatch(1)
                val frame = CountDownLatch(1)
                val observer = object : RdpNativeSessionObserver {
                    override fun onSecurity() = security.countDown()
                    override fun onFrame() = frame.countDown()
                }
                val targetPassword = descriptor.targetPassword.copyOf()
                val gatewayPassword = descriptor.gatewayPassword.copyOf()
                val session = RdpNativeAdapter(RdpFreeRdpBackend(runtime)).open(
                    request,
                    RdpNativeSecrets.take(targetPassword, gatewayPassword),
                    observer,
                    endpoint,
                ) as RdpFreeRdpSession
                assertTrue(targetPassword.all { it == '\u0000' })
                assertTrue(gatewayPassword.all { it == '\u0000' })
                currentSession.set(session)
                onMain { transfers.sessionOpened(session) }
                assertTrue("Gateway target security", security.await(10, TimeUnit.SECONDS))
                assertTrue("Gateway target initial frame", frame.await(30, TimeUnit.SECONDS))
                val initial = requireNotNull(session.pendingFrame)
                assertTrue(session.acknowledgeFrame(initial.sequence))

                assertHostSideMirrorOutbound(
                    endpoint.canonicalRoot,
                    outboundName,
                    descriptor.expectedOutboundSha256,
                )
                assertPrivateFile(File(
                    mirrorRoot,
                    "${RdpSafDocumentsAdapter.FROM_REMOTE}/$outboundName",
                ))

                val drain = OwnedResult()
                onMain {
                    transfers.drain(
                        transferLifecycle(DRAIN_REQUEST_ID, authority, grantId, grantRevision, transferId),
                        drain,
                    )
                }
                assertState(drain.awaitMap(40), "sealed")
                assertTrue(currentSession.get() == null)
                assertPrivateDirectory(transferStoreRoot)
                assertPrivateFile(File(transferStoreRoot, "journal.enc"))
                assertPrivateDirectory(mirrorRoot)
                assertPrivateDirectory(File(mirrorRoot, RdpSafDocumentsAdapter.TO_REMOTE))
                assertPrivateDirectory(File(mirrorRoot, RdpSafDocumentsAdapter.FROM_REMOTE))
                assertPrivateFile(File(mirrorRoot, "${RdpSafDocumentsAdapter.TO_REMOTE}/$uploadName"))
                assertPrivateFile(File(
                    mirrorRoot,
                    "${RdpSafDocumentsAdapter.FROM_REMOTE}/$outboundName",
                ))

                val save = OwnedResult()
                onMain {
                    transfers.save(
                        transferLifecycle(SAVE_REQUEST_ID, authority, grantId, grantRevision, transferId),
                        save,
                    )
                }
                val saved = save.awaitMap(40)
                assertState(saved, "saved")
                val readback = RdpOwnedSafDocumentsProvider.assertProviderReadback(
                    instrumentation.context,
                    outboundName,
                    descriptor.expectedOutboundSha256,
                )

                val retired = OwnedResult()
                onMain {
                    grants.retire(
                        grantRequest(RETIRE_REQUEST_ID, authority, grantId, grantRevision),
                        retired,
                    )
                }
                assertState(retired.awaitMap(), "retired")
                assertGrantRetired(ownedActivity, tree)
                transfers.close()
                grants.dispose()
                grantHost.revokeTemporary()
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
                runCatching { currentSession.getAndSet(null)?.close() }
                runCatching { transfers.close() }
                runCatching { grants.dispose() }
                runCatching { grantHost.revokeTemporary() }
            }
        }
    }

    /** Each negative is run with a fresh target fixture process; it never shares the positive lifetime. */
    @Test
    fun gatewaySafRejectsWrongGatewayPinBeforeCredentials() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        OwnedDescriptor.load(context).use { descriptor ->
            val runtime = RdpPackagedRuntime(context)
            assertWrongPinRejected(runtime, descriptor)
        }
    }

    @Test
    fun gatewaySafPickerCancellationDoesNotPersistOrPrepare() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        OwnedDescriptor.load(context).use { descriptor ->
            val tree = RdpOwnedSafDocumentsProvider.reset(
                instrumentation.context,
                "upload-" + descriptor.nonce.take(16) + ".bin",
                ("Larenor-F62-Gateway-upload:" + descriptor.nonce).toByteArray(StandardCharsets.US_ASCII),
            )
            ActivityScenario.launch(MainActivity::class.java).use { scenario ->
                val activity = AtomicReference<MainActivity>()
                scenario.onActivity(activity::set)
                val owned = requireNotNull(activity.get())
                val host = OwnedGrantHost(instrumentation.context, owned, tree)
                val broker = RdpSafGrantBroker(host, RdpSafGrantStore(owned))
                val result = OwnedResult()
                onMain {
                    broker.setResumed(true)
                    broker.setWindowFocused(true)
                    broker.select(
                        mapOf("schemaVersion" to 5, "requestId" to SELECT_REQUEST_ID,
                            "authority" to authority(descriptor.nonce)),
                        result,
                    )
                    broker.cancel(
                        mapOf("schemaVersion" to 5, "requestId" to SELECT_REQUEST_ID),
                        OwnedResult(),
                    )
                }
                assertEquals("cancelled", result.awaitError())
                assertFalse(owned.contentResolver.persistedUriPermissions.any { it.uri == tree })
                assertFalse(broker.onActivityResult(
                    requireNotNull(host.requestCode),
                    Activity.RESULT_OK,
                    Intent().setData(tree),
                ))
                broker.dispose()
            }
        }
    }

    private fun assertPrivateDirectory(value: File) {
        val stat = Os.stat(value.absolutePath)
        assertTrue(stat.st_mode and OsConstants.S_IFMT == OsConstants.S_IFDIR)
        assertEquals(RDP_SAF_PRIVATE_DIRECTORY_MODE, stat.st_mode and 0x1ff)
    }

    private fun assertPrivateFile(value: File) {
        val stat = Os.stat(value.absolutePath)
        assertTrue(stat.st_mode and OsConstants.S_IFMT == OsConstants.S_IFREG)
        assertEquals(RDP_SAF_PRIVATE_FILE_MODE, stat.st_mode and 0x1ff)
    }

    private fun assertWrongPinRejected(runtime: RdpPackagedRuntime, descriptor: OwnedDescriptor) {
        val password = descriptor.gatewayPassword.copyOf()
        val wrong = descriptor.gatewayPin.replaceRange(7, 8,
            if (descriptor.gatewayPin[7] == 'A') "B" else "A")
        val operation = runtime.inspectTargetThroughGateway(
            descriptor.targetHost,
            descriptor.targetPort,
            descriptor.targetUsername,
            descriptor.targetDomain,
            descriptor.gateway().copy(certificateFingerprint = wrong),
            password,
        )
        assertTrue(password.all { it == '\u0000' })
        assertThrows(Exception::class.java) { operation.run() }
        assertTrue(operation.closeAndAwaitDrain())
    }

    private fun assertDirectTargetBlocked(runtime: RdpPackagedRuntime, descriptor: OwnedDescriptor) {
        assertThrows(Exception::class.java) {
            runtime.inspect(descriptor.targetHost, descriptor.targetPort, descriptor.targetUsername)
        }
    }

    private fun runProbe(operation: RdpJniCertificateProbeOperation): RdpJniCertificateProbe = try {
        operation.run()
    } finally {
        assertTrue(operation.closeAndAwaitDrain())
    }

    private fun assertHostSideMirrorOutbound(
        canonicalRoot: String,
        name: String,
        expectedSha256: String,
    ) {
        val output = File(canonicalRoot, "FromRemote/$name")
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(30)
        while (System.nanoTime() < deadline) {
            if (output.isFile && output.length() == 93L && output.sha256() == expectedSha256) return
            Thread.sleep(25)
        }
        throw AssertionError("owned outbound mirror effect was not observed")
    }

    private fun sessionRequest(
        descriptor: OwnedDescriptor,
        transferId: String,
        files: Boolean,
    ): RdpNativeRequest = RdpNativeRequest.parse(mapOf(
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
            "width" to 1024, "height" to 768,
            "desktopScaleFactor" to 100, "deviceScaleFactor" to 100,
            "externalDisplay" to false, "dynamicResize" to false,
        ),
        "keyboardLayout" to "us",
        "clipboardMode" to "disabled",
        "audio" to false,
        "microphone" to false,
        "files" to files,
        "sessionRevision" to SESSION_REVISION,
        "fileTransfer" to if (files) mapOf("transferId" to transferId) else null,
    ))

    private fun transferPrepare(authority: Map<String, Any>, grantId: String, revision: Long) = mapOf(
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
        val file = File(context.filesDir, "f62-owned-gateway-saf-witness-${descriptor.nonce}.json")
        require(!file.exists())
        val value = JSONObject().apply {
            put("schemaVersion", 2)
            put("nonce", descriptor.nonce)
            put("testClass", RdpPackagedGatewaySafAcceptanceTest::class.java.name)
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
    private fun Map<*, *>.requiredLong(key: String): Long = when (val value = this[key]) {
        is Int -> value.toLong()
        is Long -> value
        else -> error("invalid private receipt")
    }

    private class OwnedGrantHost(
        private val testContext: Context,
        private val activity: Activity,
        private val tree: Uri,
    ) : RdpSafGrantHost {
        var requestCode: Int? = null
            private set

        override fun launch(intent: Intent, requestCode: Int) {
            assertEquals(Intent.ACTION_OPEN_DOCUMENT_TREE, intent.action)
            assertTrue(intent.flags and REQUIRED_FLAGS == REQUIRED_FLAGS)
            assertTrue(this.requestCode == null)
            this.requestCode = requestCode
        }

        fun deliver(requestCode: Int, broker: RdpSafGrantBroker) {
            testContext.grantUriPermission(activity.packageName, tree, REQUIRED_FLAGS)
            val result = Intent().setData(tree).addFlags(REQUIRED_FLAGS)
            assertTrue(broker.onActivityResult(requestCode, Activity.RESULT_OK, result))
        }

        override fun persistedFlags(uri: Uri): Int {
            val value = activity.contentResolver.persistedUriPermissions.singleOrNull { it.uri == uri }
                ?: return 0
            return (if (value.isReadPermission) Intent.FLAG_GRANT_READ_URI_PERMISSION else 0) or
                (if (value.isWritePermission) Intent.FLAG_GRANT_WRITE_URI_PERMISSION else 0)
        }

        override fun take(uri: Uri, flags: Int) {
            activity.contentResolver.takePersistableUriPermission(uri, flags)
        }

        override fun release(uri: Uri, flags: Int) {
            activity.contentResolver.releasePersistableUriPermission(uri, flags)
        }

        fun revokeTemporary() {
            testContext.revokeUriPermission(tree, REQUIRED_ACCESS_FLAGS)
        }

        companion object {
            private const val REQUIRED_ACCESS_FLAGS =
                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            private const val REQUIRED_FLAGS = REQUIRED_ACCESS_FLAGS or
                Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION
        }
    }

    private class OwnedResult : MethodChannel.Result {
        private val latch = CountDownLatch(1)
        private var value: Any? = null
        private var error: String? = null

        override fun success(result: Any?) {
            value = result
            latch.countDown()
        }

        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
            error = errorCode
            latch.countDown()
        }

        override fun notImplemented() {
            error = "notImplemented"
            latch.countDown()
        }

        fun awaitMap(seconds: Long = 10): Map<*, *> {
            assertTrue("owned result timeout", latch.await(seconds, TimeUnit.SECONDS))
            error?.let { throw AssertionError("owned operation rejected: $it") }
            return value as? Map<*, *> ?: throw AssertionError("owned receipt malformed")
        }

        fun awaitError(seconds: Long = 10): String {
            assertTrue("owned result timeout", latch.await(seconds, TimeUnit.SECONDS))
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
        fun gateway() = RdpNativeGateway(
            gatewayHost, gatewayPort, gatewayUsername, gatewayDomain, gatewayPin,
        )

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
                    listOf("fixtureSourceSha256", "targetPatchSha256", "targetSourceManifestSha256",
                        "expectedUploadSha256", "expectedOutboundSha256").forEach {
                        require(HEX_64.matches(json.getString(it)))
                    }
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
                    ).also { descriptor ->
                        require(descriptor.gatewayPassword.isNotEmpty() && descriptor.targetPassword.isNotEmpty())
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

    companion object {
        private const val POSITIVE_TEST_NAME =
            "gatewaySafProvesTwoHopPinsNlaAndRdpdrRoundTripAfterExplicitDrain"
        private const val SELECT_REQUEST_ID = "62736270-0000-4000-8000-000000000001"
        private const val ACTIVATE_REQUEST_ID = "62736270-0000-4000-8000-000000000002"
        private const val PREPARE_REQUEST_ID = "62736270-0000-4000-8000-000000000003"
        private const val SESSION_REQUEST_ID = "62736270-0000-4000-8000-000000000004"
        private const val DRAIN_REQUEST_ID = "62736270-0000-4000-8000-000000000005"
        private const val SAVE_REQUEST_ID = "62736270-0000-4000-8000-000000000006"
        private const val RETIRE_REQUEST_ID = "62736270-0000-4000-8000-000000000007"
        private const val SESSION_REVISION = 1L
    }
}
