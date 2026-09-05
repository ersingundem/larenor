package com.ersingundem.larenor.audio

import org.junit.Assert.*
import org.junit.Test

class AudioContractTest {
    private fun sourceMap(uri: String = "https://radio.example/live.mp3") = mapOf(
        "id" to "station-one", "uri" to uri, "mimeType" to "audio/mpeg",
        "title" to "User chosen station", "artist" to "Performer", "album" to "Album",
    )
    private fun source() = AudioSource.parse(sourceMap())
    private fun reject(code: String, action: () -> Unit) {
        try { action(); fail("Expected rejection") } catch (error: AudioRejected) {
            assertEquals(code, error.code)
            assertFalse(error.toString().contains("radio.example"))
        }
    }
    private class Owner : AudioOwner {
        var pauses = 0; var resumes = 0; var stops = 0
        val seeks = mutableListOf<Long>()
        var current = AudioSnapshot(phase = "ready", sourceId = "station-one", title = "Station",
            isPlaying = false, positionMs = 1000, durationMs = 10000, canPlay = true,
            canPause = true, canSeek = true, canStop = true)
        override fun pause() { pauses++ }
        override fun resume() { resumes++ }
        override fun seek(positionMs: Long) { seeks.add(positionMs) }
        override fun shutdown() { stops++ }
        override fun snapshot() = current
    }

    @Test fun sourcesRejectCredentialsSchemesMalformedPortsAndPayloads() {
        for (uri in listOf("file:///private/audio.mp3", "content://media/1", "javascript:alert(1)",
            "https://user:password@radio.example/a.mp3", "https://radio.example/a?api_key=secret",
            "https://radio.example/a?", "https://radio.example/a#token", "https://radio.example:0/a",
            "https://radio.example:65536/a", "https://radio.example/a%0D%0ACookie:secret",
            "https://radio.example\\@evil.example/a", "https://radio.example/white space.mp3")) {
            reject("invalidSource") { AudioSource.parse(sourceMap(uri)) }
        }
        for (update in listOf(mapOf("headers" to mapOf("Authorization" to "Bearer secret")),
            mapOf("mimeType" to "video/mp4"), mapOf("id" to "https://secret.example"),
            mapOf("title" to "private\nheader"), mapOf("title" to "x".repeat(257)))) {
            reject("invalidSource") { AudioSource.parse(sourceMap() + update) }
        }
        assertEquals("AudioSource(redacted)", source().toString())
        assertEquals("http", AudioSource.parse(sourceMap("http://192.0.2.1:8123/audio.mp3")).uri.scheme)
        assertEquals("https", AudioSource.parse(sourceMap("https://[2001:db8::1]/audio.ogg")).uri.scheme)
    }

    @Test fun sourceHasNoPersistenceAndSnapshotContainsOnlyPublicMetadata() {
        val coordinator = AudioCoordinator { 0 }
        coordinator.request(source(), true)
        val result = coordinator.state.toMap()
        assertEquals("User chosen station", result["title"])
        assertFalse(result.values.any { it.toString().contains("radio.example") })
        assertFalse(result.containsKey("uri"))
        assertEquals(false, result["isPlaying"])
        assertNull(result["durationMs"])
        val recreatedProcess = AudioCoordinator { 0 }
        assertEquals("idle", recreatedProcess.state.phase)
        assertNull(recreatedProcess.state.sourceId)
        assertFalse(recreatedProcess.hasOwner)
    }

    @Test fun onlyForegroundSingleUseUnexpiredTicketCanSelectSource() {
        var time = 100L
        val coordinator = AudioCoordinator { time }
        reject("foregroundRequired") { coordinator.request(source(), false) }
        val ticket = coordinator.request(source(), true)
        assertNull(coordinator.consume("external-invented-ticket", true))
        assertTrue(coordinator.hasPending)
        reject("busy") { coordinator.request(source(), true) }
        assertEquals("station-one", coordinator.consume(ticket, true)?.id)
        assertNull(coordinator.consume(ticket, true))
        val expired = coordinator.request(source(), true)
        time += 5000
        assertNull(coordinator.consume(expired, true))
        val background = coordinator.request(source(), true)
        assertNull(coordinator.consume(background, false))
        assertFalse(coordinator.hasPending)
    }

    @Test fun stopAndBackgroundCancelLateLaunchWithoutRestoringOldSource() {
        val coordinator = AudioCoordinator { 0 }
        val ticket = coordinator.request(source(), true)
        coordinator.stop()
        assertNull(coordinator.consume(ticket, true))
        val another = coordinator.request(source(), true)
        coordinator.cancelPending()
        assertNull(coordinator.consume(another, true))
        assertEquals("idle", coordinator.state.phase)
    }

