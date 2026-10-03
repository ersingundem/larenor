package com.ersingundem.larenor.rdp

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class RdpSafContractTest {
    @Test
    fun authorityIsStrictAndDerivedFromCanonicalOpaqueFields() {
        val authority = RdpSafContract.authority(AUTHORITY)

        assertEquals(
            "40f4cddadaeb4bac04b692af8613920a21a6c904b8740637f3398b86789d02db",
            authority.authorityId,
        )
        assertEquals(7L, authority.profileRevision)
        assertFalse(authority.toString().contains(NAMESPACE))
        assertFalse(authority.toString().contains(PROFILE))

        reject("invalid_request") {
            RdpSafContract.authority(AUTHORITY + ("profileLabel" to "Living room"))
        }
        reject("invalid_request") {
            RdpSafContract.authority(AUTHORITY + ("profileRevision" to 9_007_199_254_740_992L))
        }
        reject("invalid_request") {
            RdpSafContract.authority(AUTHORITY + ("namespaceDigest" to NAMESPACE.uppercase()))
        }
    }

    @Test
    fun requestsAndReceiptsUseExactSchemaWithoutUriOrAuthorityMaterial() {
        val selected = RdpSafContract.select(mapOf(
            "schemaVersion" to 5,
            "requestId" to SELECT_REQUEST,
            "authority" to AUTHORITY,
        ))
        assertEquals(SELECT_REQUEST, selected.requestId)

        val owned = RdpSafContract.grant(mapOf(
            "schemaVersion" to 5,
            "requestId" to GRANT_REQUEST,
            "authority" to AUTHORITY,
            "grantId" to GRANT_ID,
            "expectedGrantRevision" to 1L,
        ))
        assertEquals(GRANT_ID, owned.grantId)

        val receipt = RdpSafContract.receipt(
            requestId = GRANT_REQUEST,
            authorityId = selected.authority.authorityId,
            grantId = GRANT_ID,
            grantRevision = 1L,
            state = RdpSafPublicState.ACTIVE,
        )
        assertEquals(
            setOf("schemaVersion", "requestId", "authorityId", "grantId", "grantRevision", "state"),
            receipt.keys,
        )
        assertEquals("active", receipt["state"])
        assertTrue(receipt.values.none { it.toString().contains("content://") })
        assertTrue(receipt.values.none { it.toString().contains(NAMESPACE) })

        reject("invalid_request") {
            RdpSafContract.select(mapOf(
                "schemaVersion" to 5,
                "requestId" to SELECT_REQUEST,
                "authority" to AUTHORITY,
                "uri" to "content://forbidden",
            ))
        }
        reject("invalid_request") {
            RdpSafContract.cancel(mapOf("schemaVersion" to 5, "requestId" to "not-a-uuid"))
        }
    }

    private fun reject(code: String, block: () -> Unit) {
        try {
            block()
            fail("Expected $code")
        } catch (failure: RdpSafFailure) {
            assertEquals(code, failure.code)
        }
    }

    companion object {
        private const val NAMESPACE =
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        private const val PROFILE =
            "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        private val AUTHORITY = mapOf<String, Any?>(
            "schemaVersion" to 5,
            "namespaceDigest" to NAMESPACE,
            "profileRef" to PROFILE,
            "profileRevision" to 7L,
        )
        private const val SELECT_REQUEST = "11111111-1111-4111-8111-111111111111"
        private const val GRANT_REQUEST = "22222222-2222-4222-8222-222222222222"
        private const val GRANT_ID = "0123456789abcdef0123456789abcdef"
    }
}
