# Wellbeing unsupported-SDK eligibility with the real product manifest

Date: 2026-10-01

The earlier source-bound dual-native broad JVM run failed before executing
`WellbeingBridgeTest.api26IsExplicitlyUnavailableWithoutAnyClientOrPermissionUi`.
Robolectric configured an API 26 package parser, while the actual combined product
manifest requires minimum SDK 29. The retained RED exception identifies the
manifest minimum-SDK rejection; this was not a failed Health Connect permission
or provider operation.

The test keeps the product-compatible API 35 framework/manifest harness, then
changes only the reported `Build.VERSION.SDK_INT` for the unsupported-SDK
eligibility branch. It exercises the production backend and bridge probe,
read-permission request and settings path. Each reports unavailable and no
permission/settings activity is launched. The original reported SDK is restored
in cleanup, including construction failure. Production code and manifest remain
unchanged. This does not claim an installed API 26 product APK or physical health
provider acceptance.

The agent reproduced RED, passed the exact named test, then passed all eight
WellbeingBridgeTest cases. Root independently ran the entire actual JVM suite:

```text
cd android
JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home \
GRADLE_USER_HOME=/private/tmp/larenor-wellbeing-api26/gradle \
LARENOR_PRODUCT_NATIVE_ENGINES=required \
./gradlew :app:testDebugUnitTest --no-daemon --console=plain \
  -x :app:compileFlutterBuildDebug
```

Result: **338 total, 336 passed, 2 skipped, 0 failures, 0 errors**. Existing Flutter
build output was reused; this is a JVM regression gate, not a new APK build.
Required source-bound native packages were installed and verified separately.
Root private log: `/private/tmp/larenor-product-jvm-root-green.log`.

The two opt-in cases skipped in this local invocation are:

- `VncTigerVncAcceptanceTest.normalBridgeInteroperatesWithOwnedTigerVncAndRetiresWithoutReplay`
- `LocalNotificationNormalCoreWorkerTest.scheduledWorkerPullSealsCursorRestartsWithoutDuplicateAndClearsOnCoreRevoke`

Their owned-provider/normal-Core acceptance runners must supply their named
inputs. This local skip is not new acceptance for either flow. Broad latest-HEAD
hosted CI and F60/F62 real runtime gates remain open.
