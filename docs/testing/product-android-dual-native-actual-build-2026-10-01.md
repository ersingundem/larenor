# Android dual-native product build evidence (2026-10-01)

This gate built one debug product APK containing the current reviewed Moonlight
and FreeRDP engines for `arm64-v8a` and `x86_64`. It did not use a household
device, publish an artifact, sign a release, or establish provider runtime
acceptance.

## Source and package identity

- Moonlight Android source commit:
  `b48494cb96bff23d8886c4775cc4f39a1075495d`
- Larenor embed patch SHA-256:
  `fecdb1c3f37b9f52eedb8186c59029a54e8d2b241d4291a762ccb34a5ec18bed`
- Current Moonlight AAR SHA-256:
  `d327a45cb669afc4a9b6bfe9ee70406471c29ab6cab546cef6554500531336c5`
- Current Moonlight receipt SHA-256:
  `6f5d5593190eaebebf2e665f55f8a0771700a9f037f567ae7a21b47f78ed6eca`
- FreeRDP engine revision:
  `freerdp-3.31.1-63b948ca-clipboard-utf8-v1`
- FreeRDP arm64-v8a AAR SHA-256:
  `b35a3ccd1191768724671a80976f4e705af38eb6128e7dcbb510a29b6a58c8d8`
- FreeRDP x86_64 AAR SHA-256:
  `03ea2f3fbee95a6ca7bd92703ac8c2d529a6a36e3edbfc890cbc6ea256cdfb2f`

The Moonlight package receipt now binds the reviewed patch identity and the
structured `Game.class` method contracts below. A previously receipted v2 AAR
that lacks these methods is rejected with `missing_engine_api`.

- protected `onConnectionStopCompleted()V`
- public `onVideoFrameRendered(JJ)V`
- public `onAudioPcmWritten(II)V`

The old installed Moonlight and FreeRDP directories, product receipt, and prior
debug APK were moved without deletion to the private quarantine at
`/private/tmp/larenor-product-native-prep/stale-install-a`. Its bounded manifest
is mode `0600`.

## Build and verification results

The build used Java 17.0.20.1, Android platform/build-tools 37, NDK
29.0.14206865, and the exact installed CMake 4.1.2. Before native packages were
installed, `LARENOR_PRODUCT_NATIVE_ENGINES=required` failed at Gradle
configuration with the named missing-package error.

After installing both current engines, one two-ABI debug APK was built:

- path: `build/app/outputs/flutter-apk/app-debug.apk`
- size: 348,127,934 bytes
- SHA-256:
  `ea17fc261ae2d34cbb0af6b5f19b6e86059b5b3733293048adf0843c188e0d8f`

`product_android_native.py verify-installed` and `verify-apk` passed. The APK
contains both native ABI payloads and the required FreeRDP, packaged RDP
runtime, Moonlight host, and Moonlight game class descriptors across 32 DEX
files. The focused JVM native contracts passed 69/69 with zero failures,
errors, or skips:

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
`/private/tmp/larenor-product-native-prep`. The debug APK is not a signed
release, and this build alone does not prove Moonlight or FreeRDP behavior
against a physical client, display, input device, Sunshine host, or RDP host.
