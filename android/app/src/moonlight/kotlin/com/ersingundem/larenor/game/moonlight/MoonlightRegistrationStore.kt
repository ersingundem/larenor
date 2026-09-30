package com.ersingundem.larenor.game.moonlight

import android.util.AtomicFile
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.nio.charset.StandardCharsets
import java.nio.file.Files

data class MoonlightObservedApp(
    val entryIndex: Int,
    val observationId: String,
    val revision: Long,
    val name: String,
    internal val upstreamAppId: Int,
    val hdrSupported: Boolean,
) {
    init {
        require(entryIndex in 0..255)
        requireIdentity(observationId, "candidate")
        requireRevision(revision, "revision")
        require(name.isNotBlank() && name.length <= 160)
        require(upstreamAppId >= 0)
    }
}

data class MoonlightNativePairing(
    val receiptId: String,
    val nativeBindingId: String,
    val bindingRevision: Long,
    val hostObservationId: String,
    internal val upstreamHostUuid: String,
    val pairingRevision: Long,
    val catalogRevision: Long,
    val catalogDigest: String,
    val apps: List<MoonlightObservedApp>,
    val observationJson: String,
) {
    init {
        requireIdentity(receiptId, "candidate")
        requireIdentity(nativeBindingId, "candidate")
        requireRevision(bindingRevision, "revision")
        requireIdentity(hostObservationId, "candidate")
        require(upstreamHostUuid.isNotBlank() && upstreamHostUuid.length <= 128)
        requireRevision(pairingRevision, "pairing_revision")
        requireRevision(catalogRevision, "revision")
        require(Regex("^[0-9a-f]{64}$").matches(catalogDigest))
        require(apps.size <= 256 && apps.map { it.entryIndex }.distinct().size == apps.size)
        require(observationJson.toByteArray(StandardCharsets.UTF_8).size <= 64 * 1024)
    }
}

data class MoonlightCoreRegistration(
    val nativeReceiptId: String,
    val registrationRevision: Long,
    val hostId: String,
    val hostRevision: Long,
    val pairingRevision: Long,
    val catalogRevision: Long,
    val apps: Map<Int, Pair<String, Long>>,
) {
    init {
        requireIdentity(nativeReceiptId, "candidate")
        requireRevision(registrationRevision, "revision")
        requireIdentity(hostId, "candidate")
        requireRevision(hostRevision, "revision")
        requireRevision(pairingRevision, "pairing_revision")
        requireRevision(catalogRevision, "revision")
        require(apps.size <= 256)
        apps.forEach { (index, mapping) ->
            require(index in 0..255)
            requireIdentity(mapping.first, "candidate")
            requireRevision(mapping.second, "revision")
        }
    }
}

/** Private native mapping. Provider UUIDs/application IDs never leave this store. */
class MoonlightRegistrationStore(private val file: File) {
    private val atomic = AtomicFile(file)

    @Synchronized
    fun savePairing(pairing: MoonlightNativePairing) {
        val root = loadRoot()
        val pairings = root.getJSONArray("pairings")
        removeBy(pairings, "receiptId", pairing.receiptId)
        if (pairings.length() >= MAX_PAIRINGS) throw MoonlightRuntimeFailure("busy")
        pairings.put(pairing.toJson())
        write(root)
    }

    @Synchronized
    fun pairing(receiptId: String): MoonlightNativePairing? {
        requireIdentity(receiptId, "candidate")
        val values = loadRoot().getJSONArray("pairings")
        return (0 until values.length()).asSequence()
            .map { decodePairing(values.getJSONObject(it)) }
            .singleOrNull { it.receiptId == receiptId }
    }

