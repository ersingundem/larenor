# Android dual-native product build evidence (2026-10-01)

This gate built one debug product APK containing the current reviewed Moonlight
and FreeRDP engines for `arm64-v8a` and `x86_64`. It did not use a household
device, publish an artifact, sign a release, or establish provider runtime
acceptance.

## Source and package identity

- Moonlight Android source commit:
  `b48494cb96bff23d8886c4775cc4f39a1075495d`
- Larenor embed patch SHA-256:
  `85bfb0080400eff2bc05392b4ea1c05b2b72dc152cafea9716008ae2dd222e0d`
- Moonlight engine revision:
  `moonlight-android-12.2-larenor-embed-v3`
- Current Moonlight AAR SHA-256:
  `cdd17d087e86843970bd02f92ba05c10ba1d4c66970763f09e96bf77c9b208fb`
- Current Moonlight receipt SHA-256:
  `8f8bf685f8d968ed18eccd30ef0f92bafac23b323d632c8806eeaa1e4b275bcf`
- FreeRDP engine revision:
  `freerdp-3.31.1-63b948ca-clipboard-utf8-v1`
- FreeRDP arm64-v8a AAR SHA-256:
  `b35a3ccd1191768724671a80976f4e705af38eb6128e7dcbb510a29b6a58c8d8`
- FreeRDP x86_64 AAR SHA-256:
  `03ea2f3fbee95a6ca7bd92703ac8c2d529a6a36e3edbfc890cbc6ea256cdfb2f`

The Moonlight package receipt now binds the reviewed patch identity and the
structured class method contracts below. A previously receipted v2 AAR, even
when paired with a receipt shaped to claim the v3 contract, is rejected with
`missing_engine_api`.

- protected `onConnectionStopCompleted()V`
- public `onVideoFrameRendered(JJ)V`
- public `onAudioPcmWritten(II)V`
- public instance `NvHTTP.cancelPendingRequests()V`

The old installed Moonlight and FreeRDP directories, product receipt, and prior
debug APK were moved without deletion to the private quarantine at
`/private/tmp/larenor-product-native-prep/stale-install-a`. Its bounded manifest
is mode `0600`.

The immediately preceding v2 product mount was also preserved without deletion
at `/private/tmp/larenor-product-native-pre-v3-install-20261001` before the v3
product receipt was installed.

## Build and verification results

The build used Java 17.0.20.1, Android platform/build-tools 37, NDK
29.0.14206865, and the exact installed CMake 4.1.2. Before native packages were
installed, `LARENOR_PRODUCT_NATIVE_ENGINES=required` failed at Gradle
configuration with the named missing-package error.

After installing both current engines, one two-ABI debug APK was built:

- path: `build/app/outputs/flutter-apk/app-debug.apk`
- size: 348,195,710 bytes
- SHA-256:
  `0294d421804e3483bcf7665c43efa9437ddff0ecff1a94aea6aef58d6e6f67b3`
- product receipt SHA-256:
  `c2f889003efaf6a01f85d4c2b0f1a81f77ffe0bc1b9fae487fcd2964da877e02`

`product_android_native.py verify-installed` and `verify-apk` passed. The APK
contains both native ABI payloads and the required FreeRDP, packaged RDP
runtime, Moonlight host, Moonlight game, and `NvHTTP` class descriptors across
32 DEX files. It contains 22 `.so` entries for `arm64-v8a` and 21 for `x86_64`;
all five explicitly checked engine/runtime class descriptors were present.
The v3 cancellation-focused `MoonlightEmbeddedRuntimeTest` passed 40/40 with
zero failures, errors, or skips. The earlier focused product JVM contracts
passed 69/69 against the v2 package with zero failures, errors, or skips:

- `GameStreamNativeAdapterTest`: 8
- `GameStreamNativeBridgeTest`: 4
- `MoonlightEmbeddedRuntimeTest`: 33
- `RdpFreeRdpEngineTest`: 12
- `RdpFreeRdpPackageTest`: 2
- `RdpNativeBridgeTest`: 3
- `RdpNativeContractTest`: 7

The broader JVM run completed 338 tests with 335 passing, two skipped, and one
failure outside the focused native set in `WellbeingBridgeTest`. Robolectric failed while parsing
the merged package manifest for that test. This gate does not treat the broad
suite as green.

Private mode-`0600` logs and receipts are under
`/private/tmp/larenor-product-native-prep`,
`/private/tmp/larenor-f60-v3-package-20261001-a`, and
`/private/tmp/larenor-product-v3-build-20261001`. The debug APK is not a signed
release, and this build alone does not prove Moonlight or FreeRDP behavior
against a physical client, display, input device, Sunshine host, or RDP host.

The old broad JVM failure is now historical: the product-compatible unsupported-SDK wellbeing fixture was corrected. Root independently passed the broad required-package JVM gate:338total,336passed,2explicit opt-in skips,0failure/0error. [Manifest regression and exact command](wellbeing-product-manifest-regression-2026-10-01.md). This does not claim latest-HEAD hosted CI, a new APK build, or F60/F62 runtime acceptance.


## Current embed-v3 root regression

After the actual v3 APK build, root independently matched its exact hash, size, 32 DEX files and 22/21 native libraries, then passed the installed product verifier plus product, Moonlight and both FreeRDP APK verifiers. Root also passed the current broad JVM source with required product packages:

```text
JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home
GRADLE_USER_HOME=/private/tmp/larenor-wellbeing-api26/gradle
LARENOR_PRODUCT_NATIVE_ENGINES=required
./android/gradlew -p android :app:testDebugUnitTest --no-daemon --console=plain -x :app:compileFlutterBuildDebug
```

Result: **345 total, 343 passed, 2 skipped, 0 failures, 0 errors**, across 59 XML suites; BUILD SUCCESSFUL in 31s, 308 tasks (10 executed). The skipped methods are the explicit owned-TigerVNC and normal-TLS-Core/notification-worker opt-in acceptance cases; this default run does not claim those effects. The fresh actual APK build already produced Flutter JNI. The command above does not replace the separate hosted Sunshine/FreeRDP gates or a signed release. Private root log: `/private/tmp/larenor-product-v3-full-jvm-root.log`.
