package com.ersingundem.larenor.rdp

import org.junit.Test

private const val REQUEST_ID = "12345678-1234-4abc-8def-1234567890ab"
private const val SESSION_ID = "87654321-4321-4abc-8def-ba0987654321"
private const val GRANT_ID = "11111111111111111111111111111111"
private const val TRANSFER_ID = "22222222222222222222222222222222"
private const val NAMESPACE = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
private const val PROFILE = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
private const val FINGERPRINT = "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

private fun authority() = mapOf(
    "schemaVersion" to 5,
    "namespaceDigest" to NAMESPACE,
    "profileRef" to PROFILE,
    "profileRevision" to 7L,
)

private fun display() = mapOf(
    "width" to 1280,
    "height" to 800,
    "desktopScaleFactor" to 100,
    "deviceScaleFactor" to 100,
    "externalDisplay" to false,
    "dynamicResize" to true,
)

private fun request(schema: Int): MutableMap<String, Any?> = mutableMapOf(
    "schemaVersion" to schema,
    "requestId" to SESSION_ID,
    "targetHost" to "rdp.example.test",
    "targetPort" to 3389,
    "username" to "owned-user",
    "domain" to "",
    "gateway" to null,
    "certificateFingerprint" to FINGERPRINT,
    "requiresNla" to true,
    "display" to display(),
    "keyboardLayout" to "turkishQ",
    "clipboardMode" to "disabled",
    "audio" to false,
    "microphone" to false,
    "files" to (schema == 6),
).also {
    if (schema == 6) {
        it["sessionRevision"] = 9L
        it["fileTransfer"] = mapOf("transferId" to TRANSFER_ID)
    }
}

private fun prepare() = mapOf(
    "schemaVersion" to 6,
    "requestId" to REQUEST_ID,
    "authority" to authority(),
    "grantId" to GRANT_ID,
    "grantRevision" to 8L,
    "sessionRequestId" to SESSION_ID,
    "sessionRevision" to 9L,
)

private fun gateway() = mapOf(
    "host" to "gateway.example.test",
    "port" to 443,
    "username" to "gateway-user",
    "domain" to "",
    "certificateFingerprint" to FINGERPRINT,
)

private inline fun rejects(block: () -> Unit) {
    val failure = runCatching(block).exceptionOrNull()
    check(failure is RdpNativeFailure && failure.code in setOf("invalidRequest", "channelUnavailable"))
}

private inline fun rejectsSaf(block: () -> Unit) {
    val failure = runCatching(block).exceptionOrNull()
    check(failure is RdpSafFailure && failure.code == "invalid_request")
}

fun schema6ContractChecks(): Int {
    val ownerChecks = openOwnerGateChecks()
    val packaged = RdpNativeCapabilities.parse(RdpFreeRdpPackage.capabilities())
    check(!packaged.files && packaged.canConnect)

    val ordinary = RdpNativeRequest.parse(request(4))
    check(ordinary.schemaVersion == 4 && !ordinary.files)
    check(ordinary.sessionRevision == null && ordinary.fileTransferId == null)

    val grant = RdpSafContract.grant(mapOf(
        "schemaVersion" to 5,
        "requestId" to REQUEST_ID,
        "authority" to authority(),
        "grantId" to GRANT_ID,
        "expectedGrantRevision" to 8L,
    ))
    check(grant.grantId == GRANT_ID && grant.expectedGrantRevision == 8L)
    rejectsSaf { RdpSafContract.grant(mapOf(
        "schemaVersion" to 6,
        "requestId" to REQUEST_ID,
        "authority" to authority(),
        "grantId" to GRANT_ID,
        "expectedGrantRevision" to 8L,
    )) }

    val owned = RdpNativeRequest.parse(request(6))
    check(owned.schemaVersion == 6 && owned.files)
    check(owned.sessionRevision == 9L && owned.fileTransferId == TRANSFER_ID)

    val gatewayOnly = RdpNativeRequest.parse(request(6).also {
        it["gateway"] = gateway()
        it["files"] = false
        it["fileTransfer"] = null
    })
    check(gatewayOnly.schemaVersion == 6 && gatewayOnly.gateway != null)
    check(!gatewayOnly.files && gatewayOnly.fileTransferId == null && gatewayOnly.sessionRevision == 9L)

    rejects { RdpNativeRequest.parse(request(4).also { it["sessionRevision"] = 9L }) }
    rejects { RdpNativeRequest.parse(request(6).also { it.remove("fileTransfer") }) }
    rejects { RdpNativeRequest.parse(request(6).also { it["files"] = false; it["fileTransfer"] = null }) }
    rejects { RdpNativeRequest.parse(request(6).also { it["fileTransfer"] = null }) }
    rejects { RdpNativeRequest.parse(request(6).also { it["fileTransfer"] = mapOf("transferId" to GRANT_ID, "path" to "/private") }) }

    val prepared = RdpFileTransferContract.prepare(prepare())
    check(prepared.sessionRequestId == SESSION_ID && prepared.sessionRevision == 9L)
    check(prepared.authority.authorityId.length == 64)

    val lifecycle = RdpFileTransferContract.lifecycle(prepare() + ("transferId" to TRANSFER_ID))
    check(lifecycle.transferId == TRANSFER_ID)
    rejects { RdpFileTransferContract.lifecycle(prepare() + mapOf("transferId" to TRANSFER_ID, "path" to "/private")) }
    rejects { RdpFileTransferContract.prepare(prepare() + ("transferId" to TRANSFER_ID)) }

    val receipt = RdpFileTransferContract.receipt(
        REQUEST_ID,
        prepared.authority.authorityId,
        GRANT_ID,
        8L,
        TRANSFER_ID,
        "prepared",
    )
    check(receipt.keys == setOf("schemaVersion", "requestId", "authorityId", "grantId", "grantRevision", "transferId", "state"))
    check(receipt.values.none { it is String && ('/' in it || ':' in it && it != REQUEST_ID) })
    rejects {
        RdpFileTransferContract.receipt(
            REQUEST_ID, prepared.authority.authorityId, GRANT_ID, 8L, TRANSFER_ID, "active/path",
        )
    }

    return 19 + ownerChecks
}

fun main() {
    println("schema6-contract: ${schema6ContractChecks()} checks passed")
}

class RdpSchema6ContractJvmTest {
    @Test
    fun ordinaryFourGrantFiveAndOwnedSixContractsRemainClosed() {
        check(schema6ContractChecks() == 33)
    }
}
