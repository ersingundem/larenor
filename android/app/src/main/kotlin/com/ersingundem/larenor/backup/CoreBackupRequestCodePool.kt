package com.ersingundem.larenor.backup

/**
 * Process-scope ownership for Android activity request codes.
 *
 * Completed picker codes may wrap and be reused. Retired picker codes stay
 * reserved until their exact stale activity result is consumed, so a new
 * Flutter engine can never inherit an old picker result.
 */
internal class CoreBackupRequestCodePool(
    private val first: Int,
    private val last: Int,
) {
    private val step = if (last >= first) 1 else -1
    private val capacity = kotlin.math.abs(last - first) + 1
    private val owned = mutableSetOf<Int>()
    private val retired = mutableSetOf<Int>()
    private var next = first

    init {
        require(first in 1..0xFFFE && last in 1..0xFFFE)
    }

    fun allocate(): Int = synchronized(this) {
        repeat(capacity) {
            val candidate = next
            next = if (candidate == last) first else candidate + step
            if (owned.add(candidate)) return candidate
        }
        throw IllegalStateException("backup_request_codes_exhausted")
    }

    fun complete(code: Int): Boolean = synchronized(this) {
        if (code in retired) return false
        owned.remove(code)
    }

    fun retire(code: Int): Boolean = synchronized(this) {
        if (code !in owned) return false
        retired.add(code)
    }

    fun consumeRetired(code: Int): Boolean = synchronized(this) {
        if (!retired.remove(code)) return false
        check(owned.remove(code))
        true
    }
}
