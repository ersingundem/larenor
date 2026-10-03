package com.ersingundem.larenor.rdp

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import java.security.SecureRandom

internal interface RdpSafGrantHost {
    fun launch(intent: Intent, requestCode: Int)
    fun persistedFlags(uri: Uri): Int
    fun take(uri: Uri, flags: Int)
    fun release(uri: Uri, flags: Int)
}

private class ActivityRdpSafGrantHost(private val activity: Activity) : RdpSafGrantHost {
    override fun launch(intent: Intent, requestCode: Int) {
        @Suppress("DEPRECATION")
        activity.startActivityForResult(intent, requestCode)
    }

    override fun persistedFlags(uri: Uri): Int {
        val permission = activity.contentResolver.persistedUriPermissions.singleOrNull { it.uri == uri }
            ?: return 0
        return (if (permission.isReadPermission) Intent.FLAG_GRANT_READ_URI_PERMISSION else 0) or
            (if (permission.isWritePermission) Intent.FLAG_GRANT_WRITE_URI_PERMISSION else 0)
    }

    override fun take(uri: Uri, flags: Int) {
        activity.contentResolver.takePersistableUriPermission(uri, flags)
    }

    override fun release(uri: Uri, flags: Int) {
        activity.contentResolver.releasePersistableUriPermission(uri, flags)
    }
}

