package com.ersingundem.larenor.updater

import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okio.Buffer
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

internal fun releaseJson(bytes: ByteArray = "fixture apk bytes".toByteArray()): Map<String, Any> = mapOf(
    "schemaVersion" to 1, "applicationId" to ClientRelease.APPLICATION_ID, "versionCode" to 20,
    "versionName" to "2.0", "certificateSha256" to "a".repeat(64), "apkSha256" to sha256(bytes),
    "sizeBytes" to bytes.size, "minSdk" to 26, "commit" to "b".repeat(40),
    "downloadPath" to "/api/v1/client/releases/20/apk", "publishedAt" to "2026-09-05T08:00:00Z", "releaseNotes" to "Fixture release")
internal fun release() = ClientRelease.parse(releaseJson())
internal fun installed() = InstalledClient(ClientRelease.APPLICATION_ID, 19, "1.9", setOf("a".repeat(64)), 35)
internal fun archive() = ArchiveIdentity(ClientRelease.APPLICATION_ID, 20, "2.0", 26, setOf("a".repeat(64)), true)
internal fun failure(code: String, block: () -> Unit) {
    try { block(); fail("Expected a typed update failure") }
    catch(e: UpdateFailure) { assertEquals(code, e.code); assertEquals("Client update unavailable", e.message) }
}

