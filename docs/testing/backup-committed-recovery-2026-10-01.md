# Committed component restore recovery deadline evidence

Date: 2026-10-01

The component restore power-loss test uses an owned temporary directory, a
loopback Unix-socket Docker fixture, authenticated recovery journal state, and a
portable directory-exchange seam. It does not access a household service or a
real Docker daemon. Production continues to use the Linux `renameat2` engine;
the portable exchange is test-only and is not Linux filesystem acceptance.

Exact hosted run `36813872693`, job `110214595864`, at source revision
`36269cf05091156ae960106eaec27810ff35fc78` completed shard 0 with 1,915 tests
passed, 24 skipped, and one failure. The only failure was
`test_linux_boundary_restarts_after_power_loss[committed]`. Its named
JUnit report records 8.476 seconds. The test had supplied an eight-second
deadline independently to the interrupted restore and restarted recovery. The
elapsed time is strong evidence of deadline exhaustion. The coordinator's
intentionally redacted generic-exception wrapper exposes only
`ComponentRestorePlanError`, so the original exception type and exact source
site are unavailable and the timeout inference is not presented as proven root
cause.

This change gives only that multi-lifetime power-loss acceptance a bounded
30-second per-operation deadline. It does not change the coordinator, extend a
production deadline, retry a restore, or weaken journal, authority, receipt,
filesystem, and no-replay checks. The existing four phase variants still
exercise `quiesced`, `staging`, `pre_commit`, and `committed` recovery. A local
macOS run passed those four cases plus the two existing unproven-admin-pause
recovery cases (six tests total). It proves the portable fixture, authority,
journal, and recovery assertions only. A fresh hosted Linux shard is still
required before treating the exact source as Linux acceptance.

Root independently ran the same four power-loss cases and two unproven pause
cases successfully (exit zero). The production coordinator was not modified.
