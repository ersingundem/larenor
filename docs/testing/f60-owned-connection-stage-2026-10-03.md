# F60 owned connection-stage classification — 2026-10-03

## Actual boundary

Exact run `37121179343` executed the original named Android test once with one
failure, zero errors and zero skips. Its source-bound receipt records a visible
owned Game, a positive Surface callback, connection stages started and
completed, then `stageFailed=true` before `connectionStarted`. This proves a
pre-connection stage failure. It does not identify the failed stage or its
cause, and it does not prove an output, provider or lifecycle defect by itself.

## Pinned source model

Pinned Moonlight Android 12.2 has two stage producers:

- `NvConnection.start()` reports the selected app name while starting the
  provider session. It can fail with no code, an HTTP response code, or the
  fixed TCP-port flags used by its I/O catch.
- moonlight-common-c reports one of eleven stable `LiGetStageName()` values:
  platform initialization, name resolution, audio initialization, RTSP
  handshake, control/video/input initialization, then control/video/audio/input
  establishment.

`MoonBridge.bridgeClStageFailed()` converts the native stage to that stable
name and attaches `LiGetPortFlagsFromStage()` plus the native error integer.
`Game.stageFailed()` is therefore the authoritative boundary available to the
embedded Activity. The current receipt does not retain these arguments.

## Closed process-private diagnostic

`LarenorMoonlightGame` now converts the callback immediately to two finite
enums before passing it to the exact-token foreground registry:

- failure stage: provider launch, each of the eleven pinned native stages, or
  unclassified;
- failure signal: unspecified, transport-port flags present, reported code
  present, or both present.

The provider app name is used only for an exact private comparison and is never
retained in the snapshot. Raw stage strings, port masks, error integers,
provider text, addresses and identifiers are not retained. The first exact
failure wins; duplicate callbacks cannot rewrite the evidence. Stale,
retired and successor tokens remain unable to update the snapshot.

These signal categories describe callback fields, not causes. In particular,
transport-port flags do not prove a blocked port, and a reported code does not
prove whether the peer, protocol or local stack originated it. The
failure-only parser exposes only these wire names beside the existing six
booleans, and only for the original one-test/one-failure `firstStreamOutput`
assertion from the exact locked Android source. A malformed, duplicated,
changed-source or boolean/category-inconsistent V2 marker remains absent from
the public diagnostic.

## Verification and limits

The registry JVM regression covers every pinned stage, all four signal
combinations, provider-name precedence, unknown/null input, first-failure
retention, exact-token fencing and terminal snapshot retention. No Gradle gate
has been run for this slice yet.

This change is diagnostic only. It does not change connection ordering,
timeouts, TLS, pairing, codecs, transport, retries or output acceptance. A new
hosted run is needed to identify the finite stage for the 5122-class failure;
the source alone does not establish a repair.

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
