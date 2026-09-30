package com.ersingundem.larenor.notifications

import android.Manifest
import android.app.Application
import android.app.NotificationManager
import android.content.Context
import androidx.work.ListenableWorker
import androidx.work.Operation
import androidx.work.WorkerFactory
import androidx.work.WorkerParameters
import androidx.work.testing.TestListenableWorkerBuilder
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.SettableFuture
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
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows
import org.robolectric.annotation.Config
import java.io.IOException
import javax.crypto.KeyGenerator

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class LocalNotificationDeliveryWorkerTest {
    private lateinit var app: Application
    private lateinit var server: MockWebServer
    private lateinit var store: LocalNotificationDeliveryStore
    private lateinit var transport: LocalNotificationDeliveryTransport
    private lateinit var record: LocalNotificationDeliveryRecord

    @Before fun start() {
        app = RuntimeEnvironment.getApplication()
        Shadows.shadowOf(app).grantPermissions(Manifest.permission.POST_NOTIFICATIONS)
        val certificate = HeldCertificate.Builder()
            .commonName("localhost")
            .addSubjectAlternativeName("localhost")
            .build()
        val serverCertificates = HandshakeCertificates.Builder().heldCertificate(certificate).build()
        val clientCertificates = HandshakeCertificates.Builder()
            .addTrustedCertificate(certificate.certificate)
            .build()
        server = MockWebServer()
        server.useHttps(serverCertificates.sslSocketFactory(), tunnelProxy = false)
        server.start()
        transport = LocalNotificationDeliveryTransport(
            OkHttpClient.Builder()
                .sslSocketFactory(clientCertificates.sslSocketFactory(), clientCertificates.trustManager)
                .build(),
        )
        val key = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
        store = LocalNotificationDeliveryStore(app) { key }
        store.clear()
        record = LocalNotificationDeliveryRecord(
            "active", server.url("/").toString().removeSuffix("/"), "a".repeat(32), "b".repeat(32),
            "c".repeat(64), "d".repeat(32), 4, "e".repeat(32), 7, "x".repeat(43),
            "f".repeat(64), 4_102_444_800.0, 0,
        )
        store.save(record)
        app.getSharedPreferences(LocalNotificationRenderer.PLATFORM_STORE, Context.MODE_PRIVATE)
            .edit().clear().putString("binding_id", record.bindingId)
            .putString("subscription_id", record.subscriptionId)
            .putLong("subscription_revision", record.subscriptionRevision).commit()
        LocalNotificationRenderer(app).createChannel()
    }

    @After fun stop() {
        store.clear()
        app.getSharedPreferences(LocalNotificationRenderer.PLATFORM_STORE, Context.MODE_PRIVATE)
            .edit().clear().commit()
        (app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).cancelAll()
        server.shutdown()
    }

    @Test fun transientFailureRetriesThreeTimesThenYieldsToPeriodicSchedule() {
        server.enqueue(MockResponse().setResponseCode(503))
        assertEquals("Retry", worker(0).doWork().javaClass.simpleName)
        server.enqueue(MockResponse().setResponseCode(503))
        assertEquals("Success", worker(3).doWork().javaClass.simpleName)
        assertNotNull(store.load())
        assertFalse(platform().getBoolean("recovery_required", false))
    }

    @Test fun conflictKeepsCredentialAndReportsDistinctLeaseRenewal() {
        server.enqueue(MockResponse().setResponseCode(409))
        assertEquals("Success", worker(0).doWork().javaClass.simpleName)
        assertNotNull(store.load())
        assertEquals("deliveryLeaseRenewalRequired", platform().getString("recovery_reason", null))
    }

    @Test fun permanentRetirementClearsCredentialAndOwnedNotifications() {
        val renderer = LocalNotificationRenderer(app)
        renderer.post(
            record.bindingId,
            record.subscriptionRevision,
            LocalNotificationRenderEvent("1".repeat(32), 1, "Larenor", "", true),
        )
        val manager = app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        assertEquals(1, manager.activeNotifications.size)
        server.enqueue(MockResponse().setResponseCode(410))
        assertEquals("Success", worker(0).doWork().javaClass.simpleName)
        assertNull(store.load())
        assertEquals(0, manager.activeNotifications.size)
        assertEquals("deliveryAuthorityRejected", platform().getString("recovery_reason", null))
    }

    @Test fun asynchronousScheduleFailureIsBoundToTheExactCurrentLease() {
        val oldPeriodic = SettableFuture.create<Operation.State.SUCCESS>()
        assertTrue(
            LocalNotificationDeliveryWork.schedule(
                app,
                record,
                store,
                enqueue = { _, _ ->
                    listOf(oldPeriodic, Futures.immediateFuture(Operation.SUCCESS))
                },
                cancel = { fail("stale authority cancelled replacement work") },
            ),
        )
        val replacement = record.copy(
            leaseId = "1".repeat(32),
            leaseRevision = record.leaseRevision + 1,
            credential = "y".repeat(43),
            credentialFingerprint = "2".repeat(64),
        )
        store.save(replacement)
        oldPeriodic.setException(IOException("controlled old enqueue failure"))
        assertFalse(platform().getBoolean("recovery_required", false))

        val currentPeriodic = SettableFuture.create<Operation.State.SUCCESS>()
        var cancellations = 0
        assertTrue(
            LocalNotificationDeliveryWork.schedule(
                app,
                replacement,
                store,
                enqueue = { _, _ ->
                    listOf(currentPeriodic, Futures.immediateFuture(Operation.SUCCESS))
                },
                cancel = { cancellations += 1 },
            ),
        )
        currentPeriodic.setException(IOException("controlled current enqueue failure"))
        assertTrue(platform().getBoolean("recovery_required", false))
        assertEquals("workScheduleUnavailable", platform().getString("recovery_reason", null))
        assertEquals(1, cancellations)
        assertEquals(replacement, store.load())
    }

    private fun worker(attempt: Int): LocalNotificationDeliveryWorker {
        val factory = object : WorkerFactory() {
            override fun createWorker(
                appContext: Context,
                workerClassName: String,
                workerParameters: WorkerParameters,
            ): ListenableWorker? = if (workerClassName == LocalNotificationDeliveryWorker::class.java.name) {
                LocalNotificationDeliveryWorker(appContext, workerParameters, store, transport)
            } else null
        }
        return TestListenableWorkerBuilder.from(app, LocalNotificationDeliveryWorker::class.java)
            .setRunAttemptCount(attempt)
            .setWorkerFactory(factory)
            .build()
    }

    private fun platform() = app.getSharedPreferences(
        LocalNotificationRenderer.PLATFORM_STORE,
        Context.MODE_PRIVATE,
    )
}
