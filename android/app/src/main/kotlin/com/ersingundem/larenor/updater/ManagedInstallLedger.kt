package com.ersingundem.larenor.updater

import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import java.util.UUID

internal enum class ManagedInstallState {
    submitted,
    confirmed,
    failed,
    cancelled,
    unknown,
}

internal data class ManagedInstallRecord(
    val requestId: String,
    val callerSessionId: String,
    val installerSessionId: Int,
    val applicationId: String,
    val expectedVersionCode: Long,
    val expectedCertificateSha256: String,
    val state: ManagedInstallState,
    val observedVersionCode: Long?,
    val observedCertificateSha256: String?,
    val observedAtEpochMs: Long,
) {
    fun publicReceipt(): Map<String, Any?> = mapOf(
        "schemaVersion" to 1,
        "requestId" to requestId,
        "installerSessionId" to installerSessionId,
        "applicationId" to applicationId,
        "expectedVersionCode" to expectedVersionCode,
        "status" to if (state == ManagedInstallState.submitted) "unknown" else state.name,
        "observedVersionCode" to observedVersionCode,
        "observedCertificateSha256" to observedCertificateSha256,
        "observedAtEpochMs" to observedAtEpochMs,
    )

    fun unresolved(): Boolean = state == ManagedInstallState.submitted || state == ManagedInstallState.unknown
}

/**
 * One private, durable PackageInstaller dispatch record.
 *
 * A missing terminal callback remains unknown. It is never converted into a
 * success from the installed package alone and never causes an automatic
 * resubmission.
 */
