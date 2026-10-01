# F62 owned test lifecycle diagnostics — 2026-10-01

## Problem and scope

The exact source `36c3e015d27c3ff4b21b0e7d834075b7107bb479` failed in
[run 36808149011](https://github.com/ersingundem/larenor/actions/runs/36808149011).
The canonical report contained one test, one failure, no errors and no skips;
the bounded receipt contained no owned stack frames and did not observe a
server resize. The arm64 package job passed. That evidence does not establish
which current operation failed, and the earlier initial-frame timeout cannot
be substituted for this run's cause.

This changed-source slice records the last entered boundary of the exact owned
Android acceptance test. A fresh private nonce binds a marker to one invocation.
The marker contains only a fixed stage enum; it cannot contain a host address,
credential, clipboard content, exception message, or arbitrary string. Android
writes it using AtomicFile with flush-to-disk semantics. Write and removal
failures remain secondary and preserve the original acceptance result.

The runner reads at most 128 ASCII bytes from the exact app-private filename
with a fixed adb/run-as/dd argument vector and a five-second timeout. Unknown,
malformed and oversized stages are omitted. In a finally block it removes only
that nonce's base, .new and .bak files, including after a read timeout. Neither
the nonce nor the private filename is included in the public receipt.

The optional `testLifecycleStage` is the last successfully recorded entered
boundary, not an exception classification or proof that the operation completed.
If diagnostic I/O failed it may describe an earlier boundary. Original report
identity, source/package binding, exact one-test counts, and all TLS/NLA/SPKI,
frame/ACK, real key effect, client DISP resize, Unicode clipboard, disabled
clipboard, two-lifetime, teardown and credential-clearing assertions remain
required. The marker alone cannot establish success or even replace the named
report's invocation proof.

## Verification

- Root ran the live-source parser/runner suite: **34 passed, no failures or
  skips**, using `PYTHONPATH=. server/.venv/bin/python -m pytest
  tool/tests/f62_packaged_acceptance_test.py --tb=no -rA`.
- Tests cover enum injection rejection, nonce separation, bounded reading,
  invalid/timeout cleanup and preservation of the strict success receipt.
- The actual required native-package AndroidTest Kotlin compilation passed:
  **BUILD SUCCESSFUL**, 278 actionable tasks. The diagnostic helper's injected
  IOException/SecurityException cases compile with the owned acceptance test.
- Root's first macOS Python 3.14 run exposed a test-fixture portability error:
  `os.pipe2` was absent. The Linux production call and its CLOEXEC/NONBLOCK
  requirements remain unchanged; the scoped fixture now uses a real pipe and
  checks those flags explicitly. The suite passed under both local Python
  interpreters afterward. This is not evidence of a Linux runtime failure.

These are local source and compilation checks. A new changed-source hosted
FreeRDP run is required to prove the real remote desktop lifecycle; F62 remains
**reworking**, not CI-awaiting implementation complete.

## Exact changed-source result

Source `c829106162b92207a22d6d6f7731ec505c7100af`,
[run 36811909218](https://github.com/ersingundem/larenor/actions/runs/36811909218),
completed with the original named test failing: **1 test, 1 failure, 0 errors,
0 skips**. Its bounded diagnostic is `unclassified`, with no owned source
frames, no `testLifecycleStage`, and `serverResizeRequested=false`. The arm64
package job passed. The failure establishes no current initial-frame, resize,
or process-crash cause.

The marker is currently written after argument parsing and secondary checks,
and read only after Gradle exits. An absent marker cannot distinguish an early
initialization failure, a diagnostic I/O failure, or package-data teardown.
An early marker and bounded non-destructive collection during Gradle execution
are being developed to narrow that gap; no unchanged-source retry is used.
