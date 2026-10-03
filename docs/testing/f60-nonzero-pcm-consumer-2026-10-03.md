# F60 nonzero PCM consumer — 2026-10-03

## Source defect

The earlier embedded hook reported every complete `AudioTrack.write()` to the
Larenor foreground registry. Sunshine captures its owned null-sink monitor,
which can provide silent buffers while no fixture tone is playing. A complete
all-zero write could therefore satisfy the one-bit audio witness before the
nonce-bound owned tone was sent. The callback was causal for a local write, but
not for the owned nonzero signal required by this acceptance.

## Embed-v4 boundary

The source-locked renderer scans its already-decoded `short[]` buffer and calls
`Game.onAudioPcmWritten(requestedSamples, writtenSamples,
containsNonZeroPcm)`. Only the boolean crosses the embedded callback; samples,
PCM bytes and provider data remain inside the renderer.

`LarenorMoonlightGame` forwards that boolean with the exact launch token. The
foreground registry increments its bounded witness only when all of these are
true:

- the token still owns the exact active connection and `connectionStarted` was
  observed;
- the requested sample count is positive;
- the write completed the entire requested count;
- at least one decoded sample was nonzero.

All-zero, zero-length, partial, stale, retired and successor callbacks have no
effect. The count remains a bounded causal witness, not a volume, audibility or
speaker-output measurement.

The runtime identity is now
`moonlight-android-12.2-larenor-embed-v4`. Discovery, package receipt and
runtime reflection gates reject embed-v3, whose two-argument hook cannot prove
the nonzero boundary.

## Closed diagnostics and verification

The original single Android acceptance test requires a post-connection
`audio_ready/audio_armed` exchange, zero nonzero-output baseline, one owned
tone injection and one complete nonzero write for each of its two exact session
lifetimes. Each arm is consumed once in fixed order; there is no retry or
cross-session replay. The test retains the existing frame, input, stop,
disconnect and retirement checks.

JVM regressions cover full nonzero acceptance and rejection of zero, partial,
all-zero, stale and retired callbacks. Python regressions bind embed-v4 and the
finite V2 connection-failure marker to the exact source. The new verified embed-v4 AAR was mounted with actual schema3 FreeRDP. Root
47 Moonlight JVM tests passed with zero failures/errors/skips, and AndroidTest
Kotlin compilation passed in the combined 314-task invocation. Actual hosted
nonzero output remains an acceptance gate.

Exact run `37121179343` failed before `connectionStarted`. It does not exercise
this post-connection PCM boundary and is not evidence that this repair resolves
that failure.

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
