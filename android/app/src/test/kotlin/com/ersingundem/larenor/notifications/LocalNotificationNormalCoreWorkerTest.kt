package com.ersingundem.larenor.notifications

import android.Manifest
import android.app.Application
import android.app.NotificationManager
import android.content.Context
import androidx.work.Configuration
import androidx.work.ListenableWorker
import androidx.work.WorkManager
import androidx.work.WorkerFactory
import androidx.work.WorkerParameters
import androidx.work.testing.SynchronousExecutor
import androidx.work.testing.WorkManagerTestInitHelper
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows
import org.robolectric.annotation.Config
import java.io.File
import java.security.KeyStore
import java.security.cert.CertificateFactory
import java.util.concurrent.TimeUnit
import javax.crypto.KeyGenerator
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager

/** Uses the normal Core TLS listener owned by f54_native_service_acceptance.py. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class LocalNotificationNormalCoreWorkerTest {
    @Test fun scheduledWorkerPullSealsCursorRestartsWithoutDuplicateAndClearsOnCoreRevoke() {
        val fixturePath = System.getenv("LARENOR_F54_NATIVE_FIXTURE")
        assumeTrue("requires owned normal TLS Core fixture", fixturePath != null)
        val config = JSONObject(File(fixturePath!!).readText())
        val trust = KeyStore.getInstance(KeyStore.getDefaultType()).apply { load(null) }
        File(config.getString("caFile")).inputStream().use {
            trust.setCertificateEntry("owned-core", CertificateFactory.getInstance("X.509").generateCertificate(it))
        }
        val managerFactory = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm()).apply { init(trust) }
        val trustManager = managerFactory.trustManagers.filterIsInstance<X509TrustManager>().single()
        val ssl = SSLContext.getInstance("TLS").apply { init(null, arrayOf(trustManager), null) }
        val client = OkHttpClient.Builder()
            .sslSocketFactory(ssl.socketFactory, trustManager)
            .followRedirects(false).followSslRedirects(false)
            .retryOnConnectionFailure(false).callTimeout(5, TimeUnit.SECONDS).build()
        val transport = LocalNotificationDeliveryTransport(client)
        val record = LocalNotificationDeliveryRecord(
            "active", config.getString("baseUrl"), config.getString("coreId"), config.getString("homeId"),
            config.getString("bindingId"), config.getString("subscriptionId"), config.getLong("subscriptionRevision"),
            config.getString("leaseId"), config.getLong("leaseRevision"), config.getString("credential"),
            config.getString("credentialFingerprint"), config.getDouble("expiresAt"), 0,
        )
        val app = RuntimeEnvironment.getApplication()
        Shadows.shadowOf(app).grantPermissions(Manifest.permission.POST_NOTIFICATIONS)
        val key = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
        val store = LocalNotificationDeliveryStore(app) { key }
        val factory = object : WorkerFactory() {
            override fun createWorker(
                appContext: Context,
                workerClassName: String,
                workerParameters: WorkerParameters,
            ): ListenableWorker? = if (workerClassName == LocalNotificationDeliveryWorker::class.java.name) {
                LocalNotificationDeliveryWorker(appContext, workerParameters, store, transport)
            } else null
        }
        WorkManagerTestInitHelper.initializeTestWorkManager(
            app,
            Configuration.Builder().setExecutor(SynchronousExecutor()).setWorkerFactory(factory).build(),
        )
        val work = WorkManager.getInstance(app)
        store.clear()
        store.save(record)
        val platform = app.getSharedPreferences(LocalNotificationRenderer.PLATFORM_STORE, Context.MODE_PRIVATE)
        platform.edit().clear().putString("binding_id", record.bindingId)
            .putString("subscription_id", record.subscriptionId)
            .putLong("subscription_revision", record.subscriptionRevision).commit()
        LocalNotificationRenderer(app).createChannel()
        val manager = app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        fun alerts() = manager.activeNotifications.filter { it.notification.channelId == LocalNotificationRenderer.CHANNEL_ID }
        try {
            assertTrue(LocalNotificationDeliveryWork.schedule(app, record, store))
            runImmediate(work, app)
            await { store.load()?.cursor == config.getLong("eventSequence") && alerts().size == 1 }
            val alert = alerts().single()
            assertEquals("Larenor", alert.notification.extras.getString("android.title"))
            assertFalse(alert.notification.extras.getString("android.text").orEmpty().contains("Synthetic private"))
            assertNotNull(alert.notification.publicVersion)
            assertFalse(alert.notification.extras.toString().contains("Synthetic private"))
            val sealed = app.getSharedPreferences("larenor_local_notification_delivery_store_v1", Context.MODE_PRIVATE)
                .all.toString()
            assertFalse(sealed.contains(record.credential))
            assertFalse(sealed.contains(record.baseUrl))

            // A fresh Worker instance reads the durable record after a simulated
            // process restart. An old cursor cannot duplicate the notification.
            store.save(record)
            assertTrue(LocalNotificationDeliveryWork.schedule(app, record, store))
            runImmediate(work, app)
            await { store.load()?.cursor == config.getLong("eventSequence") }
            assertEquals(listOf(alert.id), alerts().map { it.id })

            client.newCall(Request.Builder().url(config.getString("revokeUrl"))
                .header("Authorization", "Bearer " + config.getString("accessToken"))
                .delete().build()).execute().use { assertEquals(204, it.code) }
            val periodic = work.getWorkInfosForUniqueWork(LocalNotificationDeliveryWork.PERIODIC_NAME).get()
                .single { !it.state.isFinished }
            WorkManagerTestInitHelper.getTestDriver(app)!!.setPeriodDelayMet(periodic.id)
            WorkManagerTestInitHelper.getTestDriver(app)!!.setAllConstraintsMet(periodic.id)
            await { !store.hasSealedRecord() && alerts().isEmpty() }
            assertNull(store.load())
            assertEquals("deliveryAuthorityRejected", platform.getString("recovery_reason", null))
        } finally {
            LocalNotificationDeliveryWork.stop(app)
            store.clear()
            platform.edit().clear().commit()
            manager.cancelAll()
            WorkManagerTestInitHelper.closeWorkDatabase()
        }
    }

    private fun runImmediate(work: WorkManager, context: Context) {
        val info = work.getWorkInfosForUniqueWork(LocalNotificationDeliveryWork.IMMEDIATE_NAME).get()
            .single { !it.state.isFinished }
        WorkManagerTestInitHelper.getTestDriver(context)!!.setAllConstraintsMet(info.id)
    }

    private fun await(check: () -> Boolean) {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(12)
        while (!check()) {
            if (System.nanoTime() >= deadline) fail("normal Core worker condition did not complete")
            Thread.sleep(20)
        }
    }
}