    @Test fun observerLifetimeDoesNotControlPlayerAndOldOwnerCannotPublishAfterStop() {
        val coordinator = AudioCoordinator { 0 }
        val owner = Owner()
        coordinator.attach(owner)
        val events = mutableListOf<AudioSnapshot>()
        val cancel = coordinator.observe(events::add)
        coordinator.report(owner, owner.current)
        assertEquals("ready", events.last().phase)
        cancel()
        assertEquals(0, owner.stops)
        coordinator.stop()
        assertEquals(1, owner.stops)
        coordinator.report(owner, owner.current.copy(isPlaying = true))
        assertEquals("idle", coordinator.state.phase)
        coordinator.detach(owner)
        assertEquals("idle", coordinator.state.phase)
    }

    @Test fun boundsAndAvailableActionsGateRealOwnerCommands() {
        val coordinator = AudioCoordinator { 0 }
        val owner = Owner()
        coordinator.attach(owner)
        coordinator.report(owner, owner.current)
        coordinator.pause()
        reject("foregroundRequired") { coordinator.resume(false) }
        coordinator.resume(true)
        coordinator.seek(0)
        coordinator.seek(10000L)
        for (value in listOf(-1, 10001, 1.5, "1000", Long.MAX_VALUE, null)) {
            reject("invalidPosition") { coordinator.seek(value) }
        }
        coordinator.report(owner, owner.current.copy(durationMs = null, canSeek = false))
        reject("invalidPosition") { coordinator.seek(0) }
        assertEquals(listOf(0L, 10000L), owner.seeks)
        assertEquals(1, owner.pauses)
        assertEquals(1, owner.resumes)
        val replacement = Owner()
        reject("busy") { coordinator.attach(replacement) }
    }

    @Test fun nativeMethodContractDoesNotSelectOrStartOnReadAndSettingsRequireForeground() {
        var time = 0L
        val host = object : AudioCommandHost {
            override var foreground = true
            override val coordinator = AudioCoordinator { time }
            val starts = mutableListOf<String>()
            val settings = mutableListOf<Boolean>()
            override fun start(ticket: String) { starts.add(ticket) }
            override fun powerStatus() = mapOf("supported" to true)
            override fun openSettings(notification: Boolean): Boolean { settings.add(notification); return true }
        }
        val router = AudioCommandRouter(host)
        router.call("snapshot", null)
        router.call("powerStatus", null)
        assertTrue(host.starts.isEmpty())
        router.call("play", sourceMap())
        assertEquals(1, host.starts.size)
        assertFalse(host.starts.single().contains("radio.example"))
        reject("busy") { router.call("play", sourceMap()) }
        router.call("stop", null)
        assertNull(host.coordinator.consume(host.starts.single(), true))
        assertEquals(true, router.call("openNotificationSettings", null))
        assertEquals(true, router.call("openBatterySettings", null))
        assertEquals(listOf(true, false), host.settings)
        host.foreground = false
        reject("foregroundRequired") { router.call("play", sourceMap()) }
        reject("foregroundRequired") { router.call("openBatterySettings", null) }
        reject("unsupported") { router.call("startFakeRemoteForegroundService", null) }
        reject("invalidSource") { router.call("stop", mapOf("uri" to "secret")) }
        time++
    }

    @Test fun trustedSystemOrOwnControllersOnlyAndNeverUserPackageNameClaims() {
        assertFalse(AudioControllerPolicy.mayConnect(false, false, false))
        assertTrue(AudioControllerPolicy.mayConnect(true, false, false))
        assertTrue(AudioControllerPolicy.mayConnect(false, true, false))
        assertTrue(AudioControllerPolicy.mayConnect(false, false, true))
    }

    @Test fun sourceReplacementBetweenUiReadAndDispatchCannotControlNewAudio() {
        val owner = Owner()
        val host = object : AudioCommandHost {
            override val foreground = true
            override val coordinator = AudioCoordinator { 0 }
            override fun start(ticket: String) {}
            override fun powerStatus() = emptyMap<String, Any?>()
            override fun openSettings(notification: Boolean) = false
        }
        val coordinator = host.coordinator
        coordinator.attach(owner)
        coordinator.report(owner, owner.current)
        val capturedId = coordinator.state.sourceId
        coordinator.report(owner, owner.current.copy(sourceId = "new-station"))
        val router = AudioCommandRouter(host)
        for (command in listOf("pause", "resume", "stop")) {
            reject("unavailable") { router.call(command, mapOf("sourceId" to capturedId)) }
        }
        reject("unavailable") { router.call("seek", mapOf("sourceId" to capturedId, "positionMs" to 2000)) }
        assertEquals(0, owner.pauses)
        assertEquals(0, owner.resumes)
        assertEquals(0, owner.stops)
        assertTrue(owner.seeks.isEmpty())
        router.call("pause", mapOf("sourceId" to "new-station"))
        router.call("seek", mapOf("sourceId" to "new-station", "positionMs" to 2000))
        assertEquals(1, owner.pauses)
        assertEquals(listOf(2000L), owner.seeks)
        coordinator.request(source(), true)
        reject("unavailable") { router.call("stop", mapOf("sourceId" to "station-one")) }
        // Video handoff intentionally stops any local owner and pending launch.
        router.call("stop", null)
        assertEquals(1, owner.stops)
        assertFalse(coordinator.hasPending)
    }
}
