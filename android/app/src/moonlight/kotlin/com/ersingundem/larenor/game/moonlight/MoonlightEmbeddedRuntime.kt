package com.ersingundem.larenor.game.moonlight

import android.app.Activity
import android.app.AlertDialog
import android.content.Context
import android.content.Intent
import android.preference.PreferenceManager
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.AtomicFile
import com.limelight.Game
import com.limelight.binding.crypto.AndroidCryptoProvider
import com.limelight.computers.ComputerDatabaseManager
import com.limelight.computers.IdentityManager
import com.limelight.nvstream.ConnectionContext
import com.limelight.nvstream.StreamConfiguration
import com.limelight.nvstream.http.ComputerDetails
import com.limelight.nvstream.http.NvHTTP
import com.limelight.nvstream.http.PairingManager
import com.limelight.nvstream.jni.MoonBridge
import com.limelight.nvstream.wol.WakeOnLanSender
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest
import java.security.SecureRandom
import java.nio.file.Files
import java.nio.charset.StandardCharsets
import javax.crypto.KeyGenerator
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

internal data class ProbedCandidate(
    val public: MoonlightCandidate,
    val endpoint: MoonlightDiscoveredEndpoint,
    val details: ComputerDetails,
    val serverInfo: String,
)

internal fun interface MoonlightPinPresenter {
    fun show(pin: String, cancel: () -> Unit): AutoCloseable
}

internal class MoonlightAndroidPinPresenter(private val activity: Activity) : MoonlightPinPresenter {
    override fun show(pin: String, cancel: () -> Unit): AutoCloseable {
        check(Looper.myLooper() == Looper.getMainLooper())
        val dialog = AlertDialog.Builder(activity)
            .setTitle("Moonlight pairing")
            .setMessage("Enter this PIN in the Sunshine host: $pin")
            .setNegativeButton(android.R.string.cancel) { _, _ -> cancel() }
            .setCancelable(false)
            .create()
        dialog.show()
        return AutoCloseable { if (dialog.isShowing) dialog.dismiss() }
    }
}

/** Owns every provider request belonging to one exact pairing attempt. */
internal class MoonlightPairingFlight(
    private val deadlineElapsedMillis: Long = Long.MAX_VALUE,
    private val elapsedNowMillis: () -> Long = SystemClock::elapsedRealtime,
) {
    private val lock = Any()
    private val clients = linkedSetOf<NvHTTP>()
    private var terminal = false

    fun attach(client: NvHTTP) {
        val cancel = synchronized(lock) {
            if (terminal || elapsedNowMillis() >= deadlineElapsedMillis) {
                terminal = true
                true
            } else {
                clients += client
                false
            }
        }
        if (cancel) {
            client.cancelPendingRequests()
            throw MoonlightRuntimeFailure("cancelled")
        }
    }

    fun detach(client: NvHTTP) = synchronized(lock) { clients -= client }

    fun requireActive() {
        val expired = synchronized(lock) {
            !terminal && elapsedNowMillis() >= deadlineElapsedMillis
        }
        if (expired) cancel()
        synchronized(lock) {
            if (terminal) throw MoonlightRuntimeFailure("cancelled")
        }
    }

    fun <T> withActive(block: () -> T): T = synchronized(lock) {
        if (terminal || elapsedNowMillis() >= deadlineElapsedMillis) {
            terminal = true
            throw MoonlightRuntimeFailure("cancelled")
        }
        block()
    }

    fun cancel() {
        val active = synchronized(lock) {
            if (terminal) return
            terminal = true
            clients.toList()
        }
        active.forEach(NvHTTP::cancelPendingRequests)
    }

    fun finish() = synchronized(lock) {
        terminal = true
        clients.clear()
    }
}

internal fun pairingDeadlineMillis(expiresAtEpochSeconds: Double, nowMillis: Long): Long =
    minOf(
        MoonlightEmbeddedRuntime.MAX_PAIRING_DURATION_MILLIS,
        maxOf(1L, (expiresAtEpochSeconds * 1_000.0).toLong() - nowMillis),
    )

/**
 * Native-only upstream boundary. Addresses, raw IDs, PINs and certificates do
 * not appear in any public result from this class.
 */
