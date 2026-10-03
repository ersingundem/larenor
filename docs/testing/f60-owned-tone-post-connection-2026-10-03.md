# F60 owned tone after exact connection — 2026-10-03

## Source defect

The owned-host runner previously started its only half-second stereo tone before
the Android instrumentation process. The tone worker waited for Sunshine's
stereo sink and played as soon as that sink appeared. The Android output
witness, however, deliberately ignores every PCM callback until the exact
foreground lease has received `connectionStarted`.

Those two correct local rules created a race: a complete PCM write could occur
before `connectionStarted`, be rejected by the lease fence, and never recur
because the fixture sent the tone only once. This mechanism is established by
the source ordering. It is not claimed as the exclusive cause of any earlier
hosted failure without a matching runtime receipt.

## Exact phase repair

The existing private control channel now starts with one ordered,
nonce-authenticated exchange:

1. the named Android test accepts the exact stream command only as
   `native_observed / streaming / connectionStarted`;
2. it reads the exact current session's private output snapshot and requires no
   accepted complete **nonzero** PCM write before the owned tone is armed;
3. it sends `audio_ready` and requires `audio_armed` on the existing canonical
   nonce-bound wire;
4. the host revalidates the exact paired client before acknowledging the arm
   and sends the fixed owned tone once for that session;
5. after the second exact `connectionStarted`, the test requires that
   successor's own zero nonzero-output baseline and repeats the same ordered
   arm, while the host revalidates pairing and sends exactly once for the
   second lifetime;
6. the existing touch, gamepad, deliberate-stop and remote-disconnect sequence
   remains ordered around those two one-shot lifetime witnesses.

The host never starts either tone before its exact phase. A malformed,
missing or out-of-order phase fails closed. Cancellation is visible to the
bounded sink wait, and the host does not retry either tone. A failed or retired
session cannot reach an arm, and a successor cannot consume its predecessor's
arm, because each exchange follows that lifetime's exact current command and
session snapshot checks.

Sunshine's owned null-sink monitor can legitimately deliver silence before the
fixture tone. Embed-v4 therefore reports whether a complete decoded PCM write
contains a nonzero sample, and the registry counts only a full nonzero write.
All-zero or partial writes leave the witness at zero. The pre-arm baseline is
thus a zero **nonzero-output** count; it is not a claim that no PCM callback or
silent buffer occurred.

## Bounded diagnostics and tests

The original one-test, zero-skip acceptance remains unchanged: rendered frame,
complete PCM write, actual input effects, two lifetimes, causal stop, remote
disconnect, zero replay and local retirement are still required.

Failure diagnostics may add only two booleans for the exact source-bound
`firstStreamOutput` assertion: whether a rendered-frame witness and an
accepted-audio witness were observed. Counts, PCM, pixels, provider fields,
session identifiers and raw messages remain private. Malformed, duplicated,
wrong-stage and changed-source markers are ignored.

Focused Python verification covers the exact audio-first phase order, one-shot
injection, refusal to inject on an out-of-order phase, fixed sink selection,
closed diagnostic parsing and injection rejection. This is fixture and parser
evidence. Actual rendered-frame and PCM acceptance still requires the changed
source owned-Sunshine Android gate.

Exact run `37121179343` failed before `connectionStarted` with a finite
`stageFailed=true / connectionStarted=false` boundary. It therefore does not
match this post-connection tone race and is not evidence that this repair fixes
that failure. Its connection-stage failure requires separate diagnosis.

## Root composed verification

Actual required-native product mount passed source/API/receipt/both-ABI checks.
The exact v4 AAR SHA-256 is
`e9bccd49d938284ebace46238073fad0018bb6e8a060748234c953ffe40176d8`.
Root passed **47 Moonlight JVM tests** with zero failures, errors, or skips.
The same command passed **65 RDP tests** and AndroidTest Kotlin compilation
(**314 tasks**, BUILD SUCCESSFUL). Private source manifest and JUnit are in
`/private/tmp/larenor-v4-v3-native-gate-g0exo5qs/`; the 22-source manifest SHA-256
is `ac4dc3cbdc16d0a5e359da6e26a90cc796a586e2209cb472381ec9029666da67`.
Exact owned AndroidTest SHA-256 is
`d07844aa3dd8e6f0188666c9a1082a56faf44401e28b0200cf6b4722e3d593e1`.

The composed package/runner/workflow/product/queue/progress suite passed
**225 tests / 184 subtests**, and Ruff passed. The focused F60 stream/discovery
suite passed **76 tests / 66 subtests**. There is no actual hosted stream
acceptance yet; the original real frame, nonzero PCM, input, two lifetimes,
stop, disconnect and retirement requirements are preserved.