class UpdateSecurityTest {
    @Test fun strictManifestRejectsWrongApplicationPathsAndUnboundedFields() {
        assertEquals(20L, release().versionCode)
        for (change in listOf(
            mapOf("applicationId" to "foreign.app"), mapOf("schemaVersion" to 2), mapOf("versionCode" to 20.0),
            mapOf("downloadPath" to "https://other.example/apk"), mapOf("downloadPath" to "/api/v1/client/releases/20/../apk"),
            mapOf("sizeBytes" to ClientRelease.MAX_BYTES + 1), mapOf("sizeBytes" to 0), mapOf("minSdk" to 25),
            mapOf("certificateSha256" to "x".repeat(64)), mapOf("publishedAt" to "2026-09-05"),
            mapOf("releaseNotes" to "x".repeat(12001)), mapOf("unexpected" to "field"))) {
            failure("invalidMetadata") { ClientRelease.parse(releaseJson() + change) }
        }
    }
    @Test fun signerPackageHigherVersionAndCryptographicEvidenceAreAllRequired() {
        UpdateValidation.archive(release(), installed(), archive())
        for (client in listOf(installed().copy(versionCode = 20), installed().copy(versionCode = 21),
            installed().copy(certificates = setOf("c".repeat(64))), installed().copy(certificates = emptySet()),
            installed().copy(certificates = setOf("a".repeat(64), "c".repeat(64))), installed().copy(sdkInt = 25))) {
            failure("incompatible") { UpdateValidation.preflight(release(), client) }
        }
        for (apk in listOf(archive().copy(cryptographicallyVerified = false), archive().copy(applicationId = "foreign.app"),
            archive().copy(versionCode = 19), archive().copy(versionName = "not announced"), archive().copy(minSdk = 27),
            archive().copy(certificates = setOf("c".repeat(64))))) {
            failure("verification") { UpdateValidation.archive(release(), installed(), apk) }
        }
    }
    @Test fun configuredOriginAndProxyPrefixArePreservedWithoutNormalizationAmbiguity() {
        val url = UpdateValidation.url("http://[::1]:8124/proxy/", release())
        assertEquals("http://[::1]:8124/proxy/api/v1/client/releases/20/apk", url.toString())
        for (base in listOf("http://user:pass@localhost", "http://localhost/proxy/../other", "http://localhost/proxy/%2e%2e",
            "http://localhost/proxy%2fother", "http://localhost/path?token=private", "http://localhost/#fragment", "http://localhost\\evil")) {
            failure("invalidMetadata") { UpdateValidation.url(base, release()) }
        }
    }
    @Test fun exactHashSizeAndAuthorizationRoundtripUsesOneRequest() {
        val server = MockWebServer(); server.start()
        val file = File.createTempFile("client-update", ".part")
        try {
            server.enqueue(MockResponse().setBody("fixture apk bytes"))
            val progress = mutableListOf<Long>()
            UpdateDownloader().download(server.url("/prefix/").toString(), "synthetic-session", release(), file, UpdateCancellation()) { progress.add(it) }
            val request = server.takeRequest(2, TimeUnit.SECONDS)!!
            assertEquals("Bearer synthetic-session", request.getHeader("Authorization"))
            assertEquals("identity", request.getHeader("Accept-Encoding"))
            assertEquals("/prefix/api/v1/client/releases/20/apk", request.path)
            assertEquals("GET", request.method)
            assertArrayEquals("fixture apk bytes".toByteArray(), file.readBytes())
            assertEquals(release().sizeBytes, progress.last())
            assertEquals(1, server.requestCount)
        } finally { file.delete(); server.shutdown() }
    }
    @Test fun redirectsNeverReachEvenAnotherLocalEndpointAndAuthenticationIsNotReplayed() {
        val source = MockWebServer(); val trap = MockWebServer(); source.start(); trap.start()
        val file = File.createTempFile("client-update", ".part")
        try {
            source.enqueue(MockResponse().setResponseCode(302).setHeader("Location", trap.url("/steal")))
            failure("redirect") { UpdateDownloader().download(source.url("/").toString(), "synthetic-session", release(), file, UpdateCancellation()) {} }
            assertEquals(0, trap.requestCount)
            source.enqueue(MockResponse().setResponseCode(401).setBody("private server error"))
            failure("authentication") { UpdateDownloader().download(source.url("/").toString(), "synthetic-session", release(), file, UpdateCancellation()) {} }
            assertEquals(2, source.requestCount)
        } finally { file.delete(); source.shutdown(); trap.shutdown() }
    }
    @Test fun oversizeChunkedAndTruncatedOrWrongHashNeverVerify() {
        val server = MockWebServer(); server.start(); val file = File.createTempFile("client-update", ".part")
        try {
            for (body in listOf("fixture apk bytes EXTRA", "short", "fixture apk wrong")) {
                server.enqueue(MockResponse().setChunkedBody(body, 2))
                failure("verification") { UpdateDownloader().download(server.url("/").toString(), "synthetic-session", release(), file, UpdateCancellation()) {} }
            }
        } finally { file.delete(); server.shutdown() }
    }
    @Test fun cancellationInterruptsARealPendingResponseWithoutRetry() {
        val server = MockWebServer(); server.start(); val file = File.createTempFile("client-update", ".part")
        val bytes = ByteArray(32768) { 5 }; val release = ClientRelease.parse(releaseJson(bytes))
        val cancellation = UpdateCancellation(); val result = AtomicReference<String>(); val done = CountDownLatch(1)
        try {
            server.enqueue(MockResponse().setBody(Buffer().write(bytes)).throttleBody(1, 1, TimeUnit.SECONDS))
            val thread = Thread {
                try { UpdateDownloader().download(server.url("/").toString(), "synthetic-session", release, file, cancellation) {}; result.set("unexpected success") }
                catch(e: UpdateFailure) { result.set(e.code) }
                finally { done.countDown() }
            }
            thread.start(); assertNotNull(server.takeRequest(3, TimeUnit.SECONDS)); cancellation.cancel()
            assertTrue(done.await(3, TimeUnit.SECONDS)); assertEquals("cancelled", result.get()); assertEquals(1, server.requestCount)
        } finally { cancellation.cancel(); file.delete(); server.shutdown() }
    }
}

