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
`afff28d9001796590a156d46e7f084f7de4710b81276d6ec91a702d9ef3443f1`.
The linker emits the exact Moonlight commit as the ELF build ID, which removed
the only varying bytes seen in two otherwise identical clean native builds.

Moonlight's tree contains prebuilt OpenSSL and libopus archives. The lock binds
each selected ABI archive by SHA-256. OpenSSL identifies itself as 4.0.2. The
libopus archive reports `unknown`, so the package deliberately records
`unknown-upstream-prebuilt` rather than inventing a source version. Applicable
GPL, MIT, Apache-2.0, and BSD-3-Clause notices and upstream source locations are
listed in `android/moonlight/NOTICE.md`.

## Actual build evidence

The exact recursive checkout was made under
`/tmp/larenor-f60-moonlight-source-20260930a`. The package tool verified the
parent commit/tree, all three recursive submodule commit/tree pairs, clean Git
state, reviewed source blob IDs, license digests, and prebuilt archive digests
before applying the locked patch.

```text
ANDROID_HOME=/opt/homebrew/share/android-commandlinetools \
  python3 tool/moonlight_android_package.py build \
  /tmp/larenor-f60-moonlight-source-20260930a \
  /tmp/larenor-f60-build-20260930f \
  /tmp/larenor-f60-f.aar \
  /tmp/larenor-f60-f.json

BUILD SUCCESSFUL in 11s
33 actionable tasks: 33 executed
```

The same command in the independent
`/tmp/larenor-f60-build-20260930g` directory produced a byte-identical AAR.

| Artifact or payload | SHA-256 / result |
| --- | --- |
| first clean AAR | `5c94690a9e8a14fe25000fdc7b916cd6711109a8762fb6d3998d9b84473190da` |
| second clean AAR | `5c94690a9e8a14fe25000fdc7b916cd6711109a8762fb6d3998d9b84473190da` |
| `classes.jar` | `6a4d143bce9f68058c5c95417363047f61348c33ae7963e875532169065d5f74` |
| arm64-v8a `libmoonlight-core.so` | `a55e143da4f20a47e8ec4e7b4c3026f76d2de43bc92a712ddcb394595119d17b` |
| x86_64 `libmoonlight-core.so` | `dcd9452d4a766c656f57fcf5697ba3ffdb6065a5951ee1f02127026f664c0202` |
| receipt | `eaf1ce0617c43160ed35976f79bd0f56e25ad450aae353c4fea1b9640fd01574` |
| complete corresponding-source bundle | `5e01d890ccdcd1536d7be29b1c7e5cdc166059aa778b87f32053be5dba610c50` |

The receipt verifier opened the AAR rather than trusting its filename. It found
the exact two ABIs, ELF machine IDs, native hashes, and these concrete engine
classes in `classes.jar`:

- `Game`, `PcView`, and `AppView`;
- `PairingManager`, `NvHTTP`, and `NvConnection`;
- `ComputerDatabaseManager`;
- `MediaCodecDecoderRenderer` and `AndroidAudioRenderer`;
- `ControllerHandler` and JNI `MoonBridge`.

## Actual APK link evidence

An isolated Android application under `/tmp/larenor-f60-host-20260930a`
consumed the produced AAR plus the seven exact Maven dependencies listed in the
lock. It did not use a companion app or an intent handoff.

```text
ANDROID_HOME=/opt/homebrew/share/android-commandlinetools \
  /tmp/larenor-f60-host-20260930a/gradlew \
  -p /tmp/larenor-f60-host-20260930a --no-daemon \
  :app:clean :app:assembleDebug

BUILD SUCCESSFUL in 10s
37 actionable tasks: 37 executed

python3 tool/moonlight_android_package.py verify-apk \
  /tmp/larenor-f60-host-20260930a/app/build/outputs/apk/debug/app-debug.apk \
  /tmp/larenor-f60-final-receipt.json
```

The resulting APK SHA-256 was
`42847c448a290792f34987447dcb2e5d2356c4849ffb7151db3031364d85c2a8`.
Verification read all six DEX files, required every engine descriptor, and
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

The focused tests cover exact source/submodule identity, dirty-source refusal,
patch and manifest invariants, retention of all six engine contracts, complete
class/native receipts, extra-ABI refusal, receipt tampering, DEX presence, and
APK native hash mismatch.

## Required production integration API

The next F60 slice should add a Larenor-owned, non-exported MethodChannel/native
adapter around the embedded code. The adapter must use Moonlight's own objects,
not a parallel client implementation:

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
