package com.ersingundem.larenor.game.moonlight

import android.app.Activity
import org.json.JSONObject
import java.util.function.Consumer

class MoonlightMethodChannelHost(activity: Activity) : AutoCloseable {
    private val runtime = MoonlightEmbeddedRuntime(activity)
    @Volatile private var resumed = false
    @Volatile private var focused = false

    fun handle(
        method: String,
        rawArguments: Any?,
        success: Consumer<Any?>,
        error: Consumer<String>,
    ): Boolean {
        if (method !in METHODS) return false
        try {
            if (method == "capabilities") {
                if (rawArguments != null) fail("invalid_receipt")
                Class.forName("com.limelight.nvstream.jni.MoonBridge", true, javaClass.classLoader)
                success.accept(linkedMapOf(
                    "schemaVersion" to 1, "availability" to "available",
                    "engineRevision" to MoonlightEmbeddedRuntime.ENGINE_REVISION,
                    "intents" to listOf("wake", "launch", "stream", "stop"), "maxInflight" to 1,
                    "provider" to MoonlightEmbeddedRuntime.PROVIDER, "handoffOnly" to false,
                    "inputKinds" to emptyList<String>(),
                ))
                return true
            }
            if (method in INTERACTIVE_METHODS) {
                requireInteractive(allowOwnedGame = method == "executeV2")
            }
            val args = exactMap(rawArguments)
            when (method) {
                "beginPairingV2" -> beginPairing(args, success, error)
                "pairHostV2" -> pair(args, success, error)
                "commitRegistrationV2" -> success.accept(commitRegistration(args))
                "resolveHostBindingV2" -> success.accept(resolveHostBinding(args))
                "readCatalogV2" -> readCatalog(args, success, error)
                "resolveBindingV2" -> success.accept(resolveBinding(args))
                "configureStreamPolicyV2" -> success.accept(configurePolicy(args))
                "sessionCapabilitiesV2" -> success.accept(sessionCapabilities(args))
                "bindSessionV2" -> success.accept(bindSession(args))
                "foregroundLeaseV2" -> success.accept(foregroundLease(args))
                "pairingPromptV2" -> success.accept(pairingPrompt(args))
                "executeV2" -> execute(args, success, error)
                "reconcileV2" -> success.accept(reconcile(args))
                "revokePairingV2" -> revoke(args, success, error)
                "retireAuthorityV2" -> success.accept(retireAuthority(args))
                "retire" -> success.accept(retire(args))
                else -> error.accept("engine_unavailable")
            }
        } catch (failure: Throwable) {
            error.accept((failure as? MoonlightRuntimeFailure)?.code ?: "provider_unavailable")
        }
        return true
    }

    override fun close() = runtime.close()

    fun dispose() = close()

    fun setResumed(resumed: Boolean) {
        this.resumed = resumed
        if (!resumed && !runtime.ownsForegroundLease()) runtime.retireCurrentAuthority()
    }

    fun setWindowFocused(focused: Boolean) {
        this.focused = focused
        if (!focused && !runtime.ownsForegroundLease() && !runtime.ownsPairingPrompt()) {
            runtime.retireCurrentAuthority()
        }
    }

    fun ownsForegroundLease(authorityId: String, epoch: Long): Boolean =
        MoonlightForegroundLeaseRegistry.ownsHostCover(authorityId, epoch)

    private fun beginPairing(
        args: Map<String, Any?>,
        success: Consumer<Any?>,
        error: Consumer<String>,
    ) {
        requireInteractive(allowOwnedGame = false)
        requireKeys(args, "schemaVersion", "requestId", "authority", "timeoutMs")
        schema(args)
        val requestId = id(args, "requestId")
        val authority = authority(args["authority"])
        val binding = runtime.bindAuthority(authority)
        runtime.discover(authority, requestId, integer(args, "timeoutMs", 1_000, 120_000).toLong()) { outcome ->
            outcome.fold(
                onSuccess = { candidates ->
                    val digest = sha256(candidates.joinToString("\u0000") {
                        "${it.candidateId}:${it.candidateRevision}:${it.hostIdentityDigest}"
                    }.toByteArray()).hex()
                    success.accept(linkedMapOf(
                        "schemaVersion" to 2,
                        "requestId" to requestId,
                        "nativeBindingId" to binding.first,
                        "bindingRevision" to binding.second,
                        "engineRevision" to MoonlightEmbeddedRuntime.ENGINE_REVISION,
                        "provider" to MoonlightEmbeddedRuntime.PROVIDER,
                        "catalogRevision" to publicRevision(digest),
                        "catalogDigest" to digest,
                        "candidates" to candidates.map { candidate -> linkedMapOf(
                            "candidateId" to candidate.candidateId,
                            "revision" to candidate.candidateRevision,
                            "name" to candidate.displayName.take(80),
                            "powerState" to candidate.powerState,
                            "pairState" to candidate.pairState,
                        ) },
                    ))
                },
                onFailure = { error.accept(publicCode(it)) },
            )
        }
    }

