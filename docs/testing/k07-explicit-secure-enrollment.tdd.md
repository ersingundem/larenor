# K07 explicit secure enrollment TDD evidence

Date: 2026-09-23

## Guarantee

Creating a Core pairing only reveals its one-time secret. It does not silently
turn the current Android process into that managed tablet. A current
administrator must choose **Use on this tablet** before Larenor stores the
secret and binds it to the exact server, Core, home, account, device, pairing
revision and MQTT identities.

The runtime owner accepts enrollment only while that exact binding is current
and the app is in the foreground. It retires the previous runtime before the
secure write, rechecks authority after the write, and removes the exact written
record if the session or lifecycle changes during the operation. The one-time
secret is then removed from UI state. Revocation continues to clear only the
matching secure enrollment.

The confirmation is a separate EN/TR 48 dp action. It provides a live success
message and remains absent when the route has no trusted enrollment callback.
Copying the one-time secret does not enroll the tablet.

## RED to GREEN evidence

The RED checkpoint `a0d1bf1b` added compile-time tests for the missing explicit
controller action and exact-binding runtime-owner entry point. The GREEN change
wires the route's verified `ServerSession` into `ManagedTabletEnrollment`, adds
the separate tablet confirmation UI, and preserves fail-closed generation and
lifecycle checks.

```text
flutter test test/features/kiosk_remote/kiosk_remote_client_test.dart \
  test/features/kiosk_remote/managed_tablet_runtime_owner_test.dart \
  test/features/kiosk_remote/managed_tablet_credential_store_test.dart

00:00 +24: All tests passed!

flutter analyze lib/features/kiosk_remote test/features/kiosk_remote
No issues found!
```

## Remaining K07 gates

K07 remains `pending`; this slice does not change either progress counter. The
production broker setting is still disabled until a trusted Core-managed TLS
broker configuration exists. Live Mosquitto ACL/TLS acceptance, native Android
device identity and bounded command authority, broker-loss recovery, Huawei
background behavior, Samsung DeX resize, physical keyboard and TalkBack remain
manual or later software gates.