    @Synchronized
    fun saveRegistration(registration: MoonlightCoreRegistration) {
        val root = loadRoot()
        val pairings = root.getJSONArray("pairings")
        val pairing = (0 until pairings.length()).asSequence()
            .map { decodePairing(pairings.getJSONObject(it)) }
            .singleOrNull { it.receiptId == registration.nativeReceiptId }
            ?: throw MoonlightRuntimeFailure("invalid_receipt")
        if (pairing.pairingRevision != registration.pairingRevision ||
            pairing.catalogRevision != registration.catalogRevision ||
            registration.apps.keys != pairing.apps.map { it.entryIndex }.toSet()
        ) throw MoonlightRuntimeFailure("stale_pairing")
        val registrations = root.getJSONArray("registrations")
        val existing = (0 until registrations.length()).asSequence()
            .map { decodeRegistration(registrations.getJSONObject(it)) }
            .singleOrNull { it.nativeReceiptId == registration.nativeReceiptId }
        if (existing != null) {
            if (existing != registration) throw MoonlightRuntimeFailure("invalid_receipt")
            return
        }
        var retiredReceiptId: String? = null
        for (index in registrations.length() - 1 downTo 0) {
            val previous = registrations.getJSONObject(index)
            if (previous.getString("hostId") == registration.hostId) {
                retiredReceiptId = previous.getString("nativeReceiptId")
                registrations.remove(index)
            }
        }
        if (registrations.length() >= MAX_PAIRINGS) throw MoonlightRuntimeFailure("busy")
        registrations.put(registration.toJson())
        if (retiredReceiptId != null && retiredReceiptId != registration.nativeReceiptId) {
            removeBy(pairings, "receiptId", retiredReceiptId)
        }
        write(root)
    }

    @Synchronized
    fun registration(hostId: String): MoonlightCoreRegistration? {
        requireIdentity(hostId, "candidate")
        val values = loadRoot().getJSONArray("registrations")
        return (0 until values.length()).asSequence()
            .map { decodeRegistration(values.getJSONObject(it)) }
            .singleOrNull { it.hostId == hostId }
    }

    @Synchronized
    fun resolve(
        hostId: String,
        hostRevision: Long,
        pairingRevision: Long,
        catalogRevision: Long,
        appId: String,
        appRevision: Long,
    ): Pair<MoonlightNativePairing, MoonlightObservedApp> {
        requireIdentity(hostId, "candidate")
        requireIdentity(appId, "candidate")
        val values = loadRoot().getJSONArray("registrations")
        val registration = (0 until values.length()).asSequence()
            .map { decodeRegistration(values.getJSONObject(it)) }
            .singleOrNull { it.hostId == hostId }
            ?: throw MoonlightRuntimeFailure("stale_pairing")
        if (registration.hostRevision != hostRevision || registration.pairingRevision != pairingRevision) {
            throw MoonlightRuntimeFailure("stale_pairing")
        }
        if (registration.catalogRevision != catalogRevision) throw MoonlightRuntimeFailure("stale_candidate")
        val entry = registration.apps.entries.singleOrNull {
            it.value.first == appId && it.value.second == appRevision
        }?.key ?: throw MoonlightRuntimeFailure("stale_candidate")
        val pairing = pairing(registration.nativeReceiptId)
            ?: throw MoonlightRuntimeFailure("invalid_receipt")
        val app = pairing.apps.singleOrNull { it.entryIndex == entry }
            ?: throw MoonlightRuntimeFailure("invalid_receipt")
        return pairing to app
    }

    @Synchronized
    fun deletePairing(receiptId: String) {
        val root = loadRoot()
        removeBy(root.getJSONArray("pairings"), "receiptId", receiptId)
        removeBy(root.getJSONArray("registrations"), "nativeReceiptId", receiptId)
        write(root)
    }

    private fun loadRoot(): JSONObject {
        if (!file.exists()) return emptyRoot()
        if (!file.isFile || file.isSymbolicLink() || file.length() !in 1..MAX_BYTES) {
            throw MoonlightRuntimeFailure("invalid_receipt")
        }
        return try {
            val bytes = atomic.readFully()
            if (bytes.size.toLong() > MAX_BYTES) throw MoonlightRuntimeFailure("invalid_receipt")
            JSONObject(String(bytes, StandardCharsets.UTF_8)).also {
                if (it.keys().asSequence().toSet() != ROOT_KEYS || it.getInt("schemaVersion") != 1 ||
                    it.getJSONArray("pairings").length() > MAX_PAIRINGS ||
                    it.getJSONArray("registrations").length() > MAX_PAIRINGS
                ) throw MoonlightRuntimeFailure("invalid_receipt")
            }
        } catch (failure: MoonlightRuntimeFailure) {
            throw failure
        } catch (_: Exception) {
            throw MoonlightRuntimeFailure("invalid_receipt")
        }
    }