    private fun pair(
        args: Map<String, Any?>,
        success: Consumer<Any?>,
        error: Consumer<String>,
    ) {
        requireInteractive(allowOwnedGame = false)
        requireKeys(
            args, "schemaVersion", "requestId", "authority", "nativeBindingId",
            "expectedBindingRevision", "pairingId", "expectedPairingRevision",
            "pairingGrant", "expiresAt", "candidateId", "expectedCandidateRevision",
        )
        schema(args)
        val authority = authority(args["authority"])
        binding(args, authority)
        val requestId = id(args, "requestId")
        val authorization = MoonlightPairAuthorization(
            requestId = requestId,
            pairingId = id(args, "pairingId"),
            expectedPairingRevision = revision(args, "expectedPairingRevision"),
            pairingGrant = id(args, "pairingGrant"),
            expiresAtEpochSeconds = finiteDouble(args, "expiresAt"),
        )
        runtime.pair(
            authority, authorization, id(args, "candidateId"),
            revision(args, "expectedCandidateRevision"),
        ) { outcome ->
            outcome.fold(
                onSuccess = { receipt -> success.accept(pairReceipt(authorization.pairingId, receipt)) },
                onFailure = { error.accept(publicCode(it)) },
            )
        }
    }

    private fun commitRegistration(args: Map<String, Any?>): Map<String, Any?> {
        requireInteractive(allowOwnedGame = false)
        requireKeys(
            args, "schemaVersion", "requestId", "authority", "nativeBindingId",
            "expectedBindingRevision", "nativeReceiptId", "host", "apps",
        )
        schema(args)
        val authority = authority(args["authority"])
        binding(args, authority)
        val host = exactMap(args["host"])
        requireKeys(host, "id", "revision", "pairingRevision", "catalogRevision")
        val rawApps = list(args, "apps", 0, 256)
        val apps = rawApps.associate { raw ->
            val app = exactMap(raw)
            requireKeys(app, "entryIndex", "id", "revision")
            integer(app, "entryIndex", 0, 255) to
                (id(app, "id") to revision(app, "revision"))
        }
        if (apps.size != rawApps.size) fail("invalid_receipt")
        val registration = MoonlightCoreRegistration(
            nativeReceiptId = id(args, "nativeReceiptId"),
            registrationRevision = publicRevision(
                id(args, "nativeReceiptId"), id(host, "id"),
                apps.toSortedMap().entries.joinToString { "${it.key}:${it.value.first}:${it.value.second}" },
            ),
            hostId = id(host, "id"),
            hostRevision = revision(host, "revision"),
            pairingRevision = revision(host, "pairingRevision"),
            catalogRevision = revision(host, "catalogRevision"),
            apps = apps,
        )
        runtime.commitRegistration(authority, registration)
        val digest = sha256(
            "${registration.nativeReceiptId}\u0000${registration.registrationRevision}".toByteArray(),
        ).hex()
        return linkedMapOf(
            "schemaVersion" to 2,
            "requestId" to id(args, "requestId"),
            "registrationRevision" to registration.registrationRevision,
            "hostId" to registration.hostId,
            "appIds" to apps.values.map { it.first }.sorted(),
            "nativeReceiptDigest" to digest,
        )
    }

    private fun resolveBinding(args: Map<String, Any?>): Map<String, Any?> {
        requireKeys(
            args, "schemaVersion", "requestId", "authority", "hostId", "expectedHostRevision",
            "expectedPairingRevision", "expectedCatalogRevision", "appId", "expectedAppRevision",
        )
        schema(args)
        val authority = authority(args["authority"])
        val binding = runtime.bindAuthority(authority)
        val resolved = runtime.resolveBinding(
            authority, id(args, "hostId"), revision(args, "expectedHostRevision"),
            revision(args, "expectedPairingRevision"), revision(args, "expectedCatalogRevision"),
            id(args, "appId"), revision(args, "expectedAppRevision"),
        )
        return linkedMapOf(
            "schemaVersion" to 2,
            "requestId" to id(args, "requestId"),
            "nativeBindingId" to binding.first,
            "bindingRevision" to binding.second,
            "registrationRevision" to resolved,
            "hostId" to id(args, "hostId"),
            "appId" to id(args, "appId"),
            "engineRevision" to MoonlightEmbeddedRuntime.ENGINE_REVISION,
        )
    }

