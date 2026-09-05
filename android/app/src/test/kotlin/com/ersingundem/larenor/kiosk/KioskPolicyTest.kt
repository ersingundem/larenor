package com.ersingundem.larenor.kiosk

import org.junit.Assert.*
import org.junit.Test

class KioskPolicyTest {
    private class Host : KioskHost {
        var state = KioskState(true, true, "none", true, true, true, false, true, 2)
        var now = 1L
        var tokenCount = 0
        val writes = mutableListOf<KioskAction>()
        var applyOverride: ((KioskAction) -> Unit)? = null
        override fun read() = state
        override fun apply(action: KioskAction) {
            writes += action
            applyOverride?.let { it(action); return }
            state = when(action) {
                KioskAction.allowApp -> state.copy(permitted=true)
                KioskAction.removeApp -> state.copy(permitted=false, lockState="none")
                KioskAction.restorePowerMenu -> state.copy(powerMenuAllowed=true)
                KioskAction.enter -> state.copy(lockState="locked")
                KioskAction.exit -> state.copy(lockState="none")
            }
        }
        override fun nowMillis() = now
        override fun token() = "intent-000000000000-${++tokenCount}"
    }
    private fun prepare(c: KioskPolicy, action: KioskAction=KioskAction.enter) = c.prepare(mapOf("action" to action.name))["id"] as String
    private fun execute(c: KioskPolicy, id: String)=c.execute(mapOf("id" to id))
    private fun fails(code: String, action: () -> Unit) {
        try { action(); fail("Expected $code") } catch(e: KioskFailure) { assertEquals(code,e.code) }
    }
    @Test fun readsAndProposalsHaveNoNativeSideEffects() {
        val h=Host(); val c=KioskPolicy(h)
        assertEquals("none",c.snapshot()["lockState"]); prepare(c); assertTrue(h.writes.isEmpty())
    }
    @Test fun missingAllowlistNeverFallsBackToScreenPinning() {
        val h=Host(); h.state=h.state.copy(permitted=false)
        fails("denied") { prepare(KioskPolicy(h)) }; assertTrue(h.writes.isEmpty())
    }
    @Test fun onlyOwnerCanEditOurAllowlist() {
        val h=Host(); h.state=h.state.copy(deviceOwner=false,permitted=false)
        fails("denied") { prepare(KioskPolicy(h),KioskAction.allowApp) }; assertTrue(h.writes.isEmpty())
    }
    @Test fun externalAdminPermissionCanStartButCannotEditOwnerPolicies() {
        val h=Host(); h.state=h.state.copy(deviceOwner=false,powerMenuAllowed=null)
        val c=KioskPolicy(h); assertEquals("observed",execute(c,prepare(c))["outcome"])
        fails("denied") { prepare(c,KioskAction.removeApp) }
    }
    @Test fun selfManagedEntryKeepsPowerRecoveryEnabled() {
        val h=Host(); h.state=h.state.copy(powerMenuAllowed=false)
        val c=KioskPolicy(h); fails("denied") { prepare(c) }
        execute(c,prepare(c,KioskAction.restorePowerMenu))
        assertEquals(listOf(KioskAction.restorePowerMenu),h.writes)
        execute(c,prepare(c)); assertEquals("locked",h.state.lockState)
    }
    @Test fun unknownOwnerDoesNotQualifyAsTrustedExternalAdmin() {
        val h=Host(); h.state=h.state.copy(deviceOwner=null)
        // Unknown management observations must not be interpreted as known external DPC.
        fails("denied") { prepare(KioskPolicy(h)) }
    }
    @Test fun enteringRequiresForegroundWindowAndUnlockedDevice() {
        val base=Host().state
        for(state in listOf(base.copy(resumed=false),base.copy(focused=false),base.copy(eligibleWindow=false),base.copy(keyguardLocked=true),base.copy(keyguardLocked=null),base.copy(lockState="pinned"))) {
            val h=Host(); h.state=state
            fails("denied") { prepare(KioskPolicy(h)) }; assertTrue(h.writes.isEmpty())
        }
    }
    @Test fun revokedPermissionBetweenConfirmationAndExecutionCancelsWithoutWrite() {
        val h=Host(); val c=KioskPolicy(h); val id=prepare(c)
        h.state=h.state.copy(permitted=false)
        fails("expired") { execute(c,id) }; assertTrue(h.writes.isEmpty())
    }
    @Test fun expiryUsesMonotonicThirtySecondBoundary() {
        val h=Host(); val c=KioskPolicy(h); val id=prepare(c)
        h.now+=30_000L; fails("expired") { execute(c,id) }; assertTrue(h.writes.isEmpty())
    }
    @Test fun expiredAbandonedProposalDoesNotPermanentlyBlockRecovery() {
        val h=Host(); val c=KioskPolicy(h); val old=prepare(c)
        h.now+=30_000L; val fresh=prepare(c)
        fails("expired") { execute(c,old) }; execute(c,fresh); assertEquals(1,h.writes.size)
    }
    @Test fun nativeBackgroundAndReturnDoesNotReviveIntent() {
        val h=Host(); val c=KioskPolicy(h); val id=prepare(c)
        c.invalidate(); fails("expired") { execute(c,id) }; assertTrue(h.writes.isEmpty())
    }
    @Test fun oneUseApprovalCannotStartLockTaskTwice() {
        val h=Host(); val c=KioskPolicy(h); val id=prepare(c)
        execute(c,id); fails("expired") { execute(c,id) }; assertEquals(listOf(KioskAction.enter),h.writes)
    }
    @Test fun competingProposalRequiresCancelAndCannotOverwritePendingConfirmation() {
        val h=Host(); val c=KioskPolicy(h); val id=prepare(c)
        fails("busy") { prepare(c,KioskAction.removeApp) }
        c.cancel(mapOf("id" to "another-000000000000")); execute(c,id)
        assertEquals(listOf(KioskAction.enter),h.writes)
    }
    @Test fun cancelledAndDisposedIntentWritesNothing() {
        val h=Host(); val c=KioskPolicy(h); val id=prepare(c)
        c.cancel(mapOf("id" to id)); fails("expired") { execute(c,id) }
        val newer=prepare(c); c.dispose(); fails("unavailable") { execute(c,newer) }; assertTrue(h.writes.isEmpty())
    }
    @Test fun foreignOrExtraArgumentsCannotSelectPackagesOrPolicies() {
        val c=KioskPolicy(Host())
        fails("invalid") { c.prepare(mapOf("action" to "allowApp", "package" to "other.app")) }
        fails("invalid") { c.prepare(mapOf("action" to "wipe")) }
        fails("invalid") { c.execute(mapOf("id" to "tiny")) }
    }
    @Test fun requestAcceptedIsNotProofOfManagedStateAndDoesNotAutoretry() {
        val h=Host(); h.applyOverride={}; val c=KioskPolicy(h)
        val result=execute(c,prepare(c)); assertEquals("accepted",result["outcome"])
        assertEquals("none",(result["snapshot"] as Map<*,*>)["lockState"]); assertEquals(1,h.writes.size)
    }
    @Test fun runtimeFailureAfterDispatchIsUnknownAndNeverRetried() {
        val h=Host(); h.applyOverride={throw IllegalStateException("private platform detail")}; val c=KioskPolicy(h)
        val result=execute(c,prepare(c)); assertEquals("unknown",result["outcome"]); assertEquals(1,h.writes.size)
        assertFalse(result.toString().contains("private platform detail"))
    }
    @Test fun securityExceptionIsDeniedWithoutAutomaticRetry() {
        val h=Host(); h.applyOverride={throw SecurityException("private detail")}; val c=KioskPolicy(h)
        fails("denied") { execute(c,prepare(c)) }; assertEquals(1,h.writes.size)
    }
    @Test fun exitRemainsAvailableAfterAllowlistRevocationAndInExternalWindow() {
        val h=Host(); h.state=h.state.copy(deviceOwner=false,permitted=false,eligibleWindow=false,lockState="locked",powerMenuAllowed=null)
        val c=KioskPolicy(h); execute(c,prepare(c,KioskAction.exit)); assertEquals("none",h.state.lockState)
    }
    @Test fun onlyExactObservedLockModeIsCalledManaged() {
        val h=Host(); h.state=h.state.copy(lockState="pinned")
        assertEquals("pinned",KioskPolicy(h).snapshot()["lockState"])
    }
}
