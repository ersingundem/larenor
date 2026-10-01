# F62 owned test-body failure diagnostics — 2026-10-01

## Evidence boundary

Exact source `5aa76fe85e522b2648b5957ebab5f47270af608d` failed in
[run 36822994907](https://github.com/ersingundem/larenor/actions/runs/36822994907).
The x86 canonical report contained the original named test with one failure,
zero errors and zero skips, but its bounded public diagnostic had an
`unclassified` exception, no owned frame and no lifecycle or initial-frame
classification. The arm64 package job passed. This proves an owned
instrumentation failure; it does not identify a runtime stage, exception or
product cause. Absence of the lifecycle sidecar remains uncertain because it
can also mean an early failure, diagnostic I/O failure or package-data removal.

The exact Android test body is now entered through one source-locked guard at
its first statement. The guard retains only:

- the last fixed lifecycle stage entered by this invocation; and
- an exact allowlisted throwable class, or the literal `unclassified`.

The wrapper is `RdpOwnedTestBodyFailure` with a fixed
`stage=<enum>;throwable=<enum>` marker. It does not retain the original cause,
message, stack payload, credential, address, pixels, clipboard value or private
path. Existing typed `RdpOwned*` failures pass through unchanged. Normal
`AssertionError`, `Exception` and `LinkageError` paths are wrapped;
`InterruptedException` also restores the thread interrupt flag. `ThreadDeath`
and virtual-machine fatal errors escape unchanged.

The public parser accepts this marker only when the raw report still has the
exact named test, the canonical one-test/one-failure/zero-error/zero-skip
counts, an exact owned test-method frame, and the SHA-256-locked Android source.
Arbitrary marker suffixes, stages, class names, messages, generic exception
text, missing frames, wrong counts and source drift stay unclassified or are
rejected. The optional test-body diagnostic cannot replace the original strict
success checks.

All TLS/NLA/SPKI, rendered-frame and ACK, key effect, client DISP resize,
Unicode clipboard, disabled-channel, two-lifetime, close and credential-clear
assertions retain their original timeouts and semantics. This slice adds
failure evidence only; it does not make F62 accepted and needs a changed-source
owned-host run before any runtime conclusion.

## Local verification

- `PYTHONPATH=. server/.venv/bin/python -m pytest
  tool/tests/f62_packaged_acceptance_test.py --tb=short -q`:
  **46 passed, 40 subtests passed**.
- `LARENOR_PRODUCT_NATIVE_ENGINES=required
  ./gradlew --no-daemon :app:compileDebugAndroidTestKotlin
  -x :app:compileFlutterBuildDebug --console=plain` with Java 17:
  **BUILD SUCCESSFUL in 8s**, 277 actionable tasks, 6 executed.
- The Kotlin regressions compile checks for exact stage/class output, private
  message removal, unknown-class collapse, typed-stage pass-through, interrupt
  restoration, and uncaught VM-fatal/ThreadDeath paths. They are not claimed as
  device execution evidence.

The guarded Android source SHA-256 is
`d684fb5f972105531f5811515481756893f096a518a99d11c2d1f2bbfd9df479`.

Root independently verified the runner and workflow together:
`PYTHONPATH=. server/.venv/bin/python -m pytest -o addopts='' -q
tool/tests/f62_packaged_acceptance_test.py
tool/tests/freerdp_android_workflow_test.py --tb=short` completed with
**57 passed, 40 subtests passed**, exit 0. Pinned Ruff 0.14.1 passed for the
changed runner and test. Root also compiled the final guarded AndroidTest
source in required-native mode with Homebrew Java 17: **BUILD SUCCESSFUL in
8s**, 277 actionable tasks, 5 executed. An independent read-only review
confirmed the source lock, exact named-test/count/frame fences, privacy
boundary and preservation of the original strict runtime assertions. This
review and compilation still do not establish device execution acceptance.
