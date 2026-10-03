# F62 microphone: composed product and owned-host gate — 3 October 2026

The frozen working tree on `c279d30f7a25cb7cd11403135b0c2ef7c1bd66a6`
passed the local product gates below. Microphone implementation is delivered;
hosted RDP runtime, remote microphone effect, SAF and Gateway acceptance remain
open. F62 stays `reworking`; this record does not increase accepted counters.

## Real package and product

The schema-4 FreeRDP identity is
`freerdp-3.31.1-63b948ca-display-pointer-audio-microphone-v4`.
Both actual ABI AARs, receipts and callback descriptors were independently
verified; [package evidence](f62-microphone-package-2026-10-03.md) records their
hashes. Root composed the pair with the existing Moonlight v4 AAR, validated it
through `tool/product_android_native.py`, and mounted the three ignored product
paths with a retained rollback. The merged FreeRDP AAR SHA-256 is
`fb2f423c6209324a3c58e69137403785d4600b7227159f72dd7ecc6f9eba740d`;
product receipt SHA-256 is
`062b9869810d2adf75837c0e83bf0540314deac743cd847117cefb650529990d`.

The final native invocation used Java 17 and
`LARENOR_PRODUCT_NATIVE_ENGINES=required`, the materialized production launcher,
`:app:testDebugUnitTest` for both RDP packages and MoonlightEmbeddedRuntimeTest,
plus `:app:compileDebugAndroidTestKotlin`. It passed **125/125 tests**:
78 RDP and 47 Moonlight, zero failures, errors or skips; Gradle reported 315
tasks and successful compilation of the actual acceptance source. Private proof
is retained under `/private/tmp/larenor-mic-v4-native-passed-ws1s04q7`.
The unchanged 37-file source-manifest SHA-256 is
`3aa3c80bdd33c029cd9dbd6805b2c37d2d665e1d7f1b5a7c58aadf08cb3479dc`;
the Gradle-log SHA-256 is
`581e549df2bf5b9bcaee9697a02e0b89d17b1e59a3edf30758d7f9739424e071`.

Root independently ran `flutter test --reporter=json
test/features/remote_access/rdp`: **105/105**, zero skips, terminal success.
Scoped analysis was clean. Private proof is retained under
`/private/tmp/larenor-mic-v4-flutter-gate-govrtx8d`; its unchanged 16-file manifest
SHA-256 is `989999e6e933765577c12929a473d104afe9a5e2f38423a13d3f0801d916b9e6`.
Test-log SHA-256 is
`b10c06f4ec5c203fda5ec560e9741d7f129708e23fcdbf0a3d61cef0654a2d9f`;
analysis-log SHA-256 is
`9e1a15605c7853186255559effc0d425d872f16fe600598b507f5a8d31ebd3fd`.

The six portable runner/package/workflow suites passed **128 tests**; Ruff and
actionlint passed. These include real binary terminal-record parsing, exact
process identity, nonce-derived PCM generation, cancellation and stale marker
regressions. They do not constitute Linux host or emulator execution.

## Owned effect, without a physical microphone

The owned Linux fixture uses an isolated PulseAudio server with two distinct
null sinks. The emulator input is a private monitor source; output uses the
other sink. No ALSA or household device is opened. Android's documented
[`-allow-host-audio` and `adb emu avd hostmicon`](https://developer.android.com/studio/releases/emulator)
path enables that owned input. The product still uses the actual permission
broker and Activity authority; fixture instrumentation grants its exact target
UID permission before calling that broker.

The runner waits for real native microphone-open observation before a one-shot
arm and tone. The pinned server's real AUDIN Data callback must observe the
bounded, nonempty nonce-derived tone. A capture/submission counter alone cannot
satisfy this gate. The first session requires an armed matching host record;
the second has microphone disabled and requires an all-zero host record. The
existing frame, key, resize, clipboard, audio, two-session and cleanup gates
remain mandatory. No raw PCM, nonce, endpoint, credential or provider message
enters the public receipt.

The ordered third fixture patch SHA-256 is
`d561d4846bafb60356d7303362b9fcba2e7a2233002137dbef47caf3b149dc01`.
All ten prepared-source hashes passed. Full Linux fixture compilation and
actual emulator/host effects have **not** run locally and require the changed
source workflow. Physical microphone quality and Windows application input are
separate manual gates.

## Repairs found by actual execution and review

The Android SDK rejected a hidden permission listener. Production now uses
public, package-scoped
[`AppOpsManager.startWatchingMode`](https://developer.android.com/reference/android/app/AppOpsManager#startWatchingMode(java.lang.String,%20java.lang.String,%20android.app.AppOpsManager.OnOpChangedListener))
and rechecks permission, app-op and exact focused Activity before capture.
The SPKI encoder uses Java Base64; its output is tested against the real PEM.

A live partially written diagnostic marker no longer poisons all later valid
observations. Contradictory complete observations remain invalid, and an invalid
final record after writer termination still fails. This reader repair does not
establish the sole cause of the prior exact-9551 RDP failure. Its original
source-bound failed receipt remains preserved in the queue.