class MoonlightEmbeddedRuntime internal constructor(
    private val activity: Activity,
    private val discovery: MoonlightDiscovery = MoonlightMdnsDiscovery(activity.applicationContext),
    private val pinPresenter: MoonlightPinPresenter = MoonlightAndroidPinPresenter(activity),
    private val nowMillis: () -> Long = System::currentTimeMillis,
    private val retirementStoreFactory: (File) -> MoonlightAuthorityRetirementPersistence =
        { MoonlightAuthorityRetirementStore(it) },
    private val discoveryBeforeCommit: (() -> Unit)? = null,
    private val discoveryBeforeDelivery: (() -> Unit)? = null,
    private val localRetirementAfterRegistrationFence: (() -> Unit)? = null,
    private val localRetirementBeforeDispatch: (() -> Unit)? = null,
    private val localRetirementBeforeSubmission: (() -> Unit)? = null,
) : AutoCloseable {
    private val main = Handler(Looper.getMainLooper())
    private val executor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "larenor-moonlight-runtime").apply { isDaemon = true }
    }
    private val random = SecureRandom()
    private val lock = Any()
    private var generation = 0L
    private var authority: MoonlightAuthority? = null
    private var bindingId: String? = null
    private var bindingRevision = 0L
    private val streamDispatchTraces = MoonlightStreamDispatchTraceStore()
    private var scoped: MoonlightScopedContext? = null
    private var journal: MoonlightOperationJournal? = null
    private var registrations: MoonlightRegistrationStore? = null
    private var policyStore: MoonlightPolicyStore? = null
    private var boundSession: MoonlightBoundSession? = null
    private var activeLeaseToken: String? = null
    private var pairingPrompt: PairingPromptOwner? = null
    private var pairingFlight: MoonlightPairingFlight? = null
    private var pairingDialog: AutoCloseable? = null
    private var pendingPairings = linkedMapOf<String, PendingPairing>()
    private val pendingRetirements = linkedMapOf<String, MoonlightAuthorityRetirementReceipt>()
    private val retiringHosts = mutableSetOf<String>()
    private val candidates = linkedMapOf<String, ProbedCandidate>()
    private var closed = false

    fun bindAuthority(next: MoonlightAuthority): Pair<String, Long> {
        var staleFlight: MoonlightPairingFlight? = null
        var stalePrompt: AutoCloseable? = null
        val binding = synchronized(lock) {
            ensureOpen()
            if (retiringHosts.isNotEmpty()) throw MoonlightRuntimeFailure("authority_changed")
            if (authority?.fingerprint == next.fingerprint) {
                return@synchronized exactBinding()
            }
            if (pendingRetirements.values.any { it.authorityFingerprint == next.fingerprint }) {
                throw MoonlightRuntimeFailure("authority_changed")
            }
            val context = MoonlightScopedContext.create(activity.applicationContext, next.scope)
            if (retirementStoreFactory(
                    File(context.noBackupFilesDir, "authority-retirements.json"),
                ).containsAuthority(next.fingerprint)
            ) throw MoonlightRuntimeFailure("authority_changed")
            authority?.let { previous ->
                bindingId?.let { MoonlightForegroundLeaseRegistry.retire(previous.authorityId, previous.epoch) }
            }
            staleFlight = pairingFlight.also { pairingFlight = null }
            pairingPrompt = null
            stalePrompt = pairingDialog.also { pairingDialog = null }
            discardPendingPairingsLocked()
            generation += 1
            authority = next
            scoped = context
            journal = MoonlightOperationJournal(File(context.noBackupFilesDir, "journal"))
            registrations = MoonlightRegistrationStore(File(context.noBackupFilesDir, "registrations.json"))
            policyStore = MoonlightPolicyStore(File(context.noBackupFilesDir, "policy.json"), next.scope)
            boundSession = null
            activeLeaseToken = null
            candidates.clear()
            bindingId = randomIdentity()
            bindingRevision = if (bindingRevision >= MAX_JS_REVISION) 1 else bindingRevision + 1
            exactBinding()
        }
        staleFlight?.cancel()
        stalePrompt?.let { main.post { runCatching { it.close() } } }
        return binding
    }

    fun discover(
        expected: MoonlightAuthority,
        requestId: String,
        timeoutMillis: Long,
        callback: (Result<List<MoonlightCandidate>>) -> Unit,
    ) {
        requireIdentity(requestId, "request_id")
        val captured = capture(expected)
        discovery.discover(timeoutMillis) { result ->
            val endpoints = result.getOrElse { return@discover callback(Result.failure(publicFailure(it))) }
            executor.execute {
                val probes = endpoints.take(MAX_CANDIDATES).mapNotNull { endpoint ->
                    runCatching { probe(captured, endpoint) }.getOrNull()
                }
                try {
                    discoveryBeforeCommit?.invoke()
                    synchronized(lock) {
                        currentLocked(captured)
                        candidates.clear()
                        probes.forEach { candidates[it.public.candidateId] = it }
                    }
                    discoveryBeforeDelivery?.invoke()
                    main.post {
                        runCatching { current(captured) }.fold(
                            onSuccess = { callback(Result.success(probes.map { it.public })) },
                            onFailure = { callback(Result.failure(publicFailure(it))) },
                        )
                    }
                } catch (failure: Throwable) {
                    main.post { callback(Result.failure(publicFailure(failure))) }
                }
            }
        }
    }

    fun pair(
        expected: MoonlightAuthority,
        authorization: MoonlightPairAuthorization,
        candidateId: String,
        expectedCandidateRevision: Long,
        callback: (Result<MoonlightPairReceipt>) -> Unit,
    ) {
        requireIdentity(candidateId, "candidate")
        requireRevision(expectedCandidateRevision, "candidate_revision")
        if (authorization.expiresAtEpochSeconds * 1_000.0 <= nowMillis().toDouble()) {
            callback(Result.failure(MoonlightRuntimeFailure("authority_changed")))
            return
        }
        val captured = capture(expected)
        val operationJournal = captured.journal
        val candidate = synchronized(lock) {
            currentLocked(captured)
            candidates[candidateId]?.takeIf { it.public.candidateRevision == expectedCandidateRevision }
                ?: throw MoonlightRuntimeFailure("stale_candidate")
        }
        val fingerprint = sha256(listOf(
            authorization.pairingId, authorization.expectedPairingRevision,
            authorization.grantDigest, candidateId, expectedCandidateRevision,
        ).joinToString("\u0000").toByteArray()).hex()
        val record = operationJournal.reserve(MoonlightOperationRecord(
            requestId = authorization.requestId,
            operationId = authorization.pairingId,
            kind = "pair",
            subject = candidateId,
            fingerprint = fingerprint,
            authorityFingerprint = expected.fingerprint,
            state = MoonlightOperationState.PREPARED,
            readbackRevision = 0,
            expiresAtEpochMillis = (authorization.expiresAtEpochSeconds * 1_000.0).toLong(),
        ))
        if (record.state != MoonlightOperationState.PREPARED) {
            callback(Result.success(pairReadback(record)))
            return
        }
        val pin = PairingManager.generatePinString()
        val deadlineMillis = pairingDeadlineMillis(authorization.expiresAtEpochSeconds, nowMillis())
        val deadlineElapsedMillis = SystemClock.elapsedRealtime() + deadlineMillis
        val flight = MoonlightPairingFlight(deadlineElapsedMillis)
        synchronized(lock) {
            if (pairingPrompt != null) throw MoonlightRuntimeFailure("busy")
            pairingPrompt = PairingPromptOwner(
                expected.fingerprint, authorization.pairingId, authorization.expectedPairingRevision,
            )
            pairingFlight = flight
        }
        val dialog = try {
            pinPresenter.show(pin, flight::cancel)
        } catch (failure: Throwable) {
            synchronized(lock) {
                if (pairingFlight === flight) {
                    pairingFlight = null
                    pairingPrompt = null
                }
            }
            flight.cancel()
            throw failure
        }
        val ownsPrompt = synchronized(lock) {
            if (pairingFlight === flight && pairingPrompt?.pairingId == authorization.pairingId) {
                pairingDialog = dialog
                true
            } else {
                false
            }
        }
        if (!ownsPrompt) {
            flight.cancel()
            runCatching { dialog.close() }
            throw MoonlightRuntimeFailure("authority_changed")
        }
        val deadline = Runnable { flight.cancel() }
        main.postDelayed(deadline, deadlineMillis)
        try {
            operationJournal.transition(
                authorization.requestId, MoonlightOperationState.PREPARED,
                MoonlightOperationState.DISPATCHING, 0,
            )
            executor.execute {
                val receipt = try {
                    current(captured)
                    flight.requireActive()
                    pairBlocking(captured, candidate, authorization.requestId, pin, flight)
                } catch (_: Throwable) {
                    val revision = publicRevision(authorization.requestId, "unknown", nowMillis().toString())
                    val unknown = MoonlightPairReceipt(authorization.requestId, "unknown", revision)
                    operationJournal.transition(
                        authorization.requestId, MoonlightOperationState.DISPATCHING,
                        MoonlightOperationState.UNKNOWN, revision, pairReceiptJson(unknown),
                    )
                    unknown
                } finally {
                    flight.finish()
                    main.removeCallbacks(deadline)
                }
                main.post {
                    runCatching { dialog.close() }
                    synchronized(lock) {
                        if (pairingDialog === dialog) pairingDialog = null
                        if (pairingFlight === flight) {
                            pairingFlight = null
                            pairingPrompt = null
                        }
                    }
                    runCatching { current(captured) }.fold(
                        onSuccess = { callback(Result.success(receipt)) },
                        onFailure = { callback(Result.failure(publicFailure(it))) },
                    )
                }
            }
        } catch (failure: Throwable) {
            main.removeCallbacks(deadline)
            flight.cancel()
            runCatching { dialog.close() }
            synchronized(lock) {
                if (pairingDialog === dialog) pairingDialog = null
                if (pairingFlight === flight) {
                    pairingFlight = null
                    pairingPrompt = null
                }
            }
            throw failure
        }
    }

    fun configurePolicy(
        expected: MoonlightAuthority,
        expectedRevision: Long,
        requested: MoonlightStreamPolicy,
    ): MoonlightStreamPolicy {
        current(capture(expected))
        if (requested.requirePin) requirePinSatisfied(expected)
        return requirePolicyStore().configure(expectedRevision, requested).also { current(capture(expected)) }
    }

    fun sessionCapabilities(
        expected: MoonlightAuthority,
        hostId: String,
        hostRevision: Long,
        pairingRevision: Long,
        catalogRevision: Long,
        appId: String,
        appRevision: Long,
    ): MoonlightSessionCapabilities {
        val captured = capture(expected)
        val (pairing) = requireRegistrations().resolve(
            hostId, hostRevision, pairingRevision, catalogRevision, appId, appRevision,
        )
        @Suppress("DEPRECATION")
        val activeDisplay = activity.windowManager.defaultDisplay
        val result = MoonlightSessionCapabilityObserver(requireScoped(), activeDisplay)
            .observe(pairing, requirePolicyStore().current(), expected.pinConfigured && expected.pinUnlocked)
        current(captured)
        return result
    }

    fun commitRegistration(expected: MoonlightAuthority, registration: MoonlightCoreRegistration) {
        val captured = capture(expected)
        synchronized(lock) {
            currentLocked(captured)
            ensureHostUsableLocked(captured, registration.hostId)
            requireRegistrations().saveRegistration(registration)
            pendingPairings.remove(registration.nativeReceiptId)
        }
    }

    fun readCatalog(
        expected: MoonlightAuthority,
        authorization: MoonlightCatalogAuthorization,
        hostId: String,
        hostRevision: Long,
        pairingRevision: Long,
        callback: (Result<MoonlightCatalogReceipt>) -> Unit,
    ) {
        if (authorization.expiresAtEpochSeconds * 1_000.0 <= nowMillis().toDouble()) {
            callback(Result.failure(MoonlightRuntimeFailure("authority_changed")))
            return
        }
        val captured = capture(expected)
        ensureHostUsable(captured, hostId)
        val operationJournal = captured.journal
        val registration = captured.registrations.registration(hostId)
            ?: throw MoonlightRuntimeFailure("stale_pairing")
        if (registration.hostRevision != hostRevision || registration.pairingRevision != pairingRevision ||
            registration.catalogRevision != authorization.expectedCatalogRevision
        ) throw MoonlightRuntimeFailure("stale_pairing")
        val pairing = captured.registrations.pairing(registration.nativeReceiptId)
            ?: throw MoonlightRuntimeFailure("invalid_receipt")
        val fingerprint = sha256(listOf(
            authorization.catalogObservationId, authorization.expectedObservationRevision,
            authorization.expectedCatalogRevision, authorization.grantDigest,
            hostId, hostRevision, pairingRevision,
        ).joinToString("\u0000").toByteArray()).hex()
        val record = operationJournal.reserve(MoonlightOperationRecord(
            requestId = authorization.requestId,
            operationId = authorization.catalogObservationId,
            kind = "catalog",
            subject = hostId,
            fingerprint = fingerprint,
            authorityFingerprint = expected.fingerprint,
            state = MoonlightOperationState.PREPARED,
            readbackRevision = authorization.expectedObservationRevision,
            expiresAtEpochMillis = (authorization.expiresAtEpochSeconds * 1_000.0).toLong(),
        ))
        if (record.state != MoonlightOperationState.PREPARED) {
            callback(Result.success(catalogReadback(record, authorization.catalogObservationId)))
            return
        }
        operationJournal.transition(
            authorization.requestId, MoonlightOperationState.PREPARED,
            MoonlightOperationState.DISPATCHING, authorization.expectedObservationRevision,
        )
        executor.execute {
            val receipt = try {
                current(captured)
                refreshCatalogBlocking(captured, pairing, authorization)
            } catch (_: Throwable) {
                val revision = publicRevision(authorization.requestId, "catalog-unknown", nowMillis().toString())
                val unknown = MoonlightCatalogReceipt(
                    authorization.requestId, authorization.catalogObservationId, "unknown", revision,
                )
                operationJournal.transition(
                    authorization.requestId, MoonlightOperationState.DISPATCHING,
                    MoonlightOperationState.UNKNOWN, revision, catalogReceiptJson(unknown),
                )
                unknown
            }
            main.post {
                runCatching { current(captured) }.fold(
                    onSuccess = { callback(Result.success(receipt)) },
                    onFailure = { callback(Result.failure(publicFailure(it))) },
                )
            }
        }
    }

    fun resolveBinding(
        expected: MoonlightAuthority,
        hostId: String,
        hostRevision: Long,
        pairingRevision: Long,
        catalogRevision: Long,
        appId: String,
        appRevision: Long,
    ): Long {
        val captured = capture(expected)
        ensureHostUsable(captured, hostId)
        requireRegistrations().resolve(
            hostId, hostRevision, pairingRevision, catalogRevision, appId, appRevision,
        )
        val registration = requireRegistrations().registration(hostId)
            ?: throw MoonlightRuntimeFailure("stale_pairing")
        current(captured)
        return registration.registrationRevision
    }

    fun resolveHostBinding(
        expected: MoonlightAuthority,
        hostId: String,
        hostRevision: Long,
        pairingRevision: Long,
        catalogRevision: Long,
    ): Long {
        val captured = capture(expected)
        ensureHostUsable(captured, hostId)
        val registration = requireRegistrations().registration(hostId)
            ?: throw MoonlightRuntimeFailure("stale_pairing")
        if (registration.hostRevision != hostRevision || registration.pairingRevision != pairingRevision) {
            throw MoonlightRuntimeFailure("stale_pairing")
        }
        if (registration.catalogRevision != catalogRevision) throw MoonlightRuntimeFailure("stale_candidate")
        current(captured)
        return registration.registrationRevision
    }

    fun revoke(
        expected: MoonlightAuthority,
        requestId: String,
        revocationId: String,
        hostId: String,
        expectedHostRevision: Long,
        expectedPairingRevision: Long,
        expectedCatalogRevision: Long,
        callback: (Result<MoonlightRevokeReceipt>) -> Unit,
    ) {
        requireIdentity(requestId, "request_id")
        requireIdentity(revocationId, "candidate")
        val captured = capture(expected)
        val fingerprint = sha256(listOf(
            hostId, expectedHostRevision, expectedPairingRevision, expectedCatalogRevision,
        ).joinToString("\u0000").toByteArray()).hex()
        captured.journal.read(requestId)?.let { existing ->
            if (existing.kind != "revoke" || existing.operationId != revocationId ||
                existing.subject != hostId || existing.fingerprint != fingerprint ||
                existing.authorityFingerprint != expected.fingerprint
            ) throw MoonlightRuntimeFailure("invalid_receipt")
            callback(Result.success(revokeReadback(existing)))
            return
        }
        val registration = captured.registrations.registration(hostId)
            ?: throw MoonlightRuntimeFailure("stale_pairing")
        if (registration.hostRevision != expectedHostRevision ||
            registration.pairingRevision != expectedPairingRevision ||
            registration.catalogRevision != expectedCatalogRevision
        ) throw MoonlightRuntimeFailure("stale_pairing")
        val pairing = captured.registrations.pairing(registration.nativeReceiptId)
            ?: throw MoonlightRuntimeFailure("invalid_receipt")
        synchronized(lock) {
            currentLocked(captured)
            if (boundSession != null || activeLeaseToken != null ||
                pendingPairings.containsKey(pairing.receiptId)
            ) throw MoonlightRuntimeFailure("authority_changed")
            if (!retiringHosts.add(hostId)) throw MoonlightRuntimeFailure("busy")
        }
        val record = try {
            captured.journal.reserve(MoonlightOperationRecord(
                requestId, revocationId, "revoke", hostId, fingerprint, expected.fingerprint,
                MoonlightOperationState.PREPARED, 0, 0,
            ))
        } catch (failure: Throwable) {
            synchronized(lock) { retiringHosts.remove(hostId) }
            throw failure
        }
        if (record.state != MoonlightOperationState.PREPARED) {
            synchronized(lock) { retiringHosts.remove(hostId) }
            callback(Result.success(revokeReadback(record)))
            return
        }
        try {
            localRetirementBeforeDispatch?.invoke()
            captured.journal.transition(
                requestId, MoonlightOperationState.PREPARED, MoonlightOperationState.DISPATCHING, 0,
            )
            localRetirementBeforeSubmission?.invoke()
            executor.execute {
                val receipt = try {
                    current(captured)
                    revokeBlocking(captured, pairing, registration, requestId)
                } catch (_: Throwable) {
                    val unknown = MoonlightRevokeReceipt(requestId, "unknown", null)
                    captured.journal.transition(
                        requestId, MoonlightOperationState.DISPATCHING, MoonlightOperationState.UNKNOWN,
                        0, revokeReceiptJson(unknown),
                    )
                    unknown
                } finally {
                    synchronized(lock) { retiringHosts.remove(hostId) }
                }
                main.post {
                    runCatching { current(captured) }.fold(
                        onSuccess = { callback(Result.success(receipt)) },
                        onFailure = { callback(Result.failure(publicFailure(it))) },
                    )
                }
            }
        } catch (failure: Throwable) {
            synchronized(lock) { retiringHosts.remove(hostId) }
            throw failure
        }
    }

    fun bindSession(expected: MoonlightAuthority, session: MoonlightBoundSession) {
        if (session.expiresAtEpochSeconds * 1_000.0 <= nowMillis().toDouble()) {
            throw MoonlightRuntimeFailure("authority_changed")
        }
        val captured = capture(expected)
        requirePolicyPin(expected)
        val capabilities = sessionCapabilities(
            expected, session.hostId, session.hostRevision, session.pairingRevision,
            session.catalogRevision, session.appId, session.appRevision,
        )
        if (capabilities.availability != "available" ||
            capabilities.qualityOptions.none { it.exactlyMatches(session.selectedQuality) }
        ) throw MoonlightRuntimeFailure("stale_candidate")
        current(captured)
        synchronized(lock) {
            current(captured)
            ensureHostUsableLocked(captured, session.hostId)
            boundSession = session
        }
    }

    fun executeCommand(
        expected: MoonlightAuthority,
        requestId: String,
        sessionId: String,
        expectedSessionRevision: Long,
        commandId: String,
        intent: String,
        dispatchGrant: String,
        callback: (Result<MoonlightCommandReceipt>) -> Unit,
    ) {
        requireIdentity(requestId, "request_id")
        requireIdentity(sessionId, "session_id")
        requireRevision(expectedSessionRevision, "revision")
        requireIdentity(commandId, "candidate")
        requireIdentity(dispatchGrant, "candidate")
        if (intent !in setOf("wake", "launch", "stream", "stop")) {
            throw MoonlightRuntimeFailure("invalid_receipt")
        }
        val captured = capture(expected)
        requirePolicyPin(expected)
        val session = synchronized(lock) {
            boundSession?.takeIf { it.sessionId == sessionId && it.sessionRevision == expectedSessionRevision }
        } ?: throw MoonlightRuntimeFailure("authority_changed")
        if (session.expiresAtEpochSeconds * 1_000.0 <= nowMillis().toDouble()) {
            throw MoonlightRuntimeFailure("authority_changed")
        }
        val fingerprint = sha256(listOf(
            commandId, sessionId, expectedSessionRevision.toString(), intent,
            sha256(dispatchGrant.toByteArray(Charsets.UTF_8)).hex(), session.selectedQuality.fingerprint,
        ).joinToString("\u0000").toByteArray(Charsets.UTF_8)).hex()
        val record = requireJournal().reserve(MoonlightOperationRecord(
            requestId, commandId, "command", sessionId, fingerprint, expected.fingerprint,
            MoonlightOperationState.PREPARED, 0,
            (session.expiresAtEpochSeconds * 1_000.0).toLong(),
        ))
        if (record.state != MoonlightOperationState.PREPARED) {
            callback(Result.success(commandReadback(record, requestId)))
            return
        }
        requireJournal().transition(
            requestId, MoonlightOperationState.PREPARED, MoonlightOperationState.DISPATCHING, 0,
        )
        when (intent) {
            "wake", "launch" -> dispatchProviderCommand(
                captured, session, requestId, commandId, intent, callback,
            )
            "stream" -> dispatchStream(
                captured, expected, session, requestId, commandId, fingerprint, callback,
            )
            else -> dispatchStop(captured, session, requestId, commandId, callback)
        }
    }

    fun executeSafetyStop(
        requestedAuthority: MoonlightAuthority,
        expectedBindingId: String,
        expectedBindingRevision: Long,
        requestId: String,
        sessionId: String,
        expectedSessionRevision: Long,
        commandId: String,
        dispatchGrant: String,
        callback: (Result<MoonlightCommandReceipt>) -> Unit,
    ) {
        requireIdentity(expectedBindingId, "candidate")
        requireRevision(expectedBindingRevision, "revision")
        requireIdentity(requestId, "request_id")
        requireIdentity(sessionId, "session_id")
        requireRevision(expectedSessionRevision, "revision")
        requireIdentity(commandId, "candidate")
        requireIdentity(dispatchGrant, "candidate")
        val (boundAuthority, session, token, stopJournal) = synchronized(lock) {
            ensureOpen()
            val currentAuthority = authority ?: throw MoonlightRuntimeFailure("authority_changed")
            if (!currentAuthority.sameSafetyOwner(requestedAuthority)) {
                throw MoonlightRuntimeFailure("authority_changed")
            }
            val binding = exactBinding()
            if (binding.first != expectedBindingId || binding.second != expectedBindingRevision) {
                throw MoonlightRuntimeFailure("authority_changed")
            }
            val currentSession = boundSession?.takeIf {
                it.sessionId == sessionId && it.sessionRevision == expectedSessionRevision
            } ?: throw MoonlightRuntimeFailure("authority_changed")
            val leaseToken = activeLeaseToken ?: throw MoonlightRuntimeFailure("authority_changed")
            if (MoonlightForegroundLeaseRegistry.safetyStopSnapshot(
                    currentAuthority.authorityId, currentAuthority.epoch,
                    sessionId, expectedSessionRevision,
                )?.token != leaseToken
            ) throw MoonlightRuntimeFailure("authority_changed")
            SafetyStopContext(
                currentAuthority, currentSession, leaseToken,
                journal ?: throw MoonlightRuntimeFailure("authority_changed"),
            )
        }
        val fingerprint = sha256(listOf(
            commandId, sessionId, expectedSessionRevision.toString(), "stop",
            sha256(dispatchGrant.toByteArray(Charsets.UTF_8)).hex(), session.selectedQuality.fingerprint,
        ).joinToString("\u0000").toByteArray(Charsets.UTF_8)).hex()
        val expiry = maxOf(
            (session.expiresAtEpochSeconds * 1_000.0).toLong(),
            nowMillis() + COMMAND_TIMEOUT_MS,
        )
        val record = stopJournal.reserve(MoonlightOperationRecord(
            requestId, commandId, "command", sessionId, fingerprint, boundAuthority.fingerprint,
            MoonlightOperationState.PREPARED, 0, expiry,
        ))
        if (record.state != MoonlightOperationState.PREPARED) {
            callback(Result.success(commandReadback(record, requestId)))
            return
        }
        stopJournal.transition(
            requestId, MoonlightOperationState.PREPARED, MoonlightOperationState.DISPATCHING, 0,
        )
        dispatchSafetyStop(stopJournal, token, session, requestId, commandId, callback)
    }

    fun reconcile(
        expected: MoonlightAuthority,
        reconcileRequestId: String,
        operationKind: String,
        operationId: String,
    ): Any? {
        requireIdentity(reconcileRequestId, "request_id")
        requireIdentity(operationId, "candidate")
        val captured = capture(expected)
        val journalKind = if (operationKind == "command") "command" else operationKind
        if (journalKind !in setOf("pair", "catalog", "command", "revoke")) {
            throw MoonlightRuntimeFailure("invalid_receipt")
        }
        val record = requireJournal().find(journalKind, operationId) ?: return null
        if (record.authorityFingerprint != expected.fingerprint) {
            throw MoonlightRuntimeFailure("authority_changed")
        }
        current(captured)
        if (!record.state.terminal) return null
        return when (operationKind) {
            "pair" -> pairReadback(record).copy(requestId = reconcileRequestId)
            "catalog" -> catalogReadback(record, operationId).copy(requestId = reconcileRequestId)
            "command" -> commandReadback(record, reconcileRequestId)
            "revoke" -> revokeReadback(record).copy(requestId = reconcileRequestId)
            else -> throw MoonlightRuntimeFailure("invalid_receipt")
        }
    }

    fun prepareStream(
        expected: MoonlightAuthority,
        sessionId: String,
        epoch: Long,
        commandFingerprint: String,
        hostId: String,
        hostRevision: Long,
        pairingRevision: Long,
        catalogRevision: Long,
        appId: String,
        appRevision: Long,
        displayId: Int,
        maximumLifetimeMillis: Long,
        maximumIdleMillis: Long,
        observer: ((MoonlightLeaseObservation) -> Unit)? = null,
    ): MoonlightLeaseSnapshot {
        val captured = capture(expected)
        val (pairing, app) = requireRegistrations().resolve(
            hostId, hostRevision, pairingRevision, catalogRevision, appId, appRevision,
        )
        val context = requireScoped()
        val details = ComputerDatabaseManager(context).let { database ->
            try { database.getComputerByUUID(pairing.upstreamHostUuid) } finally { database.close() }
        } ?: throw MoonlightRuntimeFailure("stale_pairing")
        val active = details.activeAddress ?: details.localAddress ?: details.ipv6Address
            ?: throw MoonlightRuntimeFailure("provider_unavailable")
        val certificate = details.serverCert?.encoded ?: throw MoonlightRuntimeFailure("stale_pairing")
        current(captured)
        return MoonlightForegroundLeaseRegistry.issue(MoonlightLaunchSpec(
            authority = expected,
            sessionId = sessionId,
            epoch = epoch,
            commandFingerprint = commandFingerprint,
            host = active.address,
            port = active.port,
            httpsPort = details.httpsPort,
            appName = app.name,
            appId = app.upstreamAppId,
            uniqueId = IdentityManager(context).uniqueId,
            computerUuid = details.uuid,
            computerName = details.name,
            supportsHdr = app.hdrSupported,
            serverCertificate = certificate,
            displayId = displayId,
            maximumLifetimeMillis = maximumLifetimeMillis,
            maximumIdleMillis = maximumIdleMillis,
        ), observer)
    }

    fun launchStream(snapshot: MoonlightLeaseSnapshot) {
        val spec = MoonlightForegroundLeaseRegistry.resolveForLaunch(snapshot.token)
        val intent = Intent(activity, LarenorMoonlightGame::class.java)
            .putExtra(LarenorMoonlightGame.EXTRA_LAUNCH_TOKEN, snapshot.token)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_DOCUMENT or Intent.FLAG_ACTIVITY_MULTIPLE_TASK)
        val options = android.app.ActivityOptions.makeBasic().setLaunchDisplayId(spec.displayId)
        activity.startActivity(intent, options.toBundle())
    }

    fun ownsForegroundLease(): Boolean = synchronized(lock) {
        val current = authority ?: return@synchronized false
        MoonlightForegroundLeaseRegistry.ownsHostCover(current.authorityId, current.epoch)
    }

    fun ownsPairingPrompt(): Boolean = synchronized(lock) { pairingPrompt != null }

    fun pairingPrompt(
        expected: MoonlightAuthority,
        expectedBindingId: String,
        expectedBindingRevision: Long,
        pairingId: String,
        expectedPairingRevision: Long,
    ): Pair<Pair<String, Long>, Boolean> {
        requireIdentity(expectedBindingId, "candidate")
        requireRevision(expectedBindingRevision, "revision")
        requireIdentity(pairingId, "candidate")
        requireRevision(expectedPairingRevision, "revision")
        val captured = capture(expected)
        val result = synchronized(lock) {
            val binding = exactBinding()
            if (binding.first != expectedBindingId || binding.second != expectedBindingRevision) {
                throw MoonlightRuntimeFailure("authority_changed")
            }
            val owner = pairingPrompt
            binding to (owner?.authorityFingerprint == expected.fingerprint &&
                owner.pairingId == pairingId && owner.pairingRevision == expectedPairingRevision)
        }
        current(captured)
        return result
    }

    fun foregroundLease(
        expected: MoonlightAuthority,
        expectedBindingId: String,
        expectedBindingRevision: Long,
        sessionId: String,
        expectedSessionRevision: Long,
    ): Pair<Pair<String, Long>, MoonlightLeaseSnapshot?> {
        requireIdentity(expectedBindingId, "candidate")
        requireRevision(expectedBindingRevision, "revision")
        requireIdentity(sessionId, "session_id")
        requireRevision(expectedSessionRevision, "revision")
        val captured = capture(expected)
        val binding = synchronized(lock) {
            exactBinding().also {
                if (it.first != expectedBindingId || it.second != expectedBindingRevision) {
                    throw MoonlightRuntimeFailure("authority_changed")
                }
                val session = boundSession
                if (session?.sessionId != sessionId || session.sessionRevision != expectedSessionRevision) {
                    throw MoonlightRuntimeFailure("authority_changed")
                }
            }
        }
        val snapshot = MoonlightForegroundLeaseRegistry.ownedSnapshot(
            expected.authorityId, expected.epoch, sessionId, expectedSessionRevision,
        )
        current(captured)
        return binding to snapshot
    }

    /**
     * Process-private acceptance evidence for the exact currently bound Core
     * session. No launch token, pixels, PCM, provider identifier, or endpoint
     * crosses this boundary.
     */
    internal fun outputWitness(
        expected: MoonlightAuthority,
        sessionId: String,
        expectedSessionRevision: Long,
    ): MoonlightOutputWitnessSnapshot {
        requireIdentity(sessionId, "session_id")
        requireRevision(expectedSessionRevision, "revision")
        val captured = capture(expected)
        val token = synchronized(lock) {
            currentLocked(captured)
            val session = boundSession?.takeIf {
                it.sessionId == sessionId && it.sessionRevision == expectedSessionRevision
            } ?: throw MoonlightRuntimeFailure("authority_changed")
            activeLeaseToken ?: throw MoonlightRuntimeFailure("authority_changed")
        }
        // Registry notifications acquire the runtime lock through their
        // observer. Never hold the runtime lock while reading the lease.
        val witness = MoonlightForegroundLeaseRegistry.outputWitnessSnapshot(token)
        synchronized(lock) {
            currentLocked(captured)
            val session = boundSession?.takeIf {
                it.sessionId == sessionId && it.sessionRevision == expectedSessionRevision
            } ?: throw MoonlightRuntimeFailure("authority_changed")
            if (activeLeaseToken != token || witness.sessionId != session.sessionId ||
                witness.epoch != session.sessionRevision
            ) throw MoonlightRuntimeFailure("authority_changed")
        }
        return witness
    }

    /**
     * Process-private terminal evidence for the exact bound session. A remote
     * disconnect is accepted only from the Game callback that owns this lease;
     * Activity destruction and provider/process inference remain unknown.
     */
    internal fun terminalWitness(
        expected: MoonlightAuthority,
        sessionId: String,
        expectedSessionRevision: Long,
    ): MoonlightTerminalWitnessSnapshot? {
        requireIdentity(sessionId, "session_id")
        requireRevision(expectedSessionRevision, "revision")
        val captured = capture(expected)
        val token = synchronized(lock) {
            currentLocked(captured)
            boundSession?.takeIf {
                it.sessionId == sessionId && it.sessionRevision == expectedSessionRevision
            } ?: throw MoonlightRuntimeFailure("authority_changed")
            activeLeaseToken ?: throw MoonlightRuntimeFailure("authority_changed")
        }
        val witness = MoonlightForegroundLeaseRegistry.terminalWitnessSnapshot(token)
        synchronized(lock) {
            currentLocked(captured)
            val session = boundSession?.takeIf {
                it.sessionId == sessionId && it.sessionRevision == expectedSessionRevision
            } ?: throw MoonlightRuntimeFailure("authority_changed")
            if (activeLeaseToken != token ||
                (witness != null && (witness.sessionId != session.sessionId ||
                    witness.epoch != session.sessionRevision))
            ) throw MoonlightRuntimeFailure("authority_changed")
        }
        return witness
    }

    internal fun streamDispatchTrace(
        expected: MoonlightAuthority,
        requestId: String,
        sessionId: String,
        expectedSessionRevision: Long,
        commandId: String,
    ): MoonlightStreamDispatchDiagnostic? {
        requireIdentity(requestId, "request_id")
        requireIdentity(sessionId, "session_id")
        requireRevision(expectedSessionRevision, "revision")
        requireIdentity(commandId, "candidate")
        val captured = capture(expected)
        val record = requireJournal().read(requestId)
            ?.takeIf {
                it.kind == "command" && it.operationId == commandId && it.subject == sessionId &&
                    it.authorityFingerprint == expected.fingerprint
            } ?: throw MoonlightRuntimeFailure("authority_changed")
        synchronized(lock) {
            currentLocked(captured)
            val session = boundSession?.takeIf {
                it.sessionId == sessionId && it.sessionRevision == expectedSessionRevision
            } ?: throw MoonlightRuntimeFailure("authority_changed")
            if (record.subject != session.sessionId) throw MoonlightRuntimeFailure("authority_changed")
        }
        val owner = MoonlightStreamDispatchOwner(
            expected.fingerprint, requestId, sessionId, expectedSessionRevision,
            commandId, record.fingerprint,
        )
        return streamDispatchTraces.read(owner).also { current(captured) }
    }

    fun retireCurrentAuthority() {
        val (previous, prompt, flight) = synchronized(lock) {
            generation += 1
            candidates.clear()
            boundSession = null
            activeLeaseToken = null
            pairingPrompt = null
            discardPendingPairingsLocked()
            Triple(
                authority.also { authority = null },
                pairingDialog.also { pairingDialog = null },
                pairingFlight.also { pairingFlight = null },
            )
        }
        flight?.cancel()
        prompt?.let { main.post { runCatching { it.close() } } }
        previous?.let { MoonlightForegroundLeaseRegistry.retire(it.authorityId, it.epoch) }
    }

    internal fun retireAuthority(
        expected: MoonlightAuthority,
        requestId: String,
        expectedBindingId: String?,
        expectedBindingRevision: Long?,
    ): MoonlightAuthorityRetirementReceipt {
        requireIdentity(requestId, "request_id")
        if ((expectedBindingId == null) != (expectedBindingRevision == null)) {
            throw MoonlightRuntimeFailure("invalid_receipt")
        }
        expectedBindingId?.let { requireIdentity(it, "candidate") }
        expectedBindingRevision?.let { requireRevision(it, "revision") }
        val context = MoonlightScopedContext.create(activity.applicationContext, expected.scope)
        val store = retirementStoreFactory(
            File(context.noBackupFilesDir, "authority-retirements.json"),
        )
        synchronized(lock) { pendingRetirements[requestId] }?.let { pending ->
            if (pending.authorityFingerprint != expected.fingerprint ||
                (expectedBindingId != null && (pending.nativeBindingId != expectedBindingId ||
                    pending.bindingRevision != expectedBindingRevision))
            ) throw MoonlightRuntimeFailure("invalid_receipt")
            store.save(pending)
            synchronized(lock) { pendingRetirements.remove(requestId) }
            return pending
        }
        store.read(requestId)?.let { stored ->
            if (stored.authorityFingerprint != expected.fingerprint ||
                (expectedBindingId != null && (stored.nativeBindingId != expectedBindingId ||
                    stored.bindingRevision != expectedBindingRevision))
            ) throw MoonlightRuntimeFailure("invalid_receipt")
            return stored
        }
        val retired: MoonlightAuthorityRetirementReceipt
        val previous: MoonlightAuthority
        val prompt: AutoCloseable?
        val flight: MoonlightPairingFlight?
        synchronized(lock) {
            ensureOpen()
            previous = authority?.takeIf { it.fingerprint == expected.fingerprint }
                ?: throw MoonlightRuntimeFailure("authority_changed")
            val binding = exactBinding()
            if (expectedBindingId != null &&
                (binding.first != expectedBindingId || binding.second != expectedBindingRevision)
            ) throw MoonlightRuntimeFailure("authority_changed")
            retired = MoonlightAuthorityRetirementReceipt(
                requestId = requestId,
                authorityId = previous.authorityId,
                authorityEpoch = previous.epoch,
                authorityFingerprint = previous.fingerprint,
                nativeBindingId = binding.first,
                bindingRevision = binding.second,
            )
            generation += 1
            candidates.clear()
            boundSession = null
            activeLeaseToken = null
            pairingPrompt = null
            discardPendingPairingsLocked()
            authority = null
            pendingRetirements[requestId] = retired
            prompt = pairingDialog.also { pairingDialog = null }
            flight = pairingFlight.also { pairingFlight = null }
        }
        flight?.cancel()
        prompt?.let { main.post { runCatching { it.close() } } }
        MoonlightForegroundLeaseRegistry.retire(previous.authorityId, previous.epoch)
        store.save(retired)
        synchronized(lock) { pendingRetirements.remove(requestId) }
        return retired
    }

    fun retireExactSession(sessionId: String, expectedSessionRevision: Long) {
        requireIdentity(sessionId, "session_id")
        requireRevision(expectedSessionRevision, "revision")
        val (prompt, flight) = synchronized(lock) {
            val session = boundSession
            if (session?.sessionId != sessionId || session.sessionRevision != expectedSessionRevision) {
                throw MoonlightRuntimeFailure("authority_changed")
            }
            if (activeLeaseToken != null &&
                MoonlightForegroundLeaseRegistry.retireSession(sessionId, expectedSessionRevision) == null
            ) {
                throw MoonlightRuntimeFailure("authority_changed")
            }
            generation += 1
            candidates.clear()
            boundSession = null
            activeLeaseToken = null
            pairingPrompt = null
            discardPendingPairingsLocked()
            authority = null
            Pair(
                pairingDialog.also { pairingDialog = null },
                pairingFlight.also { pairingFlight = null },
            )
        }
        flight?.cancel()
        prompt?.let { main.post { runCatching { it.close() } } }
    }

    override fun close() {
        val (previous, prompt, flight) = synchronized(lock) {
            if (closed) return
            closed = true
            generation += 1
            candidates.clear()
            boundSession = null
            activeLeaseToken = null
            pairingPrompt = null
            discardPendingPairingsLocked()
            Triple(
                authority.also { authority = null },
                pairingDialog.also { pairingDialog = null },
                pairingFlight.also { pairingFlight = null },
            )
        }
        flight?.cancel()
        prompt?.let { main.post { runCatching { it.close() } } }
        previous?.let { MoonlightForegroundLeaseRegistry.retire(it.authorityId, it.epoch) }
        executor.shutdownNow()
    }

    private fun dispatchStream(
        captured: Captured,
        expected: MoonlightAuthority,
        session: MoonlightBoundSession,
        requestId: String,
        commandId: String,
        fingerprint: String,
        callback: (Result<MoonlightCommandReceipt>) -> Unit,
    ) {
        val traceOwner = MoonlightStreamDispatchOwner(
            expected.fingerprint, requestId, session.sessionId, session.sessionRevision,
            commandId, fingerprint,
        )
        streamDispatchTraces.start(traceOwner)
        val delivered = AtomicBoolean(false)
        fun finish(
            observation: MoonlightLeaseObservation,
            stage: MoonlightStreamDispatchStage,
            causalFailure: Throwable? = null,
            recordStage: Boolean = true,
        ) {
            if (!delivered.compareAndSet(false, true)) return
            if (recordStage && causalFailure != null) {
                streamDispatchTraces.advance(traceOwner, stage, causalFailure)
            }
            val receipt = try {
                if (observation.observationKind != "connectionStarted") {
                    throw MoonlightRuntimeFailure("unknown_effect")
                }
                current(captured)
                val revision = requireJournal().nextReadbackRevision()
                current(captured)
                commandReceipt(
                    requestId, session.sessionId, commandId, "native_observed", "streaming",
                    "connectionStarted", revision,
                )
            } catch (failure: Throwable) {
                if (recordStage && causalFailure == null) {
                    streamDispatchTraces.advance(traceOwner, stage, failure)
                }
                commandReceipt(requestId, session.sessionId, commandId, "unknown", "unknown", "unknown", null)
            }
            if (recordStage && receipt.state == "native_observed") {
                streamDispatchTraces.advance(traceOwner, stage)
            }
            val terminal = if (receipt.state == "native_observed") {
                MoonlightOperationState.CONFIRMED
            } else MoonlightOperationState.UNKNOWN
            requireJournal().transition(
                requestId, MoonlightOperationState.DISPATCHING, terminal,
                receipt.readbackRevision ?: 0, commandReceiptJson(receipt),
            )
            callback(Result.success(receipt))
        }
        try {
            current(captured)
            val capabilities = sessionCapabilities(
                expected, session.hostId, session.hostRevision, session.pairingRevision,
                session.catalogRevision, session.appId, session.appRevision,
            )
            if (capabilities.availability != "available" ||
                capabilities.qualityOptions.none { it.exactlyMatches(session.selectedQuality) }
            ) throw MoonlightRuntimeFailure("stale_candidate")
            val policy = requirePolicyStore().current()
                ?: throw MoonlightRuntimeFailure("stale_candidate")
            if (policy.policyRevision != session.selectedQuality.policyRevision) {
                throw MoonlightRuntimeFailure("stale_candidate")
            }
            val coreRemainingMillis = (session.expiresAtEpochSeconds * 1_000.0 - nowMillis()).toLong()
            val maximumLifetimeMillis = minOf(
                coreRemainingMillis,
                policy.maximumSessionSeconds * 1_000L,
            )
            if (maximumLifetimeMillis <= 0) throw MoonlightRuntimeFailure("authority_changed")
            applySelectedQuality(session.selectedQuality)
            val lease = prepareStream(
                expected, session.sessionId, session.sessionRevision, fingerprint,
                session.hostId, session.hostRevision, session.pairingRevision,
                session.catalogRevision, session.appId, session.appRevision,
                session.selectedQuality.displayId, maximumLifetimeMillis,
                policy.maximumIdleSeconds * 1_000L,
                { observation -> finish(observation, MoonlightStreamDispatchStage.CALLBACK) },
            )
            streamDispatchTraces.advance(traceOwner, MoonlightStreamDispatchStage.POST_ISSUED)
            synchronized(lock) { activeLeaseToken = lease.token }
            main.post {
                try {
                    current(captured)
                    launchStream(lease)
                    streamDispatchTraces.advance(
                        traceOwner, MoonlightStreamDispatchStage.LAUNCH_RETURNED,
                    )
                    main.postDelayed({
                        finish(MoonlightLeaseObservation(
                            runCatching { MoonlightForegroundLeaseRegistry.snapshot(lease.token) }
                                .getOrElse { lease.copy(state = MoonlightLeaseState.UNCERTAIN) },
                            "unknown", "unknown",
                        ), MoonlightStreamDispatchStage.TIMEOUT)
                    }, COMMAND_TIMEOUT_MS)
                } catch (failure: Throwable) {
                    streamDispatchTraces.fail(traceOwner, failure)
                    finish(MoonlightLeaseObservation(
                        lease.copy(state = MoonlightLeaseState.UNCERTAIN), "unknown", "unknown",
                    ), MoonlightStreamDispatchStage.POST_ISSUED, failure, recordStage = false)
                }
            }
        } catch (failure: Throwable) {
            streamDispatchTraces.fail(traceOwner, failure)
            val unknown = commandReceipt(
                requestId, session.sessionId, commandId, "unknown", "unknown", "unknown", null,
            )
            requireJournal().transition(
                requestId, MoonlightOperationState.DISPATCHING, MoonlightOperationState.UNKNOWN, 0,
                commandReceiptJson(unknown),
            )
            callback(Result.success(unknown))
        }
    }

    private fun dispatchProviderCommand(
        captured: Captured,
        session: MoonlightBoundSession,
        requestId: String,
        commandId: String,
        intent: String,
        callback: (Result<MoonlightCommandReceipt>) -> Unit,
    ) {
        executor.execute {
            val receipt = try {
                current(captured)
                val (pairing, app) = requireRegistrations().resolve(
                    session.hostId, session.hostRevision, session.pairingRevision,
                    session.catalogRevision, session.appId, session.appRevision,
                )
                val context = requireScoped()
                val details = ComputerDatabaseManager(context).let { database ->
                    try { database.getComputerByUUID(pairing.upstreamHostUuid) } finally { database.close() }
                } ?: throw MoonlightRuntimeFailure("stale_pairing")
                val address = details.activeAddress ?: details.localAddress ?: details.ipv6Address
                    ?: throw MoonlightRuntimeFailure("provider_unavailable")
                if (intent == "wake") {
                    var serverInfo = runCatching { provider(details, context).getServerInfo(false) }.getOrNull()
                    if (serverInfo == null) {
                        current(captured)
                        WakeOnLanSender.sendWolPacket(details)
                        var attempt = 0
                        while (serverInfo == null && attempt < WAKE_READBACK_ATTEMPTS) {
                            current(captured)
                            Thread.sleep(WAKE_READBACK_INTERVAL_MS)
                            serverInfo = runCatching { provider(details, context).getServerInfo(false) }.getOrNull()
                            attempt += 1
                        }
                    }
                    val observed = serverInfo ?: throw MoonlightRuntimeFailure("unknown_effect")
                    current(captured)
                    val revision = requireJournal().nextReadbackRevision()
                    current(captured)
                    commandReceipt(
                        requestId, session.sessionId, commandId, "native_observed", "hostAwake",
                        "serverInfoOnline", revision,
                    )
                } else {
                    val http = provider(details, context)
                    val serverInfo = http.getServerInfo(true)
                    if (http.getPairState(serverInfo) != PairingManager.PairState.PAIRED) {
                        throw MoonlightRuntimeFailure("stale_pairing")
                    }
                    if (http.getCurrentGame(serverInfo) != app.upstreamAppId) {
                        val streamConfig = StreamConfiguration.Builder()
                            .setApp(com.limelight.nvstream.http.NvApp(app.name, app.upstreamAppId, app.hdrSupported))
                            .setRemoteConfiguration(StreamConfiguration.STREAM_CFG_AUTO)
                            .setResolution(session.selectedQuality.widthPixels, session.selectedQuality.heightPixels)
                            .setRefreshRate(session.selectedQuality.framesPerSecond)
                            .setLaunchRefreshRate(session.selectedQuality.framesPerSecond)
                            .setBitrate(session.selectedQuality.bitrateKbps)
                            .setEnableSops(true)
                            .enableAdaptiveResolution(false)
                            .enableLocalAudioPlayback(false)
                            .setMaxPacketSize(1_392)
                            .setAttachedGamepadMask(0)
                            .setPersistGamepadsAfterDisconnect(false)
                            .setClientRefreshRateX100(session.selectedQuality.framesPerSecond * 100)
                            .setAudioConfiguration(MoonBridge.AUDIO_CONFIGURATION_STEREO)
                            .setSupportedVideoFormats(videoFormat(session.selectedQuality.codec))
                            .build()
                        val connection = ConnectionContext().apply {
                            isNvidiaServerSoftware = details.nvidiaServer
                            this.streamConfig = streamConfig
                            negotiatedWidth = session.selectedQuality.widthPixels
                            negotiatedHeight = session.selectedQuality.heightPixels
                            negotiatedHdr = app.hdrSupported
                            riKey = KeyGenerator.getInstance("AES").apply { init(128) }.generateKey()
                            riKeyId = random.nextInt(Int.MAX_VALUE)
                        }
                        if (http.getCurrentGame(serverInfo) != 0) {
                            current(captured)
                            if (!http.quitApp()) throw MoonlightRuntimeFailure("unknown_effect")
                        }
                        current(captured)
                        if (!http.launchApp(connection, "launch", app.upstreamAppId, app.hdrSupported)) {
                            throw MoonlightRuntimeFailure("unknown_effect")
                        }
                    }
                    val readback = http.getServerInfo(true)
                    if (http.getCurrentGame(readback) != app.upstreamAppId) {
                        throw MoonlightRuntimeFailure("unknown_effect")
                    }
                    current(captured)
                    val revision = requireJournal().nextReadbackRevision()
                    current(captured)
                    commandReceipt(
                        requestId, session.sessionId, commandId, "native_observed", "appRunning",
                        "currentGameMatched", revision,
                    )
                }
            } catch (_: Throwable) {
                commandReceipt(
                    requestId, session.sessionId, commandId, "unknown", "unknown", "unknown", null,
                )
            }
            val state = if (receipt.state == "native_observed") {
                MoonlightOperationState.CONFIRMED
            } else MoonlightOperationState.UNKNOWN
            requireJournal().transition(
                requestId, MoonlightOperationState.DISPATCHING, state,
                receipt.readbackRevision ?: 0, commandReceiptJson(receipt),
            )
            main.post { callback(Result.success(receipt)) }
        }
    }

    private fun provider(details: ComputerDetails, context: Context): NvHTTP {
        val address = details.activeAddress ?: details.localAddress ?: details.ipv6Address
            ?: throw MoonlightRuntimeFailure("provider_unavailable")
        val certificate = details.serverCert ?: throw MoonlightRuntimeFailure("stale_pairing")
        return NvHTTP(
            address, details.httpsPort, IdentityManager(context).uniqueId,
            certificate, AndroidCryptoProvider(context),
        )
    }

    private fun videoFormat(codec: String): Int = when (codec) {
        "av1" -> MoonBridge.VIDEO_FORMAT_MASK_AV1
        "hevc" -> MoonBridge.VIDEO_FORMAT_MASK_H265
        else -> MoonBridge.VIDEO_FORMAT_MASK_H264
    }

    private fun dispatchStop(
        captured: Captured,
        session: MoonlightBoundSession,
        requestId: String,
        commandId: String,
        callback: (Result<MoonlightCommandReceipt>) -> Unit,
    ) {
        val token = synchronized(lock) { activeLeaseToken }
        if (token == null) {
            val unknown = commandReceipt(
                requestId, session.sessionId, commandId, "unknown", "unknown", "unknown", null,
            )
            requireJournal().transition(
                requestId, MoonlightOperationState.DISPATCHING, MoonlightOperationState.UNKNOWN, 0,
                commandReceiptJson(unknown),
            )
            callback(Result.success(unknown))
            return
        }
        val delivered = AtomicBoolean(false)
        fun finish(observation: MoonlightLeaseObservation) {
            if (!delivered.compareAndSet(false, true)) return
            val receipt = try {
                if (observation.observationKind !in setOf("connectionTerminated", "connectionStopped")) {
                    throw MoonlightRuntimeFailure("unknown_effect")
                }
                current(captured)
                val revision = requireJournal().nextReadbackRevision()
                current(captured)
                commandReceipt(
                    requestId, session.sessionId, commandId, "native_observed", "stopped",
                    observation.observationKind, revision,
                )
            } catch (_: Throwable) {
                commandReceipt(requestId, session.sessionId, commandId, "unknown", "unknown", "unknown", null)
            }
            requireJournal().transition(
                requestId, MoonlightOperationState.DISPATCHING,
                if (receipt.state == "native_observed") MoonlightOperationState.CONFIRMED
                else MoonlightOperationState.UNKNOWN,
                receipt.readbackRevision ?: 0, commandReceiptJson(receipt),
            )
            if (receipt.state == "native_observed") synchronized(lock) { activeLeaseToken = null }
            callback(Result.success(receipt))
        }
        try {
            current(captured)
            MoonlightForegroundLeaseRegistry.observe(token, ::finish)
            val snapshot = MoonlightForegroundLeaseRegistry.retireSession(
                session.sessionId, session.sessionRevision,
            ) ?: throw MoonlightRuntimeFailure("authority_changed")
            main.postDelayed({
                finish(MoonlightLeaseObservation(snapshot, "unknown", "unknown"))
            }, COMMAND_TIMEOUT_MS)
        } catch (_: Throwable) {
            finish(MoonlightLeaseObservation(
                MoonlightLeaseSnapshot(token, session.sessionId, session.sessionRevision,
                    MoonlightLeaseState.UNCERTAIN, 0),
                "unknown", "unknown",
            ))
        }
    }

    private fun dispatchSafetyStop(
        stopJournal: MoonlightOperationJournal,
        token: String,
        session: MoonlightBoundSession,
        requestId: String,
        commandId: String,
        callback: (Result<MoonlightCommandReceipt>) -> Unit,
    ) {
        val delivered = AtomicBoolean(false)
        fun finish(observation: MoonlightLeaseObservation) {
            if (!delivered.compareAndSet(false, true)) return
            val receipt = try {
                if (observation.snapshot.token != token ||
                    observation.snapshot.sessionId != session.sessionId ||
                    observation.snapshot.epoch != session.sessionRevision ||
                    observation.observationKind !in setOf("connectionTerminated", "connectionStopped")
                ) throw MoonlightRuntimeFailure("unknown_effect")
                val revision = stopJournal.nextReadbackRevision()
                commandReceipt(
                    requestId, session.sessionId, commandId, "native_observed", "stopped",
                    observation.observationKind, revision,
                )
            } catch (_: Throwable) {
                commandReceipt(requestId, session.sessionId, commandId, "unknown", "unknown", "unknown", null)
            }
            stopJournal.transition(
                requestId, MoonlightOperationState.DISPATCHING,
                if (receipt.state == "native_observed") MoonlightOperationState.CONFIRMED
                else MoonlightOperationState.UNKNOWN,
                receipt.readbackRevision ?: 0, commandReceiptJson(receipt),
            )
            callback(Result.success(receipt))
        }
        try {
            MoonlightForegroundLeaseRegistry.observe(token, ::finish)
            val snapshot = MoonlightForegroundLeaseRegistry.retireSession(
                session.sessionId, session.sessionRevision,
            ) ?: throw MoonlightRuntimeFailure("authority_changed")
            main.postDelayed({
                finish(MoonlightLeaseObservation(snapshot, "unknown", "unknown"))
            }, COMMAND_TIMEOUT_MS)
        } catch (_: Throwable) {
            finish(MoonlightLeaseObservation(
                MoonlightLeaseSnapshot(
                    token, session.sessionId, session.sessionRevision,
                    MoonlightLeaseState.UNCERTAIN, 0,
                ),
                "unknown", "unknown",
            ))
        }
    }

    private fun applySelectedQuality(quality: MoonlightSelectedQuality) {
        if (quality.frameQueueDepth != 2 || quality.inputQueueDepth != 1) {
            throw MoonlightRuntimeFailure("unsupported")
        }
        val context = requireScoped()
        val format = when (quality.codec) {
            "av1" -> "forceav1"
            "hevc" -> "forceh265"
            else -> "neverh265"
        }
        val committed = PreferenceManager.getDefaultSharedPreferences(context).edit()
            .remove("list_resolution_fps")
            .putString("list_resolution", "${quality.widthPixels}x${quality.heightPixels}")
            .putString("list_fps", quality.framesPerSecond.toString())
            .putInt("seekbar_bitrate_kbps", quality.bitrateKbps)
            .putString("video_format", format)
            .putBoolean("checkbox_unlock_fps", quality.framesPerSecond > 60)
            // The upstream USB-driver binder bypasses Activity dispatch and has
            // no listener tap for truthful idle accounting. Android framework
            // controller/key/motion input remains enabled and reaches Game.
            .putBoolean("checkbox_usb_driver", false)
            .putBoolean("checkbox_usb_bind_all", false)
            .putString("frame_pacing", "latency")
            .commit()
        if (!committed) throw MoonlightRuntimeFailure("unknown_effect")
    }

    private fun MoonlightQualityOption.exactlyMatches(value: MoonlightSelectedQuality): Boolean =
        codec == value.codec && codecId == value.codecId && codecRevision == value.codecRevision &&
            displayId == value.displayId && displayRevision == value.displayRevision &&
            networkId == value.networkId && networkRevision == value.networkRevision &&
            policyId == value.policyId && policyRevision == value.policyRevision &&
            widthPixels == value.widthPixels && heightPixels == value.heightPixels &&
            framesPerSecond == value.framesPerSecond && bitrateKbps == value.bitrateKbps &&
            frameQueueDepth == value.frameQueueDepth && inputQueueDepth == value.inputQueueDepth &&
            secureSurface == value.secureSurface

    private fun probe(captured: Captured, endpoint: MoonlightDiscoveredEndpoint): ProbedCandidate {
        current(captured)
        val context = captured.scoped
        val address = ComputerDetails.AddressTuple(endpoint.host, endpoint.port)
        val http = NvHTTP(address, 0, IdentityManager(context).uniqueId, null, AndroidCryptoProvider(context))
        val serverInfo = http.getServerInfo(false)
        val details = http.getComputerDetails(serverInfo).also {
            it.activeAddress = address
            it.localAddress = address
        }
        val hostDigest = sha256("${details.uuid}\u0000${details.name}".toByteArray()).hex()
        val candidateId = secretId("candidate", endpoint.host, endpoint.port.toString(), details.uuid)
        val revision = publicRevision(hostDigest, details.pairState.name, details.runningGameId.toString())
        return ProbedCandidate(
            MoonlightCandidate(
                candidateId, revision, safeName(details.name, 128), "awake",
                if (details.pairState == PairingManager.PairState.PAIRED) "paired" else "notPaired",
                hostDigest,
            ), endpoint, details, serverInfo,
        )
    }

    private fun pairBlocking(
        captured: Captured,
        candidate: ProbedCandidate,
        requestId: String,
        pin: String,
        flight: MoonlightPairingFlight,
    ): MoonlightPairReceipt {
        val context = captured.scoped
        val address = ComputerDetails.AddressTuple(candidate.endpoint.host, candidate.endpoint.port)
        val crypto = AndroidCryptoProvider(context)
        val http = NvHTTP(address, 0, IdentityManager(context).uniqueId, null, crypto)
        var pinned: NvHTTP? = null
        flight.attach(http)
        try {
            flight.requireActive()
            val serverInfo = http.getServerInfo(true)
            current(captured)
            flight.requireActive()
            val pairState = http.pairingManager.pair(serverInfo, pin)
            current(captured)
            flight.requireActive()
            if (pairState != PairingManager.PairState.PAIRED) {
                val revision = publicRevision(requestId, "rejected", pairState.name)
                val rejected = MoonlightPairReceipt(requestId, "rejected", revision)
                captured.journal.transition(
                    requestId, MoonlightOperationState.DISPATCHING, MoonlightOperationState.REJECTED,
                    revision, pairReceiptJson(rejected),
                )
                return rejected
            }
            val certificate = http.pairingManager.pairedCert
                ?: throw MoonlightRuntimeFailure("unknown_effect")
            val pinnedHttp = NvHTTP(
                address, http.getHttpsPort(serverInfo), IdentityManager(context).uniqueId, certificate, crypto,
            )
            pinned = pinnedHttp
            flight.attach(pinnedHttp)
            flight.requireActive()
            val readback = pinnedHttp.getServerInfo(true)
            current(captured)
            flight.requireActive()
            if (pinnedHttp.getPairState(readback) != PairingManager.PairState.PAIRED) {
                throw MoonlightRuntimeFailure("unknown_effect")
            }
            val details = pinnedHttp.getComputerDetails(readback).also {
                it.activeAddress = address
                it.localAddress = address
                it.serverCert = certificate
                it.pairState = PairingManager.PairState.PAIRED
            }
            flight.requireActive()
            val apps = requireBoundedCatalog(pinnedHttp.appList, MAX_APPS)
            current(captured)
            flight.requireActive()
            val receiptId = randomIdentity()
            val nativeBindingId = captured.bindingId
            val nativeBindingRevision = captured.bindingRevision
            val hostObservationId = secretId("host", details.uuid, certificate.encoded.hex())
            val observedApps = apps.sortedWith(compareBy({ it.appName }, { it.appId }))
                .mapIndexed { index, app ->
                    MoonlightObservedApp(
                        entryIndex = index,
                        observationId = secretId("app", details.uuid, app.appId.toString()),
                        revision = publicRevision(
                            details.uuid,
                            app.appId.toString(),
                            app.appName,
                            app.isHdrSupported.toString(),
                        ),
                        name = safeName(app.appName, 160),
                        upstreamAppId = app.appId,
                        hdrSupported = app.isHdrSupported,
                    )
                }
            val catalogDigest = canonicalCatalogDigest(observedApps)
            val catalogRevision = publicRevision(catalogDigest)
            val pairingRevision = publicRevision(certificate.encoded.hex(), details.uuid)
            val codecs = mutableListOf("h264").apply {
                val modes = pinnedHttp.getServerCodecModeSupport(readback)
                if (modes and 0x0F00 != 0L) add("hevc")
                if (modes and 0xF000 != 0L) add("av1")
            }
            val observation = JSONObject()
                .put("schemaVersion", 1)
                .put("receiptId", receiptId)
                .put("nativeBindingId", nativeBindingId)
                .put("bindingRevision", nativeBindingRevision)
                .put("engineRevision", ENGINE_REVISION)
                .put("provider", PROVIDER)
                .put("state", "paired")
                .put("hostObservationId", hostObservationId)
                .put("name", safeName(details.name, 80))
                .put("codecs", JSONArray(codecs))
                .put("catalogRevision", catalogRevision)
                .put("catalogDigest", catalogDigest)
                .put("apps", JSONArray().also { array ->
                    observedApps.forEach { app ->
                        array.put(
                            JSONObject()
                                .put("observationId", app.observationId)
                                .put("revision", app.revision)
                                .put("name", app.name),
                        )
                    }
                })
            val pairing = MoonlightNativePairing(
                receiptId, nativeBindingId, nativeBindingRevision, hostObservationId,
                details.uuid, pairingRevision, catalogRevision, catalogDigest, observedApps,
                observation.toString(),
            )
            val revision = publicRevision(receiptId, pairingRevision.toString(), catalogRevision.toString())
            val receipt = MoonlightPairReceipt(
                requestId, "paired", revision,
                MoonlightPairedHost(
                    secretId("host-handle", details.uuid),
                    secretId("credential", details.uuid, certificate.encoded.hex()),
                    safeName(details.name, 128), pairingRevision,
                    sha256(certificate.encoded).hex(), codecs.toSet(),
                ),
                nativeObservationJson = observation.toString(),
            )
            flight.withActive {
                synchronized(lock) {
                    currentLocked(captured)
                    flight.requireActive()
                    ComputerDatabaseManager(context).let { database ->
                        try {
                            if (!database.updateComputer(details)) {
                                throw MoonlightRuntimeFailure("unknown_effect")
                            }
                        } finally {
                            database.close()
                        }
                    }
                    currentLocked(captured)
                    flight.requireActive()
                    captured.registrations.savePairing(pairing)
                    pendingPairings[receiptId] = PendingPairing(
                        upstreamUuid = details.uuid,
                        requestId = requestId,
                        operationId = captured.journal.read(requestId)?.operationId
                            ?: throw MoonlightRuntimeFailure("invalid_receipt"),
                        kind = "pair",
                    )
                    captured.journal.transition(
                        requestId, MoonlightOperationState.DISPATCHING,
                        MoonlightOperationState.CONFIRMED,
                        revision, pairReceiptJson(receipt),
                    )
                }
            }
            return receipt
        } finally {
            pinned?.let(flight::detach)
            flight.detach(http)
        }
    }

    private fun revokeBlocking(
        captured: Captured,
        pairing: MoonlightNativePairing,
        registration: MoonlightCoreRegistration,
        requestId: String,
    ): MoonlightRevokeReceipt = synchronized(lock) {
        currentLocked(captured)
        if (registration.hostId !in retiringHosts ||
            captured.registrations.registration(registration.hostId) != registration ||
            captured.registrations.pairing(pairing.receiptId) != pairing
        ) throw MoonlightRuntimeFailure("authority_changed")

        // Fence the Core-resolvable mapping first. All registration commits and authority changes
        // share this lock, so an obsolete generation can never delete a successor registration.
        captured.registrations.deletePairing(pairing.receiptId)
        if (captured.registrations.pairing(pairing.receiptId) != null ||
            captured.registrations.registration(registration.hostId) != null
        ) throw MoonlightRuntimeFailure("unknown_effect")
        localRetirementAfterRegistrationFence?.invoke()
        currentLocked(captured)

        val context = captured.scoped
        val database = ComputerDatabaseManager(context)
        val details = try {
            database.getComputerByUUID(pairing.upstreamHostUuid)
                ?: throw MoonlightRuntimeFailure("stale_pairing")
        } finally {
            database.close()
        }
        ComputerDatabaseManager(context).let { next ->
            try { next.deleteComputer(details) } finally { next.close() }
        }
        val computerCleared = ComputerDatabaseManager(context).let { next ->
            try { next.getComputerByUUID(pairing.upstreamHostUuid) == null } finally { next.close() }
        }
        if (!computerCleared) throw MoonlightRuntimeFailure("unknown_effect")
        currentLocked(captured)
        val revision = captured.journal.nextReadbackRevision()
        // Sunshine has no client-certificate-authorized NvHTTP unpair route.
        // This receipt proves only exact scoped native storage retirement.
        val receipt = MoonlightRevokeReceipt(requestId, "local_cleared", revision)
        captured.journal.transition(
            requestId, MoonlightOperationState.DISPATCHING, MoonlightOperationState.REVOKED,
            revision, revokeReceiptJson(receipt),
        )
        receipt
    }

    private fun refreshCatalogBlocking(
        captured: Captured,
        previous: MoonlightNativePairing,
        authorization: MoonlightCatalogAuthorization,
    ): MoonlightCatalogReceipt {
        val context = captured.scoped
        val details = ComputerDatabaseManager(context).let { database ->
            try { database.getComputerByUUID(previous.upstreamHostUuid) } finally { database.close() }
        } ?: throw MoonlightRuntimeFailure("stale_pairing")
        val address = details.activeAddress ?: details.localAddress ?: details.ipv6Address
            ?: throw MoonlightRuntimeFailure("provider_unavailable")
        val certificate = details.serverCert ?: throw MoonlightRuntimeFailure("stale_pairing")
        val http = NvHTTP(
            address, details.httpsPort, IdentityManager(context).uniqueId,
            certificate, AndroidCryptoProvider(context),
        )
        val serverInfo = http.getServerInfo(true)
        if (http.getPairState(serverInfo) != PairingManager.PairState.PAIRED) {
            throw MoonlightRuntimeFailure("stale_pairing")
        }
        val apps = requireBoundedCatalog(http.appList, MAX_APPS)
        current(captured)
        val observedApps = apps.sortedWith(compareBy({ it.appName }, { it.appId })).mapIndexed { index, app ->
            MoonlightObservedApp(
                entryIndex = index,
                observationId = secretId("app", previous.upstreamHostUuid, app.appId.toString()),
                revision = publicRevision(
                    previous.upstreamHostUuid, app.appId.toString(), app.appName, app.isHdrSupported.toString(),
                ),
                name = safeName(app.appName, 160),
                upstreamAppId = app.appId,
                hdrSupported = app.isHdrSupported,
            )
        }
        if (authorization.expectedCatalogRevision >= MAX_JS_REVISION) {
            throw MoonlightRuntimeFailure("invalid_revision")
        }
        val catalogRevision = authorization.expectedCatalogRevision + 1
        val catalogDigest = canonicalCatalogDigest(observedApps)
        val receiptId = randomIdentity()
        val appsJson = JSONArray().also { array -> observedApps.forEach { app ->
            array.put(JSONObject()
                .put("observationId", app.observationId)
                .put("revision", app.revision)
                .put("name", app.name))
        } }
        val fullObservation = JSONObject(previous.observationJson)
            .put("receiptId", receiptId)
            .put("catalogRevision", catalogRevision)
            .put("catalogDigest", catalogDigest)
            .put("apps", appsJson)
        val updated = previous.copy(
            receiptId = receiptId,
            catalogRevision = catalogRevision,
            catalogDigest = catalogDigest,
            apps = observedApps,
            observationJson = fullObservation.toString(),
        )
        val observation = JSONObject()
            .put("schemaVersion", 1)
            .put("receiptId", receiptId)
            .put("nativeBindingId", updated.nativeBindingId)
            .put("bindingRevision", updated.bindingRevision)
            .put("catalogRevision", catalogRevision)
            .put("catalogDigest", catalogDigest)
            .put("apps", appsJson)
        val readbackRevision = publicRevision(receiptId, catalogRevision.toString(), catalogDigest)
        val receipt = MoonlightCatalogReceipt(
            authorization.requestId, authorization.catalogObservationId, "observed",
            readbackRevision, observation.toString(),
        )
        synchronized(lock) {
            currentLocked(captured)
            captured.registrations.savePairing(updated)
            pendingPairings[receiptId] = PendingPairing(
                upstreamUuid = updated.upstreamHostUuid,
                requestId = authorization.requestId,
                operationId = authorization.catalogObservationId,
                kind = "catalog",
            )
            captured.journal.transition(
                authorization.requestId, MoonlightOperationState.DISPATCHING,
                MoonlightOperationState.CONFIRMED, readbackRevision, catalogReceiptJson(receipt),
            )
        }
        return receipt
    }

    private fun pairReadback(record: MoonlightOperationRecord): MoonlightPairReceipt =
        record.result?.let(::decodePairReceipt)
            ?: MoonlightPairReceipt(record.requestId, "unknown", maxOf(1, record.readbackRevision))

    private fun revokeReadback(record: MoonlightOperationRecord): MoonlightRevokeReceipt =
        record.result?.let(::decodeRevokeReceipt)
            ?: MoonlightRevokeReceipt(record.requestId, "unknown", null)

    private fun commandReadback(
        record: MoonlightOperationRecord,
        requestId: String,
    ): MoonlightCommandReceipt = record.result?.let(::decodeCommandReceipt)?.copy(requestId = requestId)
        ?: commandReceipt(requestId, record.subject, record.operationId, "unknown", "unknown", "unknown", null)

    private fun commandReceipt(
        requestId: String,
        sessionId: String,
        commandId: String,
        state: String,
        result: String,
        observationKind: String,
        readbackRevision: Long?,
    ): MoonlightCommandReceipt {
        val digest = if (state == "unknown") null else sha256(listOf(
            requestId, sessionId, commandId, state, result, observationKind,
            readbackRevision?.toString().orEmpty(),
        ).joinToString("\u0000").toByteArray(Charsets.UTF_8)).hex()
        return MoonlightCommandReceipt(
            requestId, sessionId, commandId, state, result, observationKind, readbackRevision, digest,
        )
    }

    private fun commandReceiptJson(value: MoonlightCommandReceipt): String = JSONObject()
        .put("requestId", value.requestId)
        .put("sessionId", value.sessionId)
        .put("commandId", value.commandId)
        .put("state", value.state)
        .put("result", value.result)
        .put("observationKind", value.observationKind)
        .put("readbackRevision", value.readbackRevision ?: JSONObject.NULL)
        .put("nativeReceiptDigest", value.nativeReceiptDigest ?: JSONObject.NULL)
        .toString()

    private fun decodeCommandReceipt(raw: String): MoonlightCommandReceipt {
        val value = JSONObject(raw)
        return MoonlightCommandReceipt(
            value.getString("requestId"), value.getString("sessionId"), value.getString("commandId"),
            value.getString("state"), value.getString("result"), value.getString("observationKind"),
            if (value.isNull("readbackRevision")) null else value.getLong("readbackRevision"),
            if (value.isNull("nativeReceiptDigest")) null else value.getString("nativeReceiptDigest"),
        )
    }

    private fun catalogReadback(
        record: MoonlightOperationRecord,
        catalogObservationId: String,
    ): MoonlightCatalogReceipt {
        val stored = record.result?.let { JSONObject(it) }
            ?: return MoonlightCatalogReceipt(
                record.requestId, catalogObservationId, "unknown", maxOf(1, record.readbackRevision),
            )
        val nativeReceiptId = if (stored.isNull("nativeReceiptId")) null else stored.getString("nativeReceiptId")
        val observation = nativeReceiptId?.let { receiptId ->
            val pairing = requireRegistrations().pairing(receiptId)
                ?: throw MoonlightRuntimeFailure("invalid_receipt")
            val full = JSONObject(pairing.observationJson)
            JSONObject()
                .put("schemaVersion", 1)
                .put("receiptId", pairing.receiptId)
                .put("nativeBindingId", pairing.nativeBindingId)
                .put("bindingRevision", pairing.bindingRevision)
                .put("catalogRevision", pairing.catalogRevision)
                .put("catalogDigest", pairing.catalogDigest)
                .put("apps", full.getJSONArray("apps"))
                .toString()
        }
        return MoonlightCatalogReceipt(
            record.requestId, catalogObservationId, stored.getString("state"),
            stored.getLong("readbackRevision"), observation, stored.getString("nativeReceiptDigest"),
        )
    }

    private fun catalogReceiptJson(value: MoonlightCatalogReceipt): String = JSONObject()
        .put("state", value.state)
        .put("readbackRevision", value.readbackRevision)
        .put("nativeReceiptId", value.nativeObservationJson?.let { JSONObject(it).getString("receiptId") }
            ?: JSONObject.NULL)
        .put("nativeReceiptDigest", value.nativeReceiptDigest)
        .toString()

    private fun pairReceiptJson(value: MoonlightPairReceipt): String = JSONObject()
        .put("requestId", value.requestId)
        .put("status", value.status)
        .put("readbackRevision", value.readbackRevision)
        .put("nativeReceiptId", value.nativeObservationJson?.let { JSONObject(it).getString("receiptId") }
            ?: JSONObject.NULL)
        .put("nativeReceiptDigest", value.nativeReceiptDigest)
        .put("host", value.host?.let { host -> JSONObject()
            .put("hostHandle", host.hostHandle)
            .put("credentialHandle", host.credentialHandle)
            .put("displayName", host.displayName)
            .put("pairingRevision", host.pairingRevision)
            .put("serverFingerprint", host.serverFingerprint)
            .put("codecs", JSONArray(host.codecs.sorted()))
        } ?: JSONObject.NULL)
        .toString()

    private fun decodePairReceipt(raw: String): MoonlightPairReceipt {
        val value = JSONObject(raw)
        val host = if (value.isNull("host")) null else value.getJSONObject("host").let { raw ->
            MoonlightPairedHost(
                raw.getString("hostHandle"), raw.getString("credentialHandle"), raw.getString("displayName"),
                raw.getLong("pairingRevision"), raw.getString("serverFingerprint"),
                raw.getJSONArray("codecs").let { array ->
                    (0 until array.length()).map { array.getString(it) }.toSet()
                },
            )
        }
        val observation = if (value.isNull("nativeReceiptId")) null else
            requireRegistrations().pairing(value.getString("nativeReceiptId"))?.observationJson
                ?: throw MoonlightRuntimeFailure("invalid_receipt")
        return MoonlightPairReceipt(
            value.getString("requestId"), value.getString("status"), value.getLong("readbackRevision"), host,
            observation,
            value.getString("nativeReceiptDigest"),
        )
    }

    private fun revokeReceiptJson(value: MoonlightRevokeReceipt): String = JSONObject()
        .put("requestId", value.requestId)
        .put("status", value.status)
        .put("readbackRevision", value.readbackRevision ?: JSONObject.NULL)
        .toString()

    private fun decodeRevokeReceipt(raw: String): MoonlightRevokeReceipt {
        val value = JSONObject(raw)
        val persistedStatus = value.getString("status")
        val status = if (persistedStatus == "revoked") "local_cleared" else persistedStatus
        return MoonlightRevokeReceipt(
            value.getString("requestId"), status,
            if (value.isNull("readbackRevision")) null else value.getLong("readbackRevision"),
        )
    }

    private fun secretId(vararg parts: String): String {
        val key = nativeSecret()
        val digest = MessageDigest.getInstance("SHA-256")
        digest.update(key)
        parts.forEach { digest.update(0); digest.update(it.toByteArray()) }
        return digest.digest().hex().take(32)
    }

    private fun nativeSecret(): ByteArray = synchronized(lock) {
        val file = File(requireScoped().noBackupFilesDir, "native-handle.key")
        if (file.exists()) {
            val value = file.readBytes()
            if (!file.isFile || file.isSymbolicLink() || value.size != 32) {
                throw MoonlightRuntimeFailure("invalid_receipt")
            }
            return@synchronized value
        }
        val value = ByteArray(32).also(random::nextBytes)
        if (!file.createNewFile()) return@synchronized nativeSecret()
        file.outputStream().use { it.write(value); it.flush(); it.fd.sync() }
        value
    }

    private fun randomIdentity(): String = ByteArray(16).also(random::nextBytes).hex()
    private fun safeName(value: String?, maximum: Int): String {
        val normalized = value?.trim()?.filter { it.code >= 32 && it.code != 127 }?.take(maximum).orEmpty()
        if (normalized.isBlank()) throw MoonlightRuntimeFailure("provider_unavailable")
        return normalized
    }

    private data class Captured(
        val fingerprint: String,
        val generation: Long,
        val scoped: MoonlightScopedContext,
        val journal: MoonlightOperationJournal,
        val registrations: MoonlightRegistrationStore,
        val bindingId: String,
        val bindingRevision: Long,
    )
    private data class SafetyStopContext(
        val authority: MoonlightAuthority,
        val session: MoonlightBoundSession,
        val token: String,
        val journal: MoonlightOperationJournal,
    )
    private data class PairingPromptOwner(
        val authorityFingerprint: String,
        val pairingId: String,
        val pairingRevision: Long,
    )
    private data class PendingPairing(
        val upstreamUuid: String,
        val requestId: String,
        val operationId: String,
        val kind: String,
    )
    private fun capture(expected: MoonlightAuthority): Captured = synchronized(lock) {
        ensureOpen()
        if (authority?.fingerprint != expected.fingerprint) throw MoonlightRuntimeFailure("authority_changed")
        Captured(
            expected.fingerprint,
            generation,
            scoped ?: throw MoonlightRuntimeFailure("authority_changed"),
            journal ?: throw MoonlightRuntimeFailure("authority_changed"),
            registrations ?: throw MoonlightRuntimeFailure("authority_changed"),
            bindingId ?: throw MoonlightRuntimeFailure("authority_changed"),
            bindingRevision,
        )
    }

    private fun current(captured: Captured) = synchronized(lock) {
        currentLocked(captured)
    }

    private fun currentLocked(captured: Captured) {
        if (closed || generation != captured.generation || authority?.fingerprint != captured.fingerprint) {
            throw MoonlightRuntimeFailure("authority_changed")
        }
    }

    private fun ensureHostUsable(captured: Captured, hostId: String) = synchronized(lock) {
        currentLocked(captured)
        ensureHostUsableLocked(captured, hostId)
    }

    private fun ensureHostUsableLocked(captured: Captured, hostId: String) {
        if (hostId in retiringHosts || captured.journal.list().any {
                it.kind == "revoke" && it.subject == hostId &&
                    it.state in setOf(
                        MoonlightOperationState.PREPARED,
                        MoonlightOperationState.DISPATCHING,
                        MoonlightOperationState.UNKNOWN,
                    )
            }
        ) throw MoonlightRuntimeFailure("quarantined")
    }

    private fun discardPendingPairingsLocked() {
        if (pendingPairings.isEmpty()) return
        val context = scoped
        val store = registrations
        val pending = pendingPairings.toMap()
        pendingPairings.clear()
        pending.forEach { (receiptId, value) ->
            runCatching {
                val record = journal?.read(value.requestId)
                if (record?.state == MoonlightOperationState.CONFIRMED) {
                    val revision = publicRevision(value.requestId, "authority-retired")
                    val result = when (value.kind) {
                        "pair" -> pairReceiptJson(
                            MoonlightPairReceipt(value.requestId, "unknown", revision),
                        )
                        "catalog" -> catalogReceiptJson(MoonlightCatalogReceipt(
                            value.requestId, value.operationId, "unknown", revision,
                        ))
                        else -> throw MoonlightRuntimeFailure("invalid_receipt")
                    }
                    journal?.transition(
                        value.requestId, MoonlightOperationState.CONFIRMED,
                        MoonlightOperationState.UNKNOWN, revision, result,
                    )
                }
            }
            runCatching { store?.deletePairing(receiptId) }
            if (context != null && value.kind == "pair") runCatching {
                ComputerDatabaseManager(context).let { database ->
                    try {
                        database.getComputerByUUID(value.upstreamUuid)?.let(database::deleteComputer)
                    } finally {
                        database.close()
                    }
                }
            }
        }
    }

    private fun exactBinding(): Pair<String, Long> =
        (bindingId ?: throw MoonlightRuntimeFailure("authority_changed")) to bindingRevision
    private fun requireScoped() = synchronized(lock) { scoped } ?: throw MoonlightRuntimeFailure("authority_changed")
    private fun requireJournal() = synchronized(lock) { journal } ?: throw MoonlightRuntimeFailure("authority_changed")
    private fun requireRegistrations() = synchronized(lock) { registrations }
        ?: throw MoonlightRuntimeFailure("authority_changed")
    private fun requirePolicyStore() = synchronized(lock) { policyStore }
        ?: throw MoonlightRuntimeFailure("authority_changed")
    private fun requirePolicyPin(expected: MoonlightAuthority) {
        val policy = requirePolicyStore().current() ?: throw MoonlightRuntimeFailure("stale_candidate")
        if (policy.requirePin) requirePinSatisfied(expected)
    }
    private fun requirePinSatisfied(expected: MoonlightAuthority) {
        if (!expected.pinConfigured || !expected.pinUnlocked) throw MoonlightRuntimeFailure("pin_required")
    }
    private fun ensureOpen() { if (closed) throw MoonlightRuntimeFailure("engine_unavailable") }
    private fun publicFailure(value: Throwable): Throwable =
        value as? MoonlightRuntimeFailure ?: MoonlightRuntimeFailure("provider_unavailable")
    private fun File.isSymbolicLink(): Boolean = Files.isSymbolicLink(toPath())

    companion object {
        const val ENGINE_REVISION = "moonlight-android-12.2-larenor-embed-v3"
        const val PROVIDER = "moonlight-nvhttp"
        private const val MAX_CANDIDATES = 64
        private const val MAX_APPS = 256
        internal const val MAX_PAIRING_DURATION_MILLIS = 5 * 60 * 1_000L
        private const val COMMAND_TIMEOUT_MS = 30_000L
        private const val WAKE_READBACK_ATTEMPTS = 15
        private const val WAKE_READBACK_INTERVAL_MS = 1_000L
    }
}