    private fun resolveHostBinding(args: Map<String, Any?>): Map<String, Any?> {
        requireKeys(
            args, "schemaVersion", "requestId", "authority", "hostId", "expectedHostRevision",
            "expectedPairingRevision", "expectedCatalogRevision",
        )
        schema(args)
        val authority = authority(args["authority"])
        val binding = runtime.bindAuthority(authority)
        val registrationRevision = runtime.resolveHostBinding(
            authority, id(args, "hostId"), revision(args, "expectedHostRevision"),
            revision(args, "expectedPairingRevision"), revision(args, "expectedCatalogRevision"),
        )
        return linkedMapOf(
            "schemaVersion" to 2, "requestId" to id(args, "requestId"),
            "nativeBindingId" to binding.first, "bindingRevision" to binding.second,
            "registrationRevision" to registrationRevision, "hostId" to id(args, "hostId"),
            "engineRevision" to MoonlightEmbeddedRuntime.ENGINE_REVISION,
        )
    }

    private fun readCatalog(
        args: Map<String, Any?>,
        success: Consumer<Any?>,
        error: Consumer<String>,
    ) {
        requireInteractive(allowOwnedGame = false)
        requireKeys(
            args, "schemaVersion", "requestId", "authority", "nativeBindingId",
            "expectedBindingRevision", "hostId", "expectedHostRevision", "expectedPairingRevision",
            "expectedCatalogRevision", "catalogObservationId", "expectedObservationRevision",
            "catalogGrant", "expiresAt",
        )
        schema(args)
        val authority = authority(args["authority"])
        binding(args, authority)
        val authorization = MoonlightCatalogAuthorization(
            requestId = id(args, "requestId"),
            catalogObservationId = id(args, "catalogObservationId"),
            expectedObservationRevision = revision(args, "expectedObservationRevision"),
            expectedCatalogRevision = revision(args, "expectedCatalogRevision"),
            catalogGrant = id(args, "catalogGrant"),
            expiresAtEpochSeconds = finiteDouble(args, "expiresAt"),
        )
        runtime.readCatalog(
            authority, authorization, id(args, "hostId"), revision(args, "expectedHostRevision"),
            revision(args, "expectedPairingRevision"),
        ) { outcome ->
            outcome.fold(
                onSuccess = { receipt -> success.accept(linkedMapOf(
                    "schemaVersion" to 2,
                    "requestId" to receipt.requestId,
                    "catalogObservationId" to receipt.catalogObservationId,
                    "state" to receipt.state,
                    "nativeReceiptDigest" to receipt.nativeReceiptDigest,
                    "observation" to receipt.nativeObservationJson?.let { jsonObject(JSONObject(it)) },
                )) },
                onFailure = { error.accept(publicCode(it)) },
            )
        }
    }

    private fun configurePolicy(args: Map<String, Any?>): Map<String, Any?> {
        requireInteractive(allowOwnedGame = false)
        requireKeys(args, "schemaVersion", "requestId", "authority", "expectedPolicyRevision", "policy")
        schema(args)
        val authority = authority(args["authority"])
        runtime.bindAuthority(authority)
        val raw = exactMap(args["policy"])
        requireKeys(
            raw, "allowedCodecs", "allowMetered", "requirePin", "maxWidth", "maxHeight", "maxFps",
            "maxBitrateKbps", "maximumIdleSeconds", "maximumSessionSeconds", "frameQueueDepth",
            "inputQueueDepth",
        )
        val codecs = list(raw, "allowedCodecs", 1, 3).map {
            it as? String ?: fail("invalid_receipt")
        }.toSet()
        val requested = MoonlightStreamPolicy(
            policyId = "0".repeat(32), policyRevision = 0, allowedCodecs = codecs,
            allowMetered = boolean(raw, "allowMetered"), requirePin = boolean(raw, "requirePin"),
            maxWidth = integer(raw, "maxWidth", 320, 8192),
            maxHeight = integer(raw, "maxHeight", 320, 8192),
            maxFramesPerSecond = integer(raw, "maxFps", 24, 240),
            maxBitrateKbps = integer(raw, "maxBitrateKbps", 2_000, 100_000),
            maximumIdleSeconds = integer(raw, "maximumIdleSeconds", 30, 3_600),
            maximumSessionSeconds = integer(raw, "maximumSessionSeconds", 60, 3_600),
            frameQueueDepth = integer(raw, "frameQueueDepth", 1, 3),
            inputQueueDepth = integer(raw, "inputQueueDepth", 1, 32),
        )
        val saved = runtime.configurePolicy(authority, revisionAllowZero(args, "expectedPolicyRevision"), requested)
        return linkedMapOf(
            "schemaVersion" to 2, "requestId" to id(args, "requestId"),
            "policyId" to saved.policyId, "policyRevision" to saved.policyRevision,
        )
    }

