package com.ersingundem.larenor.notifications

import android.app.Application
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class LocalNotificationDeliveryTransportTest {
    private lateinit var server: MockWebServer
    private lateinit var transport: LocalNotificationDeliveryTransport

    @Before fun start() {
        val certificate = HeldCertificate.Builder()
            .commonName("localhost")
            .addSubjectAlternativeName("localhost")
            .build()
        val serverCertificates = HandshakeCertificates.Builder()
            .heldCertificate(certificate)
            .build()
        val clientCertificates = HandshakeCertificates.Builder()
            .addTrustedCertificate(certificate.certificate)
            .build()
        server = MockWebServer()
        server.useHttps(serverCertificates.sslSocketFactory(), tunnelProxy = false)
        server.start()
        transport = LocalNotificationDeliveryTransport(
            OkHttpClient.Builder()
                .sslSocketFactory(clientCertificates.sslSocketFactory(), clientCertificates.trustManager)
                .followRedirects(false)
                .followSslRedirects(false)
                .retryOnConnectionFailure(false)
                .build(),
        )
    }

    @After fun stop() = server.shutdown()

    @Test fun trustedTlsPullUsesOnlyDeliveryCredentialAndRecoversAfterTransientFailure() {
        server.enqueue(MockResponse().setResponseCode(503))
        server.enqueue(jsonResponse(events(publicEvent()), nextAfter = 8))
        val record = record()

        assertSame(DeliveryPullResult.TransientFailure, transport.pull(record))
        val result = transport.pull(record)
        assertTrue(result is DeliveryPullResult.Success)
        result as DeliveryPullResult.Success
        assertEquals(1, result.events.size)
        assertTrue(result.more)
        val first = server.takeRequest()
        val second = server.takeRequest()
        assertEquals("GET", second.method)
        assertEquals("synthetic_delivery_credential", second.getHeader("X-Larenor-Delivery-Credential"))
        assertNull(second.getHeader("Authorization"))
        assertNull(second.getHeader("Cookie"))
        assertNull(first.getHeader("Authorization"))
        assertEquals(
            "/api/v1/local-notifications/${"a".repeat(32)}/${"b".repeat(32)}/" +
                "delivery-leases/${"e".repeat(32)}/events?expectedLeaseRevision=7&after=5&limit=50",
            second.path,
        )
    }

    @Test fun duplicateSequenceAndUnsafeTargetAreProtocolRejected() {
        server.enqueue(jsonResponse(events(publicEvent(sequence = 5)), nextAfter = null))
        assertSame(DeliveryPullResult.ProtocolRejected, transport.pull(record()))

        server.enqueue(jsonResponse(events(publicEvent(target = "//attacker")), nextAfter = null))
        assertSame(DeliveryPullResult.ProtocolRejected, transport.pull(record()))
    }

    @Test fun conflictIsDistinctFromPermanentAuthorityRetirement() {
        server.enqueue(MockResponse().setResponseCode(409))
        assertSame(DeliveryPullResult.LeaseRenewalRequired, transport.pull(record()))
        server.enqueue(MockResponse().setResponseCode(410))
        assertSame(DeliveryPullResult.AuthorityRejected, transport.pull(record()))
    }

    @Test fun productionTrustDoesNotAcceptTheTestOnlyCertificate() {
        server.enqueue(jsonResponse(events(publicEvent()), nextAfter = 8))
        assertSame(
            DeliveryPullResult.TransientFailure,
            LocalNotificationDeliveryTransport().pull(record()),
        )
        assertEquals(0, server.requestCount)
    }

    private fun record() = LocalNotificationDeliveryRecord(
        phase = "active",
        baseUrl = server.url("/").toString().removeSuffix("/"),
        coreId = "a".repeat(32),
        homeId = "b".repeat(32),
        bindingId = "c".repeat(64),
        subscriptionId = "d".repeat(32),
        subscriptionRevision = 4,
        leaseId = "e".repeat(32),
        leaseRevision = 7,
        credential = "synthetic_delivery_credential",
        credentialFingerprint = "f".repeat(64),
        expiresAt = 4_102_444_800.0,
        cursor = 5,
    )

    private fun publicEvent(sequence: Long = 8, target: String = "/today") = """
        {"id":"${"1".repeat(32)}","sequence":$sequence,"sensitivity":"public",
         "publicProjection":{"title":"Workshop","body":"Ready","target":"$target","redacted":false}}
    """.trimIndent()

    private fun events(event: String) = "[$event]"

    private fun jsonResponse(events: String, nextAfter: Long?) = MockResponse()
        .setHeader("Content-Type", "application/json")
        .setBody(
            """{"schemaVersion":1,"scope":{"schemaVersion":1,"coreId":"${"a".repeat(32)}","homeId":"${"b".repeat(32)}"},"leaseRevision":7,"subscriptionRevision":4,"events":$events,"nextAfter":${nextAfter ?: "null"}}""",
        )
}
