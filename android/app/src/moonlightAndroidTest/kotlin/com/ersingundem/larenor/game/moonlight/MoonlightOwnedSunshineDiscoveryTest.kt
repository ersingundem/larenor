package com.ersingundem.larenor.game.moonlight

import androidx.test.core.app.ActivityScenario
import com.ersingundem.larenor.MainActivity
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/**
 * Named owned-provider gate. The orchestrator must keep its private Sunshine
 * process alive while this test exercises Moonlight's production NSD service.
 * No endpoint, credential, PIN, or provider path is injected into Android.
 */
@RunWith(AndroidJUnit4::class)
class MoonlightOwnedSunshineDiscoveryTest {
    @Test fun discoversTheExactOwnedSunshineServiceAcrossFreshDiscoveryLifetimes() {
        val arguments = InstrumentationRegistry.getArguments()
        assumeTrue(
            "F60 owned Sunshine discovery is a named opt-in gate",
            arguments.getString(REQUIRED_ARGUMENT) == "required",
        )
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            val runtime = AtomicReference<MoonlightEmbeddedRuntime>()
            scenario.onActivity { activity -> runtime.set(MoonlightEmbeddedRuntime(activity)) }
            val value = checkNotNull(runtime.get())
            val authority = authority()
            value.bindAuthority(authority)
            val expectedInstance = checkNotNull(arguments.getString(MDNS_INSTANCE_ARGUMENT))
            require(expectedInstance.matches(Regex("[A-Za-z0-9-]{1,63}")))
            val endpoints = discoverEndpoints(activity = checkNotNull(scenarioActivity(scenario)))
            assertEquals(1, endpoints.size)
            assertEquals(expectedInstance, endpoints.single().name)
            assertEquals(47_989, endpoints.single().port)
            repeat(2) { offset ->
                val result = discover(value, authority, identity(20 + offset))
                val candidates = result.getOrThrow()
                assertEquals(1, candidates.size)
                val candidate = candidates.single()
                // Raw NSD instance names are host-derived by Sunshine. The
                // public candidate name is read back from real NvHTTP serverinfo.
                assertEquals(OWNED_DISPLAY_NAME, candidate.displayName)
                assertEquals("awake", candidate.powerState)
                assertEquals("notPaired", candidate.pairState)
            }
            value.close()
        }
    }

    private fun scenarioActivity(scenario: ActivityScenario<MainActivity>): MainActivity? {
        val activity = AtomicReference<MainActivity?>()
        scenario.onActivity { value -> activity.set(value) }
        return activity.get()
    }

    private fun discoverEndpoints(activity: MainActivity): List<MoonlightDiscoveredEndpoint> {
        val delivered = CountDownLatch(1)
        val value = AtomicReference<Result<List<MoonlightDiscoveredEndpoint>>?>()
        MoonlightMdnsDiscovery(activity).discover(DISCOVERY_TIMEOUT_MILLIS) { result ->
            value.set(result)
            delivered.countDown()
        }
        if (!delivered.await(DELIVERY_TIMEOUT_SECONDS, TimeUnit.SECONDS)) {
            throw AssertionError("owned Sunshine NSD identity did not complete within the bound")
        }
        return checkNotNull(value.get()).getOrThrow()
    }

    private fun discover(
        runtime: MoonlightEmbeddedRuntime,
        authority: MoonlightAuthority,
        requestId: String,
    ): Result<List<MoonlightCandidate>> {
        val delivered = CountDownLatch(1)
        val value = AtomicReference<Result<List<MoonlightCandidate>>?>()
        runtime.discover(authority, requestId, DISCOVERY_TIMEOUT_MILLIS) { result ->
            value.set(result)
            delivered.countDown()
        }
        if (!delivered.await(DELIVERY_TIMEOUT_SECONDS, TimeUnit.SECONDS)) {
            throw AssertionError("owned Sunshine discovery did not complete within the bound")
        }
        return checkNotNull(value.get())
    }

    private fun authority(): MoonlightAuthority {
        val scope = MoonlightScope(identity(1), identity(2), identity(3), identity(4))
        val clientInstanceId = identity(5)
        return MoonlightAuthority(
            authorityId = sha256(
                "authority\u0000${scope.storageKey}\u0000$clientInstanceId".toByteArray(),
            ).hex().take(32),
            epoch = publicRevision("1", "1", "1", "1", "1", "1", "true", "true", clientInstanceId),
            scope = scope,
            clientInstanceId = clientInstanceId,
            accountRevision = 1,
            pinRevision = 1,
            pinConfigured = true,
            pinUnlocked = true,
            routeRevision = 1,
            lifecycleRevision = 1,
            idleRevision = 1,
            interactionRevision = 1,
        )
    }

    private fun identity(value: Int): String = value.toString(16).padStart(32, '0')

    companion object {
        private const val REQUIRED_ARGUMENT = "larenorF60OwnedDiscovery"
        private const val MDNS_INSTANCE_ARGUMENT = "larenorF60OwnedMdnsInstance"
        private const val OWNED_DISPLAY_NAME = "Larenor-F60-Owned"
        private const val DISCOVERY_TIMEOUT_MILLIS = 20_000L
        private const val DELIVERY_TIMEOUT_SECONDS = 25L
    }
}