    private fun sessionCapabilities(args: Map<String, Any?>): Map<String, Any?> {
        requireInteractive(allowOwnedGame = false)
        requireKeys(
            args, "schemaVersion", "requestId", "authority", "hostId", "expectedHostRevision",
            "expectedPairingRevision", "expectedCatalogRevision", "appId", "expectedAppRevision",
        )
        schema(args)
        val authority = authority(args["authority"])
        runtime.bindAuthority(authority)
        val observed = runtime.sessionCapabilities(
            authority, id(args, "hostId"), revision(args, "expectedHostRevision"),
            revision(args, "expectedPairingRevision"), revision(args, "expectedCatalogRevision"),
            id(args, "appId"), revision(args, "expectedAppRevision"),
        )
        return linkedMapOf(
            "schemaVersion" to 2, "requestId" to id(args, "requestId"),
            "availability" to observed.availability, "reason" to observed.reason,
            "display" to observed.display?.wire(), "network" to observed.network?.wire(),
            "decoders" to observed.decoders.map { it.wire() },
            "policy" to observed.policy?.wire(),
            "qualityOptions" to observed.qualityOptions.map { it.wire() },
        )
    }

    private fun revoke(
        args: Map<String, Any?>,
        success: Consumer<Any?>,
        error: Consumer<String>,
    ) {
        requireInteractive(allowOwnedGame = false)
        requireKeys(
            args, "schemaVersion", "requestId", "authority", "revocationId", "hostId",
            "expectedHostRevision", "expectedPairingRevision", "expectedCatalogRevision",
        )
        schema(args)
        val authority = authority(args["authority"])
        runtime.bindAuthority(authority)
        val requestId = id(args, "requestId")
        val revocationId = id(args, "revocationId")
        runtime.revoke(
            authority, requestId, revocationId, id(args, "hostId"),
            revision(args, "expectedHostRevision"), revision(args, "expectedPairingRevision"),
            revision(args, "expectedCatalogRevision"),
        ) { outcome ->
            outcome.fold(
                onSuccess = { receipt -> success.accept(revokeReceipt(revocationId, receipt)) },
                onFailure = { error.accept(publicCode(it)) },
            )
        }
    }

    private fun bindSession(args: Map<String, Any?>): Any? {
        requireInteractive(allowOwnedGame = false)
        requireKeys(
            args, "schemaVersion", "authority", "nativeBindingId", "expectedBindingRevision",
            "registrationRevision", "sessionId", "sessionRevision", "hostId", "hostRevision",
            "pairingRevision", "catalogRevision", "appId", "appRevision", "expiresAt",
            "selectedQuality",
        )
        schema(args)
        val authority = authority(args["authority"])
        binding(args, authority)
        val selected = selectedQuality(exactMap(args["selectedQuality"]))
        val session = MoonlightBoundSession(
            sessionId = id(args, "sessionId"),
            sessionRevision = revision(args, "sessionRevision"),
            hostId = id(args, "hostId"),
            hostRevision = revision(args, "hostRevision"),
            pairingRevision = revision(args, "pairingRevision"),
            catalogRevision = revision(args, "catalogRevision"),
            appId = id(args, "appId"),
            appRevision = revision(args, "appRevision"),
            expiresAtEpochSeconds = finiteDouble(args, "expiresAt"),
            selectedQuality = selected,
        )
        val registration = runtime.resolveBinding(
            authority, session.hostId, session.hostRevision, session.pairingRevision,
            session.catalogRevision, session.appId, session.appRevision,
        )
        if (registration != revision(args, "registrationRevision")) fail("authority_changed")
        runtime.bindSession(authority, session)
        return null
    }