/** Owns one bounded DocumentsUI picker and durable SAF permission retirement. */
internal class RdpSafGrantBroker(
    private val host: RdpSafGrantHost,
    private val store: RdpSafGrantStore,
    private val handler: Handler = Handler(Looper.getMainLooper()),
    private val now: () -> Long = { System.currentTimeMillis() },
    private val grantId: () -> String = {
        ByteArray(16).also(SecureRandom()::nextBytes).joinToString("") { "%02x".format(it) }
    },
) {
    constructor(activity: Activity) : this(
        ActivityRdpSafGrantHost(activity),
        RdpSafGrantStore(activity),
    )

    private data class Pending(
        val request: RdpSafSelectRequest,
        val grantId: String,
        val revision: Long,
        val requestCode: Int,
        val result: MethodChannel.Result,
        val generation: Long,
    )

    private data class PendingResult(
        val pending: Pending,
        val resultCode: Int,
        val data: Intent?,
    )

    private var pending: Pending? = null
    private var pendingResult: PendingResult? = null
    private var generation = 0L
    private var deadline: Runnable? = null
    private var resumed = false
    private var focused = true
    private var disposed = false
    private val issuedRequestCodes = mutableSetOf<Int>()
    private var nextRequestCode = REQUEST_CODE_BASE

    fun setResumed(value: Boolean) {
        if (disposed) return
        resumed = value
        processDeferredIfForeground()
    }

    fun setWindowFocused(value: Boolean) {
        if (disposed) return
        focused = value
        processDeferredIfForeground()
    }

    fun select(raw: Any?, result: MethodChannel.Result) {
        val request = parse(result) { RdpSafContract.select(raw) } ?: return
        if (disposed) return error(result, "unavailable")
        if (!foreground()) return error(result, "authority_changed")
        if (pending != null) return error(result, "busy")
        try {
            val currentNow = now()
            var records = pruned(store.read(), currentNow)
            records.singleOrNull { it.selectRequestId == request.requestId }?.let { existing ->
                if (existing.authority.authorityId != request.authority.authorityId) invalid()
                val index = records.indexOf(existing)
                val reconciled = reconcile(existing, records)
                val updated = records.updated(index, reconciled)
                if (updated != records) store.replace(updated)
                if (reconciled.publicState == RdpSafPublicState.PREPARED &&
                    reconciled.expiresAtMs > currentNow
                ) {
                    result.success(receipt(reconciled, request.requestId))
                    return
                }
                return error(result, "unavailable")
            }
            if (records.any {
                    it.authority.authorityId == request.authority.authorityId &&
                        it.phase != RdpSafGrantPhase.RETIRED
                }
            ) return error(result, "busy")
            val revision = (records.filter { it.authority.authorityId == request.authority.authorityId }
                .maxOfOrNull { it.grantRevision } ?: 0L) + 1L
            if (revision !in 1..RdpSafContract.MAX_JS_SAFE_INTEGER) unavailable()
            val ownedGrantId = grantId()
            if (!RdpSafContract.HEX_32.matches(ownedGrantId) || records.any { it.grantId == ownedGrantId }) {
                unavailable()
            }
            val requestCode = allocateRequestCode()
            val owned = Pending(request, ownedGrantId, revision, requestCode, result, ++generation)
            val record = RdpSafGrantRecord(
                request.authority,
                ownedGrantId,
                revision,
                RdpSafGrantPhase.SELECT_PENDING,
                request.requestId,
                currentNow,
                currentNow + PICKER_DEADLINE_MS,
                null,
                REQUIRED_FLAGS,
                0,
                0,
                null,
                null,
            )
            records = records + record
            store.replace(records)
            pending = owned
            deadline = Runnable {
                if (pending === owned) cancelOwned(owned, "unavailable")
            }.also { handler.postDelayed(it, PICKER_DEADLINE_MS) }
            try {
                host.launch(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply { flags = REQUIRED_FLAGS }, requestCode)
            } catch (_: RuntimeException) {
                cancelOwned(owned, "unavailable")
            }
        } catch (failure: RdpSafFailure) {
            error(result, failure.code)
        } catch (_: Exception) {
            error(result, "unavailable")
        }
    }

    fun cancel(raw: Any?, result: MethodChannel.Result) {
        val requestId = parse(result) { RdpSafContract.cancel(raw) } ?: return
        val owned = pending
        if (owned != null && owned.request.requestId == requestId) {
            cancelOwned(owned, "cancelled")
        }
        result.success(null)
    }

    fun activate(raw: Any?, result: MethodChannel.Result) {
        val request = parse(result) { RdpSafContract.grant(raw) } ?: return
        mutateGrant(request, result) { records, index, record ->
            rejectRequestReuse(records, request, activation = true)
            val reconciled = reconcile(record, records)
            var updated = records.updated(index, reconciled)
            if (updated != records) store.replace(updated)
            if (record.activationRequestId == request.requestId) {
                if (reconciled.phase != RdpSafGrantPhase.ACTIVE) unavailable()
                requirePermission(reconciled)
                result.success(receipt(reconciled, request.requestId))
                return@mutateGrant updated
            }
            if (reconciled.phase == RdpSafGrantPhase.PREPARED && reconciled.expiresAtMs <= now()) {
                expire(updated, index, reconciled)
                unavailable()
            }
            if (reconciled.phase !in setOf(RdpSafGrantPhase.PREPARED, RdpSafGrantPhase.ACTIVE)) {
                unavailable()
            }
            requirePermission(reconciled)
            val activated = reconciled.copy(
                phase = RdpSafGrantPhase.ACTIVE,
                activationRequestId = request.requestId,
            )
            updated = updated.updated(index, activated)
            store.replace(updated)
            result.success(receipt(activated, request.requestId))
            updated
        }
    }

    fun observe(raw: Any?, result: MethodChannel.Result) {
        val request = parse(result) { RdpSafContract.grant(raw) } ?: return
        try {
            val records = store.read()
            val index = records.indexOfFirst { it.grantId == request.grantId }
            if (index < 0) {
                result.success(RdpSafContract.receipt(
                    request.requestId,
                    request.authority.authorityId,
                    request.grantId,
                    request.expectedGrantRevision,
                    RdpSafPublicState.UNKNOWN,
                ))
                return
            }
            var record = exact(records[index], request)
            record = reconcile(record, records)
            var updated = records.updated(index, record)
            if (record.phase == RdpSafGrantPhase.PREPARED && record.expiresAtMs <= now()) {
                record = expire(updated, index, record)
                updated = updated.updated(index, record)
            }
            if (updated[index] != records[index]) store.replace(updated)
            result.success(receipt(record, request.requestId))
        } catch (failure: RdpSafFailure) {
            error(result, failure.code)
        } catch (_: Exception) {
            error(result, "unavailable")
        }
    }

    fun retire(raw: Any?, result: MethodChannel.Result) {
        val request = parse(result) { RdpSafContract.grant(raw) } ?: return
        mutateGrant(request, result) { records, index, record ->
            rejectRequestReuse(records, request, activation = false)
            val reconciled = reconcile(record, records)
            if (reconciled.phase == RdpSafGrantPhase.RETIRED) {
                val updated = records.updated(index, reconciled)
                if (updated != records) store.replace(updated)
                result.success(receipt(reconciled, request.requestId))
                return@mutateGrant updated
            }
            if (reconciled.phase == RdpSafGrantPhase.RELEASE_DISPATCHED) {
                if (reconciled.retirementRequestId != null &&
                    reconciled.retirementRequestId != request.requestId
                ) unavailable()
                result.success(receipt(reconciled, request.requestId))
                return@mutateGrant records.updated(index, reconciled)
            }
            if (reconciled.phase == RdpSafGrantPhase.RETIRE_INTENT) {
                if (reconciled.retirementRequestId != null &&
                    reconciled.retirementRequestId != request.requestId
                ) unavailable()
                val intent = if (reconciled.retirementRequestId == null) {
                    reconciled.copy(retirementRequestId = request.requestId)
                } else reconciled
                val intentRecords = records.updated(index, intent)
                if (intentRecords != records) store.replace(intentRecords)
                val updated = dispatchRelease(intentRecords, index, intent)
                result.success(receipt(updated[index], request.requestId))
                return@mutateGrant updated
            }
            val intent = reconciled.copy(
                phase = RdpSafGrantPhase.RETIRE_INTENT,
                retirementRequestId = request.requestId,
            )
            var updated = records.updated(index, intent)
            store.replace(updated)
            updated = dispatchRelease(updated, index, intent)
            result.success(receipt(updated[index], request.requestId))
            updated
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode !in issuedRequestCodes) return false
        val owned = pending ?: return true
        if (requestCode != owned.requestCode) return true
        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            cancelOwned(owned, "cancelled")
            return true
        }
        val deferred = PendingResult(owned, resultCode, data)
        if (foreground()) processResult(deferred) else pendingResult = deferred
        return true
    }

    fun dispose() {
        if (disposed) return
        disposed = true
        pending?.let { cancelOwned(it, "cancelled") }
        deadline?.let(handler::removeCallbacks)
        deadline = null
        pendingResult = null
    }

    private fun processDeferredIfForeground() {
        if (!foreground()) return
        pendingResult?.let {
            pendingResult = null
            processResult(it)
        }
    }

    private fun processResult(deferred: PendingResult) {
        val owned = pending ?: return
        if (owned !== deferred.pending || owned.generation != generation) return
        val data = deferred.data ?: return cancelOwned(owned, "cancelled")
        val uri = data.data ?: return cancelOwned(owned, "cancelled")
        if (uri.scheme != "content" || uri.toString().length > 4096 ||
            (data.flags and GRANT_FLAG_MASK) != REQUIRED_FLAGS
        ) return cancelOwned(owned, "permission_denied")
        try {
            val records = store.read()
            val index = records.indexOfFirst { it.grantId == owned.grantId }
            if (index < 0 || records[index].phase != RdpSafGrantPhase.SELECT_PENDING ||
                records[index].authority.authorityId != owned.request.authority.authorityId
            ) unavailable()
            if (records.any { other ->
                    other.grantId != owned.grantId && other.uri == uri.toString() &&
                        other.phase in setOf(
                            RdpSafGrantPhase.ACQUIRE_INTENT,
                            RdpSafGrantPhase.RETIRE_INTENT,
                            RdpSafGrantPhase.RELEASE_DISPATCHED,
                        )
                }
            ) {
                store.replace(records.updated(index, records[index].copy(
                    phase = RdpSafGrantPhase.RETIRED,
                    uri = null,
                )))
                unavailable()
            }
            val preexisting = host.persistedFlags(uri) and REQUIRED_ACCESS_FLAGS
            val acquired = REQUIRED_ACCESS_FLAGS and preexisting.inv()
            val intent = records[index].copy(
                phase = RdpSafGrantPhase.ACQUIRE_INTENT,
                uri = uri.toString(),
                preexistingFlags = preexisting,
                acquiredFlags = acquired,
            )
            var updated = records.updated(index, intent)
            store.replace(updated)
            host.take(uri, REQUIRED_ACCESS_FLAGS)
            if ((host.persistedFlags(uri) and REQUIRED_ACCESS_FLAGS) != REQUIRED_ACCESS_FLAGS) {
                permissionDenied()
            }
            val prepared = intent.copy(phase = RdpSafGrantPhase.PREPARED)
            updated = updated.updated(index, prepared)
            store.replace(updated)
            finishPending(owned)
            owned.result.success(receipt(prepared, owned.request.requestId))
            schedulePreparedExpiry(prepared)
        } catch (failure: RdpSafFailure) {
            finishPending(owned)
            error(owned.result, failure.code)
        } catch (_: SecurityException) {
            finishPending(owned)
            error(owned.result, "permission_denied")
        } catch (_: Exception) {
            finishPending(owned)
            error(owned.result, "unavailable")
        }
    }

    private fun mutateGrant(
        request: RdpSafGrantRequest,
        result: MethodChannel.Result,
        block: (List<RdpSafGrantRecord>, Int, RdpSafGrantRecord) -> List<RdpSafGrantRecord>,
    ) {
        try {
            val records = store.read()
            val reused = records.firstOrNull {
                it.activationRequestId == request.requestId || it.retirementRequestId == request.requestId
            }
            if (reused != null && (reused.grantId != request.grantId ||
                    reused.authority.authorityId != request.authority.authorityId ||
                    reused.grantRevision != request.expectedGrantRevision)
            ) invalid()
            val index = records.indexOfFirst { it.grantId == request.grantId }
            if (index < 0) authorityChanged()
            block(records, index, exact(records[index], request))
        } catch (failure: RdpSafFailure) {
            error(result, failure.code)
        } catch (_: Exception) {
            error(result, "unavailable")
        }
    }

    private fun rejectRequestReuse(
        records: List<RdpSafGrantRecord>,
        request: RdpSafGrantRequest,
        activation: Boolean,
    ) {
        records.firstOrNull {
            it.activationRequestId == request.requestId || it.retirementRequestId == request.requestId
        }?.let { owner ->
            val exactActivation = owner.grantId == request.grantId &&
                owner.activationRequestId == request.requestId &&
                owner.authority.authorityId == request.authority.authorityId &&
                owner.grantRevision == request.expectedGrantRevision
            val exactRetirement = owner.grantId == request.grantId &&
                owner.retirementRequestId == request.requestId &&
                owner.authority.authorityId == request.authority.authorityId &&
                owner.grantRevision == request.expectedGrantRevision
            if (activation && !exactActivation || !activation && !exactRetirement) invalid()
        }
    }

    private fun exact(record: RdpSafGrantRecord, request: RdpSafGrantRequest): RdpSafGrantRecord {
        if (record.authority.authorityId != request.authority.authorityId ||
            record.grantRevision != request.expectedGrantRevision
        ) authorityChanged()
        return record
    }

    private fun reconcile(
        record: RdpSafGrantRecord,
        records: List<RdpSafGrantRecord>,
    ): RdpSafGrantRecord {
        val uri = record.uri?.let(Uri::parse)
        return when (record.phase) {
            RdpSafGrantPhase.ACQUIRE_INTENT -> {
                if (uri != null &&
                    (host.persistedFlags(uri) and REQUIRED_ACCESS_FLAGS) == REQUIRED_ACCESS_FLAGS
                ) {
                    record.copy(phase = RdpSafGrantPhase.PREPARED)
                } else record
            }
            RdpSafGrantPhase.RELEASE_DISPATCHED -> {
                if (uri == null || releaseConfirmed(record, uri)) {
                    record.copy(
                        phase = RdpSafGrantPhase.RETIRED,
                        uri = null,
                        acquiredFlags = 0,
                    )
                } else record
            }
            RdpSafGrantPhase.PREPARED,
            RdpSafGrantPhase.ACTIVE,
            -> {
                val currentFlags = (uri?.let(host::persistedFlags) ?: 0) and REQUIRED_ACCESS_FLAGS
                if (currentFlags == REQUIRED_ACCESS_FLAGS) {
                    record
                } else {
                    val remainingOwned = record.acquiredFlags and currentFlags
                    if (remainingOwned == 0) {
                        record.copy(
                            phase = RdpSafGrantPhase.RETIRED,
                            uri = null,
                            acquiredFlags = 0,
                        )
                    } else {
                        record.copy(
                            phase = RdpSafGrantPhase.RETIRE_INTENT,
                            acquiredFlags = remainingOwned,
                        )
                    }
                }
            }
            else -> record
        }
    }

    private fun expire(
        records: List<RdpSafGrantRecord>,
        index: Int,
        record: RdpSafGrantRecord,
    ): RdpSafGrantRecord {
        val intent = record.copy(
            phase = RdpSafGrantPhase.RETIRE_INTENT,
            retirementRequestId = record.selectRequestId,
        )
        var updated = records.updated(index, intent)
        store.replace(updated)
        updated = dispatchRelease(updated, index, intent)
        return updated[index]
    }

    private fun dispatchRelease(
        records: List<RdpSafGrantRecord>,
        index: Int,
        record: RdpSafGrantRecord,
    ): List<RdpSafGrantRecord> {
        val uriString = record.uri
        if (uriString == null) {
            return records.updated(index, record.copy(
                phase = RdpSafGrantPhase.RETIRED,
                acquiredFlags = 0,
            )).also(store::replace)
        }
        val uri = Uri.parse(uriString)
        val survivors = records.withIndex().filter { (otherIndex, other) ->
            otherIndex != index && other.uri == uriString && other.phase != RdpSafGrantPhase.RETIRED
        }
        if (record.acquiredFlags != 0 && survivors.isNotEmpty()) {
            val successor = survivors.minWith(
                compareBy<IndexedValue<RdpSafGrantRecord>> { it.value.grantRevision }
                    .thenBy { it.value.grantId },
            )
            var transferred = records.updated(index, record.copy(
                phase = RdpSafGrantPhase.RETIRED,
                uri = null,
                acquiredFlags = 0,
            ))
            transferred = transferred.updated(successor.index, successor.value.copy(
                acquiredFlags = successor.value.acquiredFlags or record.acquiredFlags,
            ))
            store.replace(transferred)
            return transferred
        }
        val releaseFlags = record.acquiredFlags
        if (releaseFlags == 0) {
            return records.updated(index, record.copy(
                phase = RdpSafGrantPhase.RETIRED,
                uri = null,
                acquiredFlags = 0,
            )).also(store::replace)
        }
        if ((host.persistedFlags(uri) and releaseFlags) == 0) {
            return records.updated(index, record.copy(
                phase = RdpSafGrantPhase.RETIRED,
                uri = null,
                acquiredFlags = 0,
            )).also(store::replace)
        }
        val dispatched = record.copy(phase = RdpSafGrantPhase.RELEASE_DISPATCHED)
        val dispatchedRecords = records.updated(index, dispatched)
        store.replace(dispatchedRecords)
        try {
            host.release(uri, releaseFlags)
        } catch (_: Exception) {
            return dispatchedRecords
        }
        if (!releaseConfirmed(dispatched, uri)) return dispatchedRecords
        return dispatchedRecords.updated(index, dispatched.copy(
            phase = RdpSafGrantPhase.RETIRED,
            uri = null,
            acquiredFlags = 0,
        )).also(store::replace)
    }

    private fun releaseConfirmed(
        record: RdpSafGrantRecord,
        uri: Uri,
    ): Boolean {
        return (host.persistedFlags(uri) and record.acquiredFlags) == 0
    }

    private fun requirePermission(record: RdpSafGrantRecord) {
        val uri = record.uri?.let(Uri::parse) ?: unavailable()
        if ((host.persistedFlags(uri) and REQUIRED_ACCESS_FLAGS) != REQUIRED_ACCESS_FLAGS) {
            permissionDenied()
        }
    }

    private fun cancelOwned(owned: Pending, code: String) {
        if (pending !== owned || owned.generation != generation) return
        try {
            val records = store.read()
            val index = records.indexOfFirst { it.grantId == owned.grantId }
            if (index >= 0 && records[index].phase == RdpSafGrantPhase.SELECT_PENDING) {
                store.replace(records.updated(index, records[index].copy(
                    phase = RdpSafGrantPhase.RETIRED,
                    uri = null,
                )))
            }
        } catch (_: Exception) {
            finishPending(owned)
            error(owned.result, "unavailable")
            return
        }
        finishPending(owned)
        error(owned.result, code)
    }

    private fun finishPending(owned: Pending) {
        if (pending !== owned) return
        pending = null
        pendingResult = null
        deadline?.let(handler::removeCallbacks)
        deadline = null
    }

    private fun schedulePreparedExpiry(record: RdpSafGrantRecord) {
        val delay = (record.expiresAtMs - now()).coerceAtLeast(0)
        handler.postDelayed({
            if (disposed) return@postDelayed
            try {
                val records = store.read()
                val index = records.indexOfFirst { it.grantId == record.grantId }
                if (index >= 0 && records[index].phase == RdpSafGrantPhase.PREPARED &&
                    records[index].grantRevision == record.grantRevision && records[index].expiresAtMs <= now()
                ) expire(records, index, records[index])
            } catch (_: Exception) {
                // Durable transitional state remains unknown for explicit observation.
            }
        }, delay)
    }

    private fun pruned(records: List<RdpSafGrantRecord>, currentNow: Long): List<RdpSafGrantRecord> {
        val newestByAuthority = records.groupBy { it.authority.authorityId }
            .mapValues { (_, values) -> values.maxByOrNull { it.grantRevision }?.grantId }
        return records.filter { record ->
            record.phase != RdpSafGrantPhase.RETIRED ||
                newestByAuthority[record.authority.authorityId] == record.grantId ||
                currentNow - record.expiresAtMs <= REPLAY_RETENTION_MS
        }
    }

    private fun receipt(record: RdpSafGrantRecord, requestId: String) = RdpSafContract.receipt(
        requestId,
        record.authority.authorityId,
        record.grantId,
        record.grantRevision,
        record.publicState,
    )

    private fun foreground() = !disposed && resumed && focused

    private fun allocateRequestCode(): Int {
        while (nextRequestCode <= REQUEST_CODE_LAST) {
            val candidate = nextRequestCode++
            if (issuedRequestCodes.add(candidate)) return candidate
        }
        unavailable()
    }

    private fun <T> parse(result: MethodChannel.Result, block: () -> T): T? = try {
        block()
    } catch (failure: RdpSafFailure) {
        error(result, failure.code)
        null
    } catch (_: Exception) {
        error(result, "invalid_request")
        null
    }

    private fun error(result: MethodChannel.Result, code: String) {
        result.error(code, "RDP file transfer grant unavailable", null)
    }

    private fun invalid(): Nothing = throw RdpSafFailure("invalid_request")
    private fun unavailable(): Nothing = throw RdpSafFailure("unavailable")
    private fun permissionDenied(): Nothing = throw RdpSafFailure("permission_denied")
    private fun authorityChanged(): Nothing = throw RdpSafFailure("authority_changed")
    private fun <T> List<T>.updated(index: Int, value: T): List<T> = toMutableList().apply { this[index] = value }

    companion object {
        const val REQUEST_CODE_BASE = 41061
        const val REQUEST_CODE_LAST = 45156
        const val REQUIRED_ACCESS_FLAGS =
            Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        const val REQUIRED_FLAGS = REQUIRED_ACCESS_FLAGS or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
        private const val GRANT_FLAG_MASK = REQUIRED_FLAGS or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION
        private const val PICKER_DEADLINE_MS = 30_000L
        private const val REPLAY_RETENTION_MS = 24L * 60 * 60 * 1000
    }
}