internal data class MoonlightAuthorityRetirementReceipt(
    val requestId: String,
    val authorityId: String,
    val authorityEpoch: Long,
    internal val authorityFingerprint: String,
    val nativeBindingId: String,
    val bindingRevision: Long,
) {
    init {
        requireIdentity(requestId, "request_id")
        requireIdentity(authorityId, "authority_id")
        requireRevision(authorityEpoch, "revision")
        require(Regex("^[0-9a-f]{64}$").matches(authorityFingerprint))
        requireIdentity(nativeBindingId, "candidate")
        requireRevision(bindingRevision, "revision")
    }
}

internal interface MoonlightAuthorityRetirementPersistence {
    fun read(requestId: String): MoonlightAuthorityRetirementReceipt?
    fun save(receipt: MoonlightAuthorityRetirementReceipt)
    fun containsAuthority(authorityFingerprint: String): Boolean
}

private class MoonlightAuthorityRetirementStore(
    private val file: File,
) : MoonlightAuthorityRetirementPersistence {
    private val atomic = AtomicFile(file)

    @Synchronized
    override fun read(requestId: String): MoonlightAuthorityRetirementReceipt? {
        requireIdentity(requestId, "request_id")
        return load().singleOrNull { it.requestId == requestId }
    }

    @Synchronized
    override fun containsAuthority(authorityFingerprint: String): Boolean {
        if (!Regex("^[0-9a-f]{64}$").matches(authorityFingerprint)) {
            throw MoonlightRuntimeFailure("invalid_receipt")
        }
        return load().any { it.authorityFingerprint == authorityFingerprint }
    }

    @Synchronized
    override fun save(receipt: MoonlightAuthorityRetirementReceipt) {
        val values = load().toMutableList()
        values.singleOrNull { it.requestId == receipt.requestId }?.let {
            if (it != receipt) throw MoonlightRuntimeFailure("invalid_receipt")
            return
        }
        if (values.any {
                it.nativeBindingId == receipt.nativeBindingId && it.bindingRevision == receipt.bindingRevision
            }
        ) throw MoonlightRuntimeFailure("invalid_receipt")
        if (values.size >= MAX_AUTHORITY_RETIREMENTS) throw MoonlightRuntimeFailure("busy")
        values += receipt
        write(values)
    }

    private fun load(): List<MoonlightAuthorityRetirementReceipt> {
        if (!file.exists()) return emptyList()
        if (!file.isFile || file.isSymbolicLink() || file.length() !in 1..MAX_RETIREMENT_BYTES) {
            throw MoonlightRuntimeFailure("invalid_receipt")
        }
        return try {
            val root = JSONObject(String(atomic.readFully(), StandardCharsets.UTF_8))
            if (root.keys().asSequence().toSet() != setOf("schemaVersion", "receipts") ||
                root.getInt("schemaVersion") != 1
            ) throw MoonlightRuntimeFailure("invalid_receipt")
            val receipts = root.getJSONArray("receipts")
            if (receipts.length() > MAX_AUTHORITY_RETIREMENTS) {
                throw MoonlightRuntimeFailure("invalid_receipt")
            }
            (0 until receipts.length()).map { index ->
                receipts.getJSONObject(index).let { value ->
                    if (value.keys().asSequence().toSet() != setOf(
                            "requestId", "authorityId", "authorityEpoch", "authorityFingerprint",
                            "nativeBindingId", "bindingRevision",
                        )
                    ) throw MoonlightRuntimeFailure("invalid_receipt")
                    MoonlightAuthorityRetirementReceipt(
                        requestId = value.getString("requestId"),
                        authorityId = value.getString("authorityId"),
                        authorityEpoch = value.getLong("authorityEpoch"),
                        authorityFingerprint = value.getString("authorityFingerprint"),
                        nativeBindingId = value.getString("nativeBindingId"),
                        bindingRevision = value.getLong("bindingRevision"),
                    )
                }
            }.also { decoded ->
                if (decoded.map { it.requestId }.distinct().size != decoded.size ||
                    decoded.map { it.nativeBindingId to it.bindingRevision }.distinct().size != decoded.size
                ) throw MoonlightRuntimeFailure("invalid_receipt")
            }
        } catch (failure: MoonlightRuntimeFailure) {
            throw failure
        } catch (_: Exception) {
            throw MoonlightRuntimeFailure("invalid_receipt")
        }
    }

    private fun write(values: List<MoonlightAuthorityRetirementReceipt>) {
        val root = JSONObject().put("schemaVersion", 1).put("receipts", JSONArray().also { array ->
            values.forEach { value ->
                array.put(JSONObject()
                    .put("requestId", value.requestId)
                    .put("authorityId", value.authorityId)
                    .put("authorityEpoch", value.authorityEpoch)
                    .put("authorityFingerprint", value.authorityFingerprint)
                    .put("nativeBindingId", value.nativeBindingId)
                    .put("bindingRevision", value.bindingRevision))
            }
        })
        val bytes = root.toString().toByteArray(StandardCharsets.UTF_8)
        if (bytes.size > MAX_RETIREMENT_BYTES) throw MoonlightRuntimeFailure("busy")
        file.parentFile?.let { parent ->
            if ((!parent.isDirectory && !parent.mkdirs()) || parent.isSymbolicLink()) {
                throw MoonlightRuntimeFailure("invalid_receipt")
            }
        }
        val output = try { atomic.startWrite() } catch (_: Exception) {
            throw MoonlightRuntimeFailure("unknown_effect")
        }
        try {
            output.write(bytes)
            output.fd.sync()
            atomic.finishWrite(output)
        } catch (_: Exception) {
            atomic.failWrite(output)
            throw MoonlightRuntimeFailure("unknown_effect")
        }
    }

    private fun File.isSymbolicLink(): Boolean = Files.isSymbolicLink(toPath())

    companion object {
        private const val MAX_AUTHORITY_RETIREMENTS = 1024
        private const val MAX_RETIREMENT_BYTES = 512 * 1024L
    }
}