    private fun execute(
        args: Map<String, Any?>,
        success: Consumer<Any?>,
        error: Consumer<String>,
    ) {
        requireInteractive(allowOwnedGame = true)
        val command = exactMap(args["command"])
        requireKeys(command, "id", "intent")
        val intent = text(command, "intent", 16)
        if (intent == "stop") {
            requireKeys(
                args, "schemaVersion", "requestId", "authority", "sessionId",
                "expectedSessionRevision", "command", "dispatchGrant", "safetyClosure",
            )
        } else {
            requireKeys(
                args, "schemaVersion", "requestId", "authority", "sessionId",
                "expectedSessionRevision", "command", "dispatchGrant",
            )
        }
        schema(args)
        val authority = authority(args["authority"])
        val requestId = id(args, "requestId")
        if (intent == "stop") {
            val closure = exactMap(args["safetyClosure"])
            requireKeys(closure, "nativeBindingId", "bindingRevision")
            runtime.executeSafetyStop(
                authority,
                id(closure, "nativeBindingId"), revision(closure, "bindingRevision"),
                requestId, id(args, "sessionId"), revision(args, "expectedSessionRevision"),
                id(command, "id"), id(args, "dispatchGrant"),
            ) { outcome ->
                outcome.fold(
                    onSuccess = { success.accept(commandReceipt(it)) },
                    onFailure = { error.accept(publicCode(it)) },
                )
            }
            return
        }
        runtime.bindAuthority(authority)
        runtime.executeCommand(
            authority, requestId, id(args, "sessionId"), revision(args, "expectedSessionRevision"),
            id(command, "id"), intent, id(args, "dispatchGrant"),
        ) { outcome ->
            outcome.fold(
                onSuccess = { success.accept(commandReceipt(it)) },
                onFailure = { error.accept(publicCode(it)) },
            )
        }
    }

    private fun foregroundLease(args: Map<String, Any?>): Map<String, Any?> {
        requireKeys(
            args, "schemaVersion", "requestId", "authority", "nativeBindingId",
            "expectedBindingRevision", "sessionId", "expectedSessionRevision",
        )
        schema(args)
        val expected = authority(args["authority"])
        val (binding, snapshot) = runtime.foregroundLease(
            expected,
            id(args, "nativeBindingId"),
            revision(args, "expectedBindingRevision"),
            id(args, "sessionId"),
            revision(args, "expectedSessionRevision"),
        )
        val state = when (snapshot?.state) {
            MoonlightLeaseState.TRANSFER_PENDING -> "transfer_pending"
            MoonlightLeaseState.GAME_VISIBLE -> "game_visible"
            else -> "unavailable"
        }
        return linkedMapOf(
            "schemaVersion" to 2,
            "requestId" to id(args, "requestId"),
            "nativeBindingId" to binding.first,
            "bindingRevision" to binding.second,
            "sessionId" to id(args, "sessionId"),
            "sessionRevision" to revision(args, "expectedSessionRevision"),
            "owned" to (snapshot != null),
            "state" to state,
        )
    }

    private fun pairingPrompt(args: Map<String, Any?>): Map<String, Any?> {
        requireKeys(
            args, "schemaVersion", "requestId", "authority", "nativeBindingId",
            "expectedBindingRevision", "pairingId", "expectedPairingRevision",
        )
        schema(args)
        val expected = authority(args["authority"])
        val pairingId = id(args, "pairingId")
        val pairingRevision = revision(args, "expectedPairingRevision")
        val (binding, owned) = runtime.pairingPrompt(
            expected,
            id(args, "nativeBindingId"),
            revision(args, "expectedBindingRevision"),
            pairingId,
            pairingRevision,
        )
        return linkedMapOf(
            "schemaVersion" to 2,
            "requestId" to id(args, "requestId"),
            "nativeBindingId" to binding.first,
            "bindingRevision" to binding.second,
            "pairingId" to pairingId,
            "pairingRevision" to pairingRevision,
            "owned" to owned,
            "state" to if (owned) "pairing_prompt" else "unavailable",
        )
    }

    private fun reconcile(args: Map<String, Any?>): Map<String, Any?> {
        requireKeys(args, "schemaVersion", "requestId", "authority", "operationKind", "operationId")
        schema(args)
        val requestId = id(args, "requestId")
        val authority = authority(args["authority"])
        runtime.bindAuthority(authority)
        val kind = text(args, "operationKind", 16)
        if (kind !in setOf("pair", "catalog", "command", "revoke")) fail("invalid_receipt")
        val operationId = id(args, "operationId")
        val receipt = runtime.reconcile(authority, requestId, kind, operationId)
        val wire = when (receipt) {
            null -> null
            is MoonlightPairReceipt -> pairReceipt(operationId, receipt)
            is MoonlightCatalogReceipt -> catalogReceipt(receipt)
            is MoonlightCommandReceipt -> commandReceipt(receipt)
            is MoonlightRevokeReceipt -> revokeReceipt(operationId, receipt)
            else -> fail("invalid_receipt")
        }
        return linkedMapOf(
            "schemaVersion" to 2, "requestId" to requestId, "operationKind" to kind,
            "terminal" to (wire != null), "receipt" to wire,
        )
    }