internal class ManagedInstallLedger(private val context: Context) {
    private val preferences = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)

    @Synchronized
    fun requireDispatchAvailable() {
        val current = read()
        if ((hasRecord() && current == null) || current?.unresolved() == true) {
            throw UpdateFailure("busy")
        }
    }

    @Synchronized
    fun publicReceipt(): Map<String, Any?>? {
        val record = read()
        if (hasRecord() && record == null) throw UpdateFailure("unavailable")
        return record?.publicReceipt()
    }

    @Synchronized
    fun recordSubmission(
        callerSessionId: String,
        installerSessionId: Int,
        release: ClientRelease,
        requestId: String = UUID.randomUUID().toString().replace("-", ""),
        nowEpochMs: Long = System.currentTimeMillis(),
    ): ManagedInstallRecord {
        if (!SESSION.matches(callerSessionId) ||
            installerSessionId < 0 ||
            !REQUEST.matches(requestId) ||
            release.applicationId != ClientRelease.APPLICATION_ID ||
            release.versionCode !in 1..Int.MAX_VALUE.toLong() ||
            !CERTIFICATE.matches(release.certificateSha256) ||
            nowEpochMs < 0
        ) {
            throw UpdateFailure("invalidMetadata")
        }
        requireDispatchAvailable()
        val record = ManagedInstallRecord(
            requestId = requestId,
            callerSessionId = callerSessionId,
            installerSessionId = installerSessionId,
            applicationId = release.applicationId,
            expectedVersionCode = release.versionCode,
            expectedCertificateSha256 = release.certificateSha256,
            state = ManagedInstallState.submitted,
            observedVersionCode = null,
            observedCertificateSha256 = null,
            observedAtEpochMs = nowEpochMs,
        )
        if (!write(record)) throw UpdateFailure("unavailable")
        return record
    }

    @Synchronized
    fun recordPreCommitFailure(record: ManagedInstallRecord) {
        val current = read() ?: return
        if (!sameRequest(current, record) || current.state != ManagedInstallState.submitted) return
        write(
            current.copy(
                state = ManagedInstallState.failed,
                observedAtEpochMs = System.currentTimeMillis(),
            ),
        )
    }

    @Synchronized
    fun recordCommitUncertain(record: ManagedInstallRecord) {
        val current = read() ?: return
        if (!sameRequest(current, record) || !current.unresolved()) return
        write(
            current.copy(
                state = ManagedInstallState.unknown,
                observedVersionCode = null,
                observedCertificateSha256 = null,
                observedAtEpochMs = System.currentTimeMillis(),
            ),
        )
    }

    @Synchronized
    fun acceptStatus(intent: Intent, installed: () -> InstalledClient) {
        if (intent.action != ManagedInstallStatusReceiver.ACTION) return
        val current = read() ?: return
        val requestId = intent.getStringExtra(ManagedInstallStatusReceiver.EXTRA_REQUEST_ID)
        val installerSessionId = intent.getIntExtra(PackageInstaller.EXTRA_SESSION_ID, -1)
        val applicationId = intent.getStringExtra(PackageInstaller.EXTRA_PACKAGE_NAME)
        if (requestId != current.requestId ||
            installerSessionId != current.installerSessionId ||
            applicationId != current.applicationId
        ) return
        if (!current.unresolved()) return
        val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, Int.MIN_VALUE)
        val now = System.currentTimeMillis()
        val next = when (status) {
            PackageInstaller.STATUS_SUCCESS -> verifyInstalled(current, installed, now)
            PackageInstaller.STATUS_FAILURE_ABORTED -> current.copy(
                state = ManagedInstallState.cancelled,
                observedVersionCode = null,
                observedCertificateSha256 = null,
                observedAtEpochMs = now,
            )
            PackageInstaller.STATUS_PENDING_USER_ACTION -> current.copy(
                state = ManagedInstallState.unknown,
                observedVersionCode = null,
                observedCertificateSha256 = null,
                observedAtEpochMs = now,
            )
            PackageInstaller.STATUS_FAILURE,
            PackageInstaller.STATUS_FAILURE_BLOCKED,
            PackageInstaller.STATUS_FAILURE_CONFLICT,
            PackageInstaller.STATUS_FAILURE_INCOMPATIBLE,
            PackageInstaller.STATUS_FAILURE_INVALID,
            PackageInstaller.STATUS_FAILURE_STORAGE,
            PackageInstaller.STATUS_FAILURE_TIMEOUT,
            -> current.copy(
                state = ManagedInstallState.failed,
                observedVersionCode = null,
                observedCertificateSha256 = null,
                observedAtEpochMs = now,
            )
            else -> current.copy(
                state = ManagedInstallState.unknown,
                observedVersionCode = null,
                observedCertificateSha256 = null,
                observedAtEpochMs = now,
            )
        }
        write(next)
    }

    @Synchronized
    fun read(): ManagedInstallRecord? {
        if (!hasRecord()) return null
        if (preferences.getInt(KEY_SCHEMA_VERSION, -1) != 2) return null
        val requestId = preferences.getString(KEY_REQUEST_ID, null)
        val callerSessionId = preferences.getString(KEY_CALLER_SESSION_ID, null)
        val installerSessionId = preferences.getInt(KEY_INSTALLER_SESSION_ID, -1)
        val applicationId = preferences.getString(KEY_APPLICATION_ID, null)
        val expectedVersion = preferences.getLong(KEY_EXPECTED_VERSION, -1)
        val expectedCertificate = preferences.getString(KEY_EXPECTED_CERTIFICATE, null)
        val state = preferences.getString(KEY_STATE, null)?.let {
            ManagedInstallState.entries.firstOrNull { candidate -> candidate.name == it }
        }
        val observedVersion = preferences.getLong(KEY_OBSERVED_VERSION, -1).takeIf { it >= 1 }
        val observedCertificate = preferences.getString(KEY_OBSERVED_CERTIFICATE, null)
        val observedAt = preferences.getLong(KEY_OBSERVED_AT, -1)
        if (requestId == null || !REQUEST.matches(requestId) ||
            callerSessionId == null || !SESSION.matches(callerSessionId) ||
            installerSessionId < 0 ||
            applicationId != ClientRelease.APPLICATION_ID ||
            expectedVersion !in 1..Int.MAX_VALUE.toLong() ||
            expectedCertificate == null || !CERTIFICATE.matches(expectedCertificate) ||
            state == null || observedAt < 0 ||
            (observedCertificate != null && !CERTIFICATE.matches(observedCertificate)) ||
            ((observedVersion == null) != (observedCertificate == null)) ||
            (state == ManagedInstallState.confirmed &&
                (observedVersion != expectedVersion || observedCertificate != expectedCertificate))
        ) {
            return null
        }
        return ManagedInstallRecord(
            requestId,
            callerSessionId,
            installerSessionId,
            applicationId,
            expectedVersion,
            expectedCertificate,
            state,
            observedVersion,
            observedCertificate,
            observedAt,
        )
    }

    private fun verifyInstalled(
        current: ManagedInstallRecord,
        installed: () -> InstalledClient,
        now: Long,
    ): ManagedInstallRecord {
        val observation = try {
            installed()
        } catch (_: Exception) {
            null
        }
        val certificate = observation?.certificates?.singleOrNull()
        val confirmed = observation != null &&
            observation.applicationId == current.applicationId &&
            observation.versionCode == current.expectedVersionCode &&
            certificate == current.expectedCertificateSha256
        return current.copy(
            state = if (confirmed) ManagedInstallState.confirmed else ManagedInstallState.unknown,
            observedVersionCode = observation?.versionCode?.takeIf { certificate != null },
            observedCertificateSha256 = certificate,
            observedAtEpochMs = now,
        )
    }

    private fun write(record: ManagedInstallRecord): Boolean = preferences.edit()
        .putInt(KEY_SCHEMA_VERSION, 2)
        .putString(KEY_REQUEST_ID, record.requestId)
        .putString(KEY_CALLER_SESSION_ID, record.callerSessionId)
        .putInt(KEY_INSTALLER_SESSION_ID, record.installerSessionId)
        .putString(KEY_APPLICATION_ID, record.applicationId)
        .putLong(KEY_EXPECTED_VERSION, record.expectedVersionCode)
        .putString(KEY_EXPECTED_CERTIFICATE, record.expectedCertificateSha256)
        .putString(KEY_STATE, record.state.name)
        .putLong(KEY_OBSERVED_VERSION, record.observedVersionCode ?: -1)
        .putString(KEY_OBSERVED_CERTIFICATE, record.observedCertificateSha256)
        .putLong(KEY_OBSERVED_AT, record.observedAtEpochMs)
        .commit()

    private fun hasRecord() = preferences.contains(KEY_SCHEMA_VERSION)

    private fun sameRequest(left: ManagedInstallRecord, right: ManagedInstallRecord) =
        left.requestId == right.requestId &&
            left.installerSessionId == right.installerSessionId &&
            left.callerSessionId == right.callerSessionId &&
            left.applicationId == right.applicationId &&
            left.expectedVersionCode == right.expectedVersionCode &&
            left.expectedCertificateSha256 == right.expectedCertificateSha256

    private companion object {
        const val PREFERENCES = "managed_client_install_v2"
        const val KEY_SCHEMA_VERSION = "schemaVersion"
        const val KEY_REQUEST_ID = "requestId"
        const val KEY_CALLER_SESSION_ID = "callerSessionId"
        const val KEY_INSTALLER_SESSION_ID = "installerSessionId"
        const val KEY_APPLICATION_ID = "applicationId"
        const val KEY_EXPECTED_VERSION = "expectedVersionCode"
        const val KEY_EXPECTED_CERTIFICATE = "expectedCertificateSha256"
        const val KEY_STATE = "state"
        const val KEY_OBSERVED_VERSION = "observedVersionCode"
        const val KEY_OBSERVED_CERTIFICATE = "observedCertificateSha256"
        const val KEY_OBSERVED_AT = "observedAtEpochMs"
        val REQUEST = Regex("[a-f0-9]{32}")
        val SESSION = Regex("[a-zA-Z0-9-]{16,80}")
        val CERTIFICATE = Regex("[a-f0-9]{64}")
    }
}
