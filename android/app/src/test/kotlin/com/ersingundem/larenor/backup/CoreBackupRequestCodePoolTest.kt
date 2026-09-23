package com.ersingundem.larenor.backup

import org.junit.Assert.*
import org.junit.Test

class CoreBackupRequestCodePoolTest {
    @Test fun completedCodesWrapAndReuseInConfiguredDirection() {
        val ascending = CoreBackupRequestCodePool(10, 11)
        assertEquals(10, ascending.allocate())
        ascending.complete(10)
        assertEquals(11, ascending.allocate())
        ascending.complete(11)
        assertEquals(10, ascending.allocate())

        val descending = CoreBackupRequestCodePool(2, 1)
        assertEquals(2, descending.allocate())
        descending.complete(2)
        assertEquals(1, descending.allocate())
        descending.complete(1)
        assertEquals(2, descending.allocate())
    }

    @Test fun retiredCodeCannotBeReusedBeforeItsExactLateResult() {
        val pool = CoreBackupRequestCodePool(20, 21)
        val retired = pool.allocate()
        pool.retire(retired)
        assertEquals(21, pool.allocate())
        assertThrows(IllegalStateException::class.java) { pool.allocate() }
        assertFalse(pool.consumeRetired(999))
        assertThrows(IllegalStateException::class.java) { pool.allocate() }

        assertTrue(pool.consumeRetired(retired))
        assertEquals(retired, pool.allocate())
    }

    @Test fun completingUnknownOrRetiredCodesCannotReleaseAnotherOwner() {
        val pool = CoreBackupRequestCodePool(30, 30)
        val code = pool.allocate()
        pool.retire(code)

        assertFalse(pool.complete(999))
        assertFalse(pool.complete(code))
        assertThrows(IllegalStateException::class.java) { pool.allocate() }
        assertTrue(pool.consumeRetired(code))
        assertEquals(code, pool.allocate())
    }
}