    private fun retire(args: Map<String, Any?>): Map<String, Any?> {
        requireKeys(args, "sessionId", "epoch")
        val sessionId = id(args, "sessionId")
        val epoch = revision(args, "epoch")
        runtime.retireExactSession(sessionId, epoch)
        return linkedMapOf(
            "schemaVersion" to 2,
            "sessionId" to sessionId,
            "epoch" to epoch,
            // This receipt proves that native authority is fenced. It is not
            // provider evidence; only connectionStopped or a remote
            // connectionTerminated observation proves a stop.
            "state" to "retired",
        )
    }

    private fun retireAuthority(args: Map<String, Any?>): Map<String, Any?> {
        requireKeys(
            args, "schemaVersion", "requestId", "authority", "nativeBindingId", "bindingRevision",
        )
        schema(args)
        val rawBindingId = args["nativeBindingId"]
        val rawBindingRevision = args["bindingRevision"]
        if ((rawBindingId == null) != (rawBindingRevision == null)) fail("invalid_receipt")
        val expectedBindingId = rawBindingId?.let {
            (it as? String)?.let { value -> requireIdentity(value, "candidate") }
                ?: fail("invalid_receipt")
        }
        val expectedBindingRevision = rawBindingRevision?.let {
            val number = it as? Number ?: fail("invalid_receipt")
            if (number.toDouble() != number.toLong().toDouble()) fail("invalid_receipt")
            requireRevision(number.toLong(), "revision")
        }
        val receipt = runtime.retireAuthority(
            authority(args["authority"]), id(args, "requestId"),
            expectedBindingId, expectedBindingRevision,
        )
        return linkedMapOf(
            "schemaVersion" to 2,
            "requestId" to receipt.requestId,
            "authorityId" to receipt.authorityId,
            "authorityEpoch" to receipt.authorityEpoch,
            "nativeBindingId" to receipt.nativeBindingId,
            "bindingRevision" to receipt.bindingRevision,
            "state" to "retired",
        )
    }

    private fun binding(args: Map<String, Any?>, authority: MoonlightAuthority) {
        val current = runtime.bindAuthority(authority)
        if (id(args, "nativeBindingId") != current.first ||
            revision(args, "expectedBindingRevision") != current.second
        ) fail("authority_changed")
    }

    private fun requireInteractive(allowOwnedGame: Boolean) {
        if (resumed && focused) return
        if (allowOwnedGame && runtime.ownsForegroundLease()) return
        throw MoonlightRuntimeFailure("foreground_required")
    }

    companion object {
        private val METHODS = setOf(
            "capabilities", "beginPairingV2", "pairHostV2", "commitRegistrationV2", "resolveHostBindingV2",
            "readCatalogV2", "resolveBindingV2",
            "configureStreamPolicyV2", "sessionCapabilitiesV2", "bindSessionV2", "executeV2",
            "foregroundLeaseV2", "pairingPromptV2", "reconcileV2", "revokePairingV2", "retire",
            "retireAuthorityV2",
        )
        private val INTERACTIVE_METHODS = METHODS -
            setOf(
                "capabilities", "foregroundLeaseV2", "pairingPromptV2", "reconcileV2",
                "retireAuthorityV2", "retire",
            )
    }
}

private fun authority(raw: Any?): MoonlightAuthority {
    val value = exactMap(raw)
    requireKeys(
        value, "coreId", "homeId", "accountId", "familyId", "accountRevision", "pinRevision",
        "pinConfigured", "pinUnlocked", "clientInstanceId",
        "routeRevision", "lifecycleRevision", "idleRevision", "interactionRevision",
    )
    val scope = MoonlightScope(
        id(value, "coreId"), id(value, "homeId"), id(value, "accountId"), id(value, "familyId"),
    )
    val revisions = listOf(
        revision(value, "accountRevision"), revision(value, "pinRevision"),
        revision(value, "routeRevision"), revision(value, "lifecycleRevision"),
        revision(value, "idleRevision"), revision(value, "interactionRevision"),
    )
    val clientInstanceId = id(value, "clientInstanceId")
    return MoonlightAuthority(
        authorityId = sha256(
            "authority\u0000${scope.storageKey}\u0000$clientInstanceId".toByteArray(),
        ).hex().take(32),
        epoch = publicRevision(
            *revisions.map(Long::toString).toTypedArray(),
            boolean(value, "pinConfigured").toString(), boolean(value, "pinUnlocked").toString(),
            clientInstanceId,
        ),
        scope = scope,
        clientInstanceId = clientInstanceId,
        accountRevision = revisions[0], pinRevision = revisions[1], routeRevision = revisions[2],
        pinConfigured = boolean(value, "pinConfigured"), pinUnlocked = boolean(value, "pinUnlocked"),
        lifecycleRevision = revisions[3], idleRevision = revisions[4], interactionRevision = revisions[5],
    )
}

