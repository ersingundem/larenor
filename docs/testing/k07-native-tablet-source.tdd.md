# K07 native managed-tablet source TDD evidence

Source: the Android telemetry and lifecycle gap recorded in
`k07-mqtt-runtime.tdd.md`. This dependent slice starts from
`origin/codex/k07-mqtt-runtime` at `8ec15621`; that historical slice did not
change queue counts. Later K07 closure evidence is recorded separately.

## User journeys

1. Installing or launching Larenor does not start native collection. The
   source must be explicitly enabled and bound to a current session scope.
2. An active foreground session exposes only bounded battery percentage,
   coarse network kind, app version, app foreground state and kiosk lock state.
   It never reads or returns an SSID, URL, token, password or arbitrary native
   metadata.
3. Android pause, Flutter lifecycle retirement, or a new account/Core/home/
   session scope retires the old session. A late platform reply is discarded,
   and the old command-executor lease loses authority.
4. This slice never performs a device command. Its active executor reports
   `unsupported`; a retired executor reports `denied`.

## RED and GREEN

| Guarantee | RED evidence | GREEN evidence |
| --- | --- | --- |
| Flutter production port exists | `flutter test test/features/kiosk_remote/native_managed_tablet_source_test.dart` failed to compile because `native_managed_tablet_source.dart` and its types were absent | The focused Flutter matrix passes 26 tests, including 6 source-port tests and 10 runtime race/failure tests |
| Android bridge and bounded host exist | `:app:compileDebugUnitTestKotlin` failed with unresolved `ManagedTabletSourceBridge`, `ManagedTabletSnapshotHost`, and `ManagedTabletNativeSnapshot` references | The focused Robolectric class passes 4 tests |
| Scope/lifecycle retirement is fail closed | The late-result and old-executor tests could not compile before the port existed | A held snapshot is rejected after rebinding; stale stop cannot retire a newer native session; pause retires the native session |
| Payload is bounded and secret-free | Invalid-field, extra-field and secret-bearing argument tests could not compile before the contract existed | Both platforms enforce exact key sets, closed enums and length/range limits; wire tests assert no token or URL surface |

## Implemented boundary

- `AndroidManagedTabletSnapshotHost` reads battery percentage, transport class,
  package version and lock-task state from Android system services. It does not
  request permissions or inspect network identity.
- `ManagedTabletSourceBridge` is attached to `MainActivity`; `onPause` and
  engine cleanup retire the session. The method channel remains inert until an
  explicit enabled start with a bounded session id and scope.
- `NativeManagedTabletSource` owns one generation-scoped lease. Rebinding or
  foreground loss invalidates it before awaiting native cleanup, so late
  replies and stale executors cannot regain authority.
- The runtime publishes `app_foreground` as a fifth retained, bounded telemetry
  topic. Server discovery names the same five-topic contract.

## Verification

- `flutter test test/features/kiosk_remote/native_managed_tablet_source_test.dart test/features/kiosk_remote/kiosk_remote_mqtt_runtime_test.dart`
  — 26 passed; the two runtime files have **398/427 (93.2%)** combined line
  coverage.
- `./android/gradlew -p android :app:testDebugUnitTest --tests com.ersingundem.larenor.kioskremote.ManagedTabletSourceBridgeTest`
  — 4 passed with Robolectric 4.17 / API 35.
- `uv run pytest -q tests/test_k07_paired_remote_mqtt.py`
  — validates the exact five-topic discovery contract.

## Final K07 status

Secure pairing credentials, current Core/component-egress authority, runtime
ownership and native lock plus retained Dart refresh/profile commands are now
production-bound and automated. K07 software acceptance is `done` at 29/125.
Real broker deployment, Huawei process death, DeX, keyboard and TalkBack remain
MANUAL. See [`k07-software-acceptance.tdd.md`](k07-software-acceptance.tdd.md).