class UpdateCoordinatorTest {
    private class Host: UpdateHost {
        var active = true; var client: InstalledClient = com.ersingundem.larenor.updater.installed(); var identity = archive()
        override fun installed(): InstalledClient = client
        override fun foreground() = active
        override fun verify(file: File) = identity
    }
    private fun withCoordinator(block: (UpdateCoordinator, Host, File) -> Unit) {
        val directory = Files.createTempDirectory("client-updates").toFile(); val host = Host()
        val coordinator = UpdateCoordinator(directory, host)
        try { coordinator.activate("synthetic-session-one"); block(coordinator, host, directory) }
        finally { coordinator.dispose(); directory.deleteRecursively() }
    }
    @Test fun lateAccountDownloadCannotBecomeInstallableAndOwnPartialIsRemoved() = withCoordinator { coordinator, _, _ ->
        val work = coordinator.beginDownload("synthetic-session-one", release()); work.file.writeText("fixture apk bytes")
        coordinator.activate("synthetic-session-two")
        failure("cancelled") { coordinator.finishDownload(work) }
        coordinator.failed(work); assertFalse(work.file.exists())
        failure("expired") { coordinator.beginInstall("synthetic-session-two", work.id) }
    }
    @Test fun duplicateOperationsFailAndBackgroundCancelsWithoutRevivingOldWork() = withCoordinator { coordinator, host, _ ->
        val work = coordinator.beginDownload("synthetic-session-one", release())
        failure("busy") { coordinator.beginDownload("synthetic-session-one", release()) }
        host.active = false; coordinator.suspend(); host.active = true
        failure("cancelled") { coordinator.verify(work) }
        coordinator.failed(work)
    }
    @Test fun verifiedStageSurvivesPermissionScreenButInstallationIsFreshAndOneUse() = withCoordinator { coordinator, host, _ ->
        val work = coordinator.beginDownload("synthetic-session-one", release()); work.file.writeText("fixture apk bytes")
        coordinator.verify(work); val stage = coordinator.finishDownload(work)
        assertFalse(work.file.exists()); assertTrue(stage.file.isFile)
        host.active = false; coordinator.suspend()
        failure("expired") { coordinator.beginInstall("synthetic-session-one", stage.id) }
        host.active = true
        val install = coordinator.beginInstall("synthetic-session-one", stage.id); coordinator.verify(install)
        assertEquals(stage.file, coordinator.consumeInstall(install))
        coordinator.suspend(); assertTrue(stage.file.exists())
        failure("expired") { coordinator.beginInstall("synthetic-session-one", stage.id) }
    }
    @Test fun logoutRemovesOnlyTheOwnedVerifiedStage() = withCoordinator { coordinator, _, directory ->
        val unrelated = File(directory.parentFile, "unrelated-${directory.name}").also { it.writeText("not an update") }
        try {
            val work = coordinator.beginDownload("synthetic-session-one", release()); work.file.writeText("fixture apk bytes")
            coordinator.verify(work); val stage = coordinator.finishDownload(work)
            coordinator.invalidate("synthetic-session-one")
            assertFalse(stage.file.exists()); assertTrue(unrelated.exists())
        } finally { unrelated.delete() }
    }
    @Test fun changedInstalledVersionOrSignerRejectsPreviouslyStagedApkAtInstall() = withCoordinator { coordinator, host, _ ->
        val work = coordinator.beginDownload("synthetic-session-one", release()); work.file.writeText("fixture apk bytes")
        coordinator.verify(work); val stage = coordinator.finishDownload(work)
        host.client = installed().copy(versionCode = 20)
        val install = coordinator.beginInstall("synthetic-session-one", stage.id)
        failure("incompatible") { coordinator.verify(install) }
        coordinator.failed(install)
    }
    @Test fun staleInvalidationCannotCancelNewAccount() = withCoordinator { coordinator, _, _ ->
        coordinator.activate("synthetic-session-two"); val work = coordinator.beginDownload("synthetic-session-two", release())
        coordinator.invalidate("synthetic-session-one"); coordinator.cancel("synthetic-session-one")
        assertTrue(coordinator.current(work)); coordinator.failed(work)
    }
}