private fun pairReceipt(pairingId: String, value: MoonlightPairReceipt): Map<String, Any?> = linkedMapOf(
    "schemaVersion" to 2, "requestId" to value.requestId, "pairingId" to pairingId,
    "state" to value.status, "nativeReceiptDigest" to value.nativeReceiptDigest,
    "observation" to value.nativeObservationJson?.let { jsonObject(JSONObject(it)) },
)

private fun catalogReceipt(value: MoonlightCatalogReceipt): Map<String, Any?> = linkedMapOf(
    "schemaVersion" to 2, "requestId" to value.requestId,
    "catalogObservationId" to value.catalogObservationId, "state" to value.state,
    "nativeReceiptDigest" to value.nativeReceiptDigest,
    "observation" to value.nativeObservationJson?.let { jsonObject(JSONObject(it)) },
)

private fun commandReceipt(value: MoonlightCommandReceipt): Map<String, Any?> = linkedMapOf(
    "schemaVersion" to 2, "requestId" to value.requestId, "sessionId" to value.sessionId,
    "commandId" to value.commandId, "state" to value.state, "result" to value.result,
    "observationKind" to value.observationKind, "readbackRevision" to value.readbackRevision,
    "nativeReceiptDigest" to value.nativeReceiptDigest,
)

private fun revokeReceipt(
    revocationId: String,
    value: MoonlightRevokeReceipt,
): Map<String, Any?> {
    val revision = value.readbackRevision
    return linkedMapOf(
        "schemaVersion" to 2, "requestId" to value.requestId, "revocationId" to revocationId,
        "state" to if (value.status == "revoked") "local_cleared" else "unknown",
        "readbackRevision" to revision,
        "nativeReceiptDigest" to if (value.status == "revoked" && revision != null) sha256(
            "$revocationId\u0000${value.status}\u0000$revision".toByteArray(),
        ).hex() else null,
    )
}

private fun selectedQuality(value: Map<String, Any?>): MoonlightSelectedQuality {
    requireKeys(
        value, "codec", "codecId", "codecRevision", "displayId", "displayRevision",
        "networkId", "networkRevision", "policyId", "policyRevision", "widthPixels",
        "heightPixels", "framesPerSecond", "bitrateKbps", "frameQueueDepth",
        "inputQueueDepth", "secureSurface",
    )
    return MoonlightSelectedQuality(
        codec = text(value, "codec", 8), codecId = id(value, "codecId"),
        codecRevision = revision(value, "codecRevision"), displayId = integer(value, "displayId", 0, 63),
        displayRevision = revision(value, "displayRevision"), networkId = id(value, "networkId"),
        networkRevision = revision(value, "networkRevision"), policyId = id(value, "policyId"),
        policyRevision = revision(value, "policyRevision"),
        widthPixels = integer(value, "widthPixels", 320, 8192),
        heightPixels = integer(value, "heightPixels", 320, 8192),
        framesPerSecond = integer(value, "framesPerSecond", 24, 240),
        bitrateKbps = integer(value, "bitrateKbps", 2_000, 100_000),
        frameQueueDepth = integer(value, "frameQueueDepth", 1, 3),
        inputQueueDepth = integer(value, "inputQueueDepth", 1, 32),
        secureSurface = boolean(value, "secureSurface"),
    )
}