    private fun write(root: JSONObject) {
        val bytes = root.toString().toByteArray(StandardCharsets.UTF_8)
        if (bytes.size > MAX_BYTES) throw MoonlightRuntimeFailure("invalid_receipt")
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

    private fun emptyRoot() = JSONObject()
        .put("schemaVersion", 1)
        .put("pairings", JSONArray())
        .put("registrations", JSONArray())

    private fun removeBy(array: JSONArray, key: String, value: String) {
        for (index in array.length() - 1 downTo 0) {
            if (array.getJSONObject(index).getString(key) == value) array.remove(index)
        }
    }

    private fun MoonlightNativePairing.toJson() = JSONObject()
        .put("receiptId", receiptId)
        .put("nativeBindingId", nativeBindingId)
        .put("bindingRevision", bindingRevision)
        .put("hostObservationId", hostObservationId)
        .put("upstreamHostUuid", upstreamHostUuid)
        .put("pairingRevision", pairingRevision)
        .put("catalogRevision", catalogRevision)
        .put("catalogDigest", catalogDigest)
        .put("observationJson", observationJson)
        .put("apps", JSONArray().also { array -> apps.forEach { array.put(it.toJson()) } })

    private fun MoonlightObservedApp.toJson() = JSONObject()
        .put("entryIndex", entryIndex)
        .put("observationId", observationId)
        .put("revision", revision)
        .put("name", name)
        .put("upstreamAppId", upstreamAppId)
        .put("hdrSupported", hdrSupported)

    private fun MoonlightCoreRegistration.toJson() = JSONObject()
        .put("nativeReceiptId", nativeReceiptId)
        .put("registrationRevision", registrationRevision)
        .put("hostId", hostId)
        .put("hostRevision", hostRevision)
        .put("pairingRevision", pairingRevision)
        .put("catalogRevision", catalogRevision)
        .put("apps", JSONArray().also { array ->
            apps.toSortedMap().forEach { (entryIndex, mapping) ->
                array.put(JSONObject()
                    .put("entryIndex", entryIndex)
                    .put("appId", mapping.first)
                    .put("appRevision", mapping.second))
            }
        })

    private fun decodePairing(value: JSONObject) = MoonlightNativePairing(
        receiptId = value.getString("receiptId"),
        nativeBindingId = value.getString("nativeBindingId"),
        bindingRevision = value.getLong("bindingRevision"),
        hostObservationId = value.getString("hostObservationId"),
        upstreamHostUuid = value.getString("upstreamHostUuid"),
        pairingRevision = value.getLong("pairingRevision"),
        catalogRevision = value.getLong("catalogRevision"),
        catalogDigest = value.getString("catalogDigest"),
        apps = value.getJSONArray("apps").let { array ->
            (0 until array.length()).map { decodeApp(array.getJSONObject(it)) }
        },
        observationJson = value.getString("observationJson"),
    )

    private fun decodeApp(value: JSONObject) = MoonlightObservedApp(
        entryIndex = value.getInt("entryIndex"),
        observationId = value.getString("observationId"),
        revision = value.getLong("revision"),
        name = value.getString("name"),
        upstreamAppId = value.getInt("upstreamAppId"),
        hdrSupported = value.getBoolean("hdrSupported"),
    )

    private fun decodeRegistration(value: JSONObject) = MoonlightCoreRegistration(
        nativeReceiptId = value.getString("nativeReceiptId"),
        registrationRevision = value.getLong("registrationRevision"),
        hostId = value.getString("hostId"),
        hostRevision = value.getLong("hostRevision"),
        pairingRevision = value.getLong("pairingRevision"),
        catalogRevision = value.getLong("catalogRevision"),
        apps = value.getJSONArray("apps").let { array ->
            (0 until array.length()).associate {
                val item = array.getJSONObject(it)
                item.getInt("entryIndex") to (item.getString("appId") to item.getLong("appRevision"))
            }
        },
    )

    private fun File.isSymbolicLink(): Boolean = Files.isSymbolicLink(toPath())

    companion object {
        private const val MAX_PAIRINGS = 64
        private const val MAX_BYTES = 256 * 1024L
        private val ROOT_KEYS = setOf("schemaVersion", "pairings", "registrations")
    }
}