/** Byte-for-byte Python json.dumps(separators=(",", ":"), sort_keys=True). */
internal fun canonicalCatalogDigest(apps: List<MoonlightObservedApp>): String {
    val canonical = apps.joinToString(prefix = "[", postfix = "]", separator = ",") { app ->
        "{\"name\":${pythonJsonString(app.name)},\"observationId\":\"${app.observationId}\",\"revision\":${app.revision}}"
    }
    return sha256(canonical.toByteArray(Charsets.UTF_8)).hex()
}

internal fun <T> requireBoundedCatalog(items: List<T>, maximum: Int): List<T> {
    if (maximum < 0 || items.size > maximum) throw MoonlightRuntimeFailure("provider_unavailable")
    return items
}

private fun pythonJsonString(value: String): String = buildString(value.length + 2) {
    append('"')
    value.forEach { character ->
        when (character) {
            '"' -> append("\\\"")
            '\\' -> append("\\\\")
            '\b' -> append("\\b")
            '\u000c' -> append("\\f")
            '\n' -> append("\\n")
            '\r' -> append("\\r")
            '\t' -> append("\\t")
            else -> if (character.code < 0x20 || character.code > 0x7f) {
                append("\\u")
                append(character.code.toString(16).padStart(4, '0'))
            } else append(character)
        }
    }
    append('"')
}