private fun MoonlightDisplayObservation.wire() = linkedMapOf(
    "displayId" to displayId, "displayRevision" to displayRevision, "attached" to attached,
    "widthPixels" to widthPixels, "heightPixels" to heightPixels, "densityDpi" to densityDpi,
    "secureSurface" to secureSurface, "maxRefreshRate" to maxRefreshRate,
)
private fun MoonlightNetworkObservation.wire() = linkedMapOf(
    "networkId" to networkId, "networkRevision" to networkRevision,
    "reachability" to reachability, "metered" to metered,
)
private fun MoonlightDecoderObservation.wire() = linkedMapOf(
    "codecId" to codecId, "codecRevision" to codecRevision, "codec" to codec,
    "supported" to supported, "maxWidthPixels" to maxWidthPixels,
    "maxHeightPixels" to maxHeightPixels, "maxFramesPerSecond" to maxFramesPerSecond,
)
private fun MoonlightStreamPolicy.wire() = linkedMapOf(
    "policyId" to policyId, "policyRevision" to policyRevision,
    "allowedCodecIds" to allowedCodecs.sorted(), "allowMetered" to allowMetered,
    "requirePin" to requirePin, "maxWidth" to maxWidth, "maxHeight" to maxHeight,
    "maxFps" to maxFramesPerSecond, "maxBitrateKbps" to maxBitrateKbps,
    "maximumIdleSeconds" to maximumIdleSeconds, "maximumSessionSeconds" to maximumSessionSeconds,
    "frameQueueDepth" to frameQueueDepth, "inputQueueDepth" to inputQueueDepth,
)
private fun MoonlightQualityOption.wire() = linkedMapOf(
    "codec" to codec, "codecId" to codecId, "codecRevision" to codecRevision,
    "displayId" to displayId, "displayRevision" to displayRevision,
    "networkId" to networkId, "networkRevision" to networkRevision,
    "policyId" to policyId, "policyRevision" to policyRevision,
    "widthPixels" to widthPixels, "heightPixels" to heightPixels,
    "framesPerSecond" to framesPerSecond, "bitrateKbps" to bitrateKbps,
    "frameQueueDepth" to frameQueueDepth, "inputQueueDepth" to inputQueueDepth,
    "secureSurface" to secureSurface,
)

private fun jsonObject(value: JSONObject): Map<String, Any?> = value.keys().asSequence().associateWith { key ->
    when (val item = value.get(key)) {
        JSONObject.NULL -> null
        is JSONObject -> jsonObject(item)
        is org.json.JSONArray -> (0 until item.length()).map { index ->
            when (val nested = item.get(index)) { is JSONObject -> jsonObject(nested); else -> nested }
        }
        else -> item
    }
}

private fun exactMap(value: Any?): Map<String, Any?> = when (value) {
    is Map<*, *> -> value.entries.associate { entry ->
        (entry.key as? String ?: fail("invalid_receipt")) to entry.value
    }
    else -> fail("invalid_receipt")
}
private fun requireKeys(value: Map<String, Any?>, vararg keys: String) {
    if (value.keys != keys.toSet()) fail("invalid_receipt")
}
private fun schema(value: Map<String, Any?>) {
    if (integer(value, "schemaVersion", 2, 2) != 2) fail("invalid_receipt")
}
private fun id(value: Map<String, Any?>, key: String): String =
    requireIdentity(value[key] as? String ?: fail("invalid_receipt"), "candidate")
private fun revision(value: Map<String, Any?>, key: String): Long =
    requireRevision(number(value[key]), "revision").also { if (it == 0L) fail("invalid_revision") }
private fun revisionAllowZero(value: Map<String, Any?>, key: String): Long =
    requireRevision(number(value[key]), "revision")
private fun integer(value: Map<String, Any?>, key: String, minimum: Int, maximum: Int): Int {
    val number = number(value[key])
    if (number !in minimum.toLong()..maximum.toLong()) fail("invalid_receipt")
    return number.toInt()
}
private fun number(value: Any?): Long = when (value) {
    is Byte -> value.toLong(); is Short -> value.toLong(); is Int -> value.toLong(); is Long -> value
    else -> fail("invalid_receipt")
}
private fun finiteDouble(value: Map<String, Any?>, key: String): Double {
    val result = (value[key] as? Number)?.toDouble() ?: fail("invalid_receipt")
    if (!result.isFinite() || result <= 0.0) fail("invalid_receipt")
    return result
}
private fun boolean(value: Map<String, Any?>, key: String): Boolean =
    value[key] as? Boolean ?: fail("invalid_receipt")
private fun text(value: Map<String, Any?>, key: String, maximum: Int): String {
    val result = value[key] as? String ?: fail("invalid_receipt")
    if (result.isBlank() || result.length > maximum) fail("invalid_receipt")
    return result
}
private fun list(value: Map<String, Any?>, key: String, minimum: Int, maximum: Int): List<Any?> {
    val result = value[key] as? List<*> ?: fail("invalid_receipt")
    if (result.size !in minimum..maximum) fail("invalid_receipt")
    return result
}
private fun publicCode(value: Throwable): String =
    (value as? MoonlightRuntimeFailure)?.code ?: "provider_unavailable"
private fun fail(code: String): Nothing = throw MoonlightRuntimeFailure(code)
