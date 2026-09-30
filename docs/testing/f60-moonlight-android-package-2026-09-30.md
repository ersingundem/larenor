# F60 embedded Moonlight Android package evidence — 2026-09-30

## Result

The Moonlight engine can be embedded in the Larenor APK as a private Android
library. This slice proves the source-to-AAR transformation and an independent
AAR-to-APK link. It does **not** enable the product capability: Larenor still
needs an authenticated native adapter, pairing flow, credential lifecycle, and
normal Client/Core acceptance before `available=true` is truthful.

The transformation keeps Moonlight's production pairing, certificate/key,
computer database, stream protocol, MediaCodec, audio, and input code. It only
changes application packaging: `com.android.application` becomes
`com.android.library`, the standalone launcher and exported entry points are
removed, consumer-safe keep rules are supplied, and the output is limited to
the arm64-v8a and x86_64 ABIs used by Larenor's Android/device and emulator
gates.

## Pinned source and toolchain

`android/moonlight/source-lock.json` is the machine-readable authority. It
contains no branch or floating tag.

| Source | Exact revision |
| --- | --- |
| [Moonlight Android](https://github.com/moonlight-stream/moonlight-android) | `b48494cb96bff23d8886c4775cc4f39a1075495d` (`12.2`) |
| [moonlight-common-c](https://github.com/moonlight-stream/moonlight-common-c) | `874ac9548f1bd6f095ef2b435c42cdde460e7821` |
| [ENet](https://github.com/cgutman/enet) | `aca87840b57f045a1f7f9299e4b1b9b8e2a5e2f1` |
| [nanors](https://github.com/sleepybishop/nanors) | `b1e3c22ca0cdc0bb83e3cd6ed1a2fc77869ed99a` |

The build uses Java 17, Android Gradle Plugin 9.4.0, Gradle 9.7.1,
compile SDK 37.0, and NDK 29.0.14206865. The transform patch SHA-256 is
`06cc81c69805eb92fed2becd14a1c3f38f30e80ac150ace1a9abca88de39b347`.
The linker emits the exact Moonlight commit as the ELF build ID, which removed
the only varying bytes seen in two otherwise identical clean native builds.

The v2 transform also adds one protected callback immediately after the actual
`NvConnection.stop()` call returns. This is a causal local-stop observation,
not an Activity lifecycle shortcut. It is required because the pinned
moonlight-common-c sets `alreadyTerminated` in `LiStopConnection()` and
therefore deliberately suppresses the ordinary `connectionTerminated`
callback for a local stop. The packaging verifier rejects a transformed source
tree that omits either the call site or the protected hook.

Moonlight's tree contains prebuilt OpenSSL and libopus archives. The lock binds
each selected ABI archive by SHA-256. OpenSSL identifies itself as 4.0.2. The
libopus archive reports `unknown`, so the package deliberately records
`unknown-upstream-prebuilt` rather than inventing a source version. Applicable
GPL, MIT, Apache-2.0, and BSD-3-Clause notices and upstream source locations are
listed in `android/moonlight/NOTICE.md`.

## Actual build evidence

The exact recursive checkout was made under
`/tmp/larenor-f60-upstream-stop`. The package tool verified the
parent commit/tree, all three recursive submodule commit/tree pairs, clean Git
state, reviewed source blob IDs, license digests, and prebuilt archive digests
before applying the locked patch.

```text
ANDROID_HOME=/opt/homebrew/share/android-commandlinetools \
  python3 tool/moonlight_android_package.py build \
  /tmp/larenor-f60-upstream-stop \
  /tmp/larenor-f60-stop-build-v2b \
  /tmp/larenor-f60-stop-v2b.aar \
  /tmp/larenor-f60-stop-v2b-receipt.json

BUILD SUCCESSFUL in 12s
33 actionable tasks: 33 executed
```

| Artifact or payload | SHA-256 / result |
| --- | --- |
| clean v2 AAR | `15881010a5fd3fb4831e3ab17ce32cfc41721ef190b887438982b402a882f646` |
| `classes.jar` | `7daa5a4d799e71f0f72e9f5ada9e2ac224bdcc13883e28e228eadab0e64990a8` |
| arm64-v8a `libmoonlight-core.so` | `a55e143da4f20a47e8ec4e7b4c3026f76d2de43bc92a712ddcb394595119d17b` |
| x86_64 `libmoonlight-core.so` | `dcd9452d4a766c656f57fcf5697ba3ffdb6065a5951ee1f02127026f664c0202` |
| receipt | `6df3dd13f7ccd83fd556993990a89474a8eaa6b30d4e925e2c8e0a477497c6b7` |

The earlier embed-v1 byte-identical build proved deterministic packaging but
predated the causal local-stop hook. It is superseded and is not production
input. The hosted immutable pipeline creates the corresponding-source bundle
from this v2 lock and patch; no older source-bundle hash is evidence for this
artifact.

The receipt verifier opened the AAR rather than trusting its filename. It found
the exact two ABIs, ELF machine IDs, native hashes, and these concrete engine
classes in `classes.jar`:

- `Game`, `PcView`, and `AppView`;
- `PairingManager`, `NvHTTP`, and `NvConnection`;
- `ComputerDatabaseManager`;
- `MediaCodecDecoderRenderer` and `AndroidAudioRenderer`;
- `ControllerHandler` and JNI `MoonBridge`.

## Actual APK link evidence

The normal Larenor Android application consumed the produced AAR plus the seven
exact Maven dependencies listed in the lock. It did not use a companion app or
an intent handoff.

```text
flutter build apk --debug

Running Gradle task 'assembleDebug'... 18.7s
Built build/app/outputs/flutter-apk/app-debug.apk

python3 tool/moonlight_android_package.py verify-apk \
  /tmp/larenor-f60-embedded-stop-v2-final.apk \
  /tmp/larenor-f60-stop-v2-local-package-20261001/receipt.json
```

The resulting APK SHA-256 was
`26d5f24680df169232edb5a344600dcd43dd42da12f749526c7ddb6d9209f9a5`.
Verification read all 32 DEX files, required every engine descriptor, and
matched both packaged native libraries to the AAR receipt. This is build/link
proof, not a physical Sunshine stream proof.

## Focused software checks

```text
python3 -m unittest tool/tests/moonlight_android_package_test.py
......
Ran 6 tests in 0.218s
OK

python3 -m py_compile tool/moonlight_android_package.py
git diff --check -- android/moonlight \
  tool/moonlight_android_package.py \
  tool/tests/moonlight_android_package_test.py
```

The latest rerun completed all six tests with no failures. The focused tests
cover exact source/submodule identity, dirty-source refusal,
patch and manifest invariants, retention of all six engine contracts, complete
class/native receipts, extra-ABI refusal, receipt tampering, DEX presence, and
APK native hash mismatch.

## Production integration contract

The following contract is implemented by the Larenor-owned, non-exported
MethodChannel/native adapter documented in
`f60-moonlight-embedded-integration-2026-10-01.md`. The adapter uses
Moonlight's own objects rather than a parallel client implementation:

1. `PairingManager` with `AndroidCryptoProvider` starts and completes pairing,
   returns the exact server certificate/fingerprint and pair result, and never
   accepts a caller-provided certificate as truth.
2. `ComputerDatabaseManager` persists the Moonlight computer identity and
   paired certificate material. Larenor's secure store should hold only its
   opaque binding to this record, scoped to account/home/host/pairing revision.
3. `NvHTTP` rereads server info and app identity before launch;
   `NvConnection`, `Game`, `MediaCodecDecoderRenderer`,
   `AndroidAudioRenderer`, `ControllerHandler`, and `MoonBridge` provide the
   actual stream and input path.
4. Every network or native transition needs the current route/account/session,
   host revision, and pairing revision guard immediately before I/O and after
   readback. Lost acknowledgement stays uncertain and must not initiate a
   second pairing or stream.
5. Authority retirement stops the connection, clears the Larenor binding, and
   deletes/retires the matching Moonlight database/credential record without
   affecting another account or host.
6. Launching embedded `Game` cannot use the old external-handoff lifecycle.
   Today `GameStreamNativeBridge.setResumed(false)` and
   `setWindowFocused(false)` retire the adapter immediately. The integration
   needs a narrow, owned-native-foreground lease transferred from the Flutter
   route to the exact `Game` activity. `Game` lifecycle callbacks must prove
   that this lease remains visibly foreground; real background, activity
   destruction, or Core authority retirement must stop the stream and retire
   the lease. A foreign activity or stale callback cannot keep it alive.
7. Moonlight's upstream computer database is application-global. The Larenor
   binding and credential access layer must add exact Core account, home,
   family, host, and pairing-revision namespaces. A record selected under one
   namespace must be invisible to another even though the underlying upstream
   store shares an application process.

The application build must verify the AAR and receipt before including it and
declare the lock's exact BouncyCastle, JCodec, OkHttp, JmDNS,
ShieldControllerExtensions, and desugaring dependencies because a local AAR has
no Maven POM for transitive resolution. The private library manifest contributes
network, Wi-Fi multicast, wake-lock, vibration, keyboard-capture, gamepad, and
USB declarations. `PcView`, `ShortcutTrampoline`, and the poster provider are
non-exported; there is no Moonlight launcher. No runtime availability should be
advertised until the production Larenor APK passes `verify-apk` and the real
pair/start/stop/revoke acceptance path.

## Manual/provider boundary

No household Sunshine server, camera, microphone, keyboard, controller, or
display was used. A physical-provider gate still must prove PIN confirmation,
certificate continuity, decoded video, audio, input, resize/orientation,
disconnect, app restart, and revocation against an owned Sunshine fixture.
Those facts are not inferred from compilation or the isolated APK link.
