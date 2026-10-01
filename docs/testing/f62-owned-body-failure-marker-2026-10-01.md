# F62 owned Android body-failure marker — 2026-10-01

## Scope

The strict packaged FreeRDP acceptance keeps the original connected Android
JUnit result authoritative. This slice adds only bounded failure diagnostics;
it does not relax TLS 1.2, NLA, certificate pinning, frame acknowledgement,
input, resize, clipboard, two-lifetime, or clean-close acceptance.

The Android test writes its current fixed lifecycle enum to the existing
nonce-named `AtomicFile`. When the outer test-body guard catches an allowlisted
throwable, it replaces that record with this closed ASCII grammar:

```
bodyFailure|v1|<fixed lifecycle stage>|<fixed throwable class>
```

The host observes only that private file through the existing app-owned
`run-as com.ersingundem.larenor` channel. It first probes the channel, then
checks the exact nonce filename, and reads at most 129 bytes so a record longer
than the 128-byte contract cannot be accepted through truncation. Raw adb
stderr, exception messages, provider values, credentials, and marker bytes are
never published.

The probe, existence check, and bounded read share one monotonic one-second
deadline. Each subprocess receives only the remaining time, and no later adb
command starts once that deadline is exhausted. Observer shutdown suppresses
any result that returns after the stop fence. Host Gradle exit does not prove
that the on-device instrumentation writer exited, so the owned baseline path
never deletes its nonce marker. It performs one final bounded read and merges
it with the cached record after an observed host exit, retaining a body marker
written near test termination. Timeout, fixture failure, and observer join
failure paths stop polling and suppress late cache writes without deleting the
marker. The exact private nonce file remains only on the disposable owned
emulator until that emulator is removed. None of these diagnostic outcomes
replaces the primary failure.

Initial-frame marker details remain in the structured evidence object when the
observer caches or performs its final host-exit read. Publication uses that
observation only for the exact matching initial-frame throwable, lifecycle
stage, current source checksum, and validated bounded observation shape; a
generic or mismatched failure cannot inherit it or change its cause.

Public failure diagnostics expose only these fixed availability fields:

- `channel`: `available` or `unavailable`
- `record`: `observed`, `absent`, `invalid`, or `readUnavailable`
- `writer`: `observed` or `unknown`

`unknown` is deliberate: a missing single-channel record cannot distinguish a
pre-body failure from an unavailable writer. The implementation does not claim
`writeUnavailable` without an independent causal channel.

A closed body-failure stage/class may be attached only when the original report
is the exact named one-test failure (`1 test / 1 failure / 0 errors / 0 skips`),
the exact source checksum matches, and the nonce-bound body-failure marker is
observed. A conflicting body marker is marked invalid and adds no marker-based
classification; any independently valid primary XML classification remains
unchanged. Ordinary lifecycle records likewise preserve their observed
availability and the primary XML classification. A marker never turns a
passing report into acceptance or changes any success criterion.

## TDD evidence

The focused Python RED gate first failed because the decoder, marker evidence
model, bounded reader, receipt validation, and source-bound application did not
exist. The intentional RED command was:

```
python3 -m unittest \
  tool.tests.f62_packaged_acceptance_test.PackagedRdpReceiptTest.test_body_failure_marker_decoder_is_closed_and_rejects_injection \
  tool.tests.f62_packaged_acceptance_test.PackagedRdpReceiptTest.test_body_marker_only_upgrades_exact_named_failure_with_bound_source \
  tool.tests.f62_packaged_acceptance_test.PackagedRdpReceiptTest.test_marker_evidence_conflict_and_unavailability_never_infer_failure \
  tool.tests.f62_packaged_acceptance_test.PackagedRdpReceiptTest.test_failure_receipt_rejects_forged_owned_marker_fields
```

It produced one assertion failure and three missing-API/validation errors. A
second RED gate proved the bounded reader was absent. After the minimal
implementation, the full focused runner initially passed:

```
python3 -m unittest tool.tests.f62_packaged_acceptance_test
# Ran 52 tests ... OK
```

The tests cover closed marker grammar, unknown fields, injected stages/classes,
source mismatch, wrong result/count shapes, conflicting serialized evidence,
channel unavailable, absent file, read failure, invalid bytes, a valid prefix
whose file exceeds 128 bytes, invalid nonce, bounded timeouts, and success
non-elevation. An additional RED/GREEN regression proves that the three adb
steps share one absolute deadline and stop issuing commands when it expires;
another proves failed observer join suppresses late cache writes and leaves the
private marker untouched.
Exit-order regressions additionally prove that an exact terminal Gradle result
gets a final marker read without cleanup, while a fixture failure stops the
host process and retains the nonce marker without publishing a speculative
body failure.

The Kotlin producer and its Android instrumentation regression compile against
the verified merged FreeRDP and Moonlight product mount:

```
JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home \
  ./gradlew :app:compileDebugAndroidTestKotlin
# BUILD SUCCESSFUL in 12s
# 278 actionable tasks: 9 executed, 269 up-to-date
```

The compile log is private at
`/private/tmp/larenor-f62-body-marker-20261001/compile-androidtest.log`.
No emulator acceptance was run locally. The next changed-source hosted strict
run remains required to produce a real marker from the owned NLA fixture and to
diagnose, rather than accept, the underlying failure.


## Independent root review

Root reproduced an additional diagnostic correctness fault: a valid ordinary
`initialFrameWait` marker was incorrectly marked invalid when the original XML
already carried a valid initial-frame classification. The fixed conflict check
now runs only for an actual body-failure marker. A new regression keeps the
primary XML classification and ordinary availability intact. That review gate
passed **53 focused tests** and root independently passed **64 composed tests**
plus pinned Ruff 0.14.1. Follow-up deadline, host-exit ordering, and structured
initial-frame preservation regressions bring the current local gate to **56
focused tests** and **67 composed runner/workflow tests**, all green. The two
Android sources and their checksum remained unchanged, so the named AndroidTest
compile proof above is still applicable. No local instrumentation execution is
claimed. Root private logs are in
`/private/tmp/larenor-f62-body-marker-root-20261001/`; current local logs are in
`/private/tmp/larenor-f62-body-marker-deadline-20261001/`.


## Final root verification

After the conservative host-exit fix, root independently reran the frozen
runner/workflow composition: **67 tests passed, 0 failures/errors/skips**.
Pinned Ruff 0.14.1 and `git diff --check` passed. The independent reviewer
confirmed no remaining blocker: host termination never authorizes nonce
deletion or an Android writer-terminal claim, and diagnostic observations
cannot override the original named JUnit or success criteria. Both Kotlin
files stayed unchanged throughout the runner lifecycle fixes, preserving the
278-task compilation evidence. Hosted strict RDP acceptance remains open.
