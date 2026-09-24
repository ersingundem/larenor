# K07 explicit secure enrollment TDD evidence

Date: 2026-09-23

## Guarantee

Creating a Core pairing only reveals its one-time secret. It does not silently
turn the current Android process into that managed tablet. A current
administrator must choose **Use on this tablet** before Larenor stores the
secret and binds it to the exact server, Core, home, account, device, pairing
revision and MQTT identities.

The runtime owner accepts enrollment only while that exact binding, route and
app foreground are current. It retires the previous runtime before the secure
write and rechecks all three boundaries after the write and during runtime
startup. A retired operation removes only the exact written enrollment,
including its revision and token identity; it cannot delete a newer revision
of the same pairing. The one-time secret is then removed from UI state.
Revocation continues to clear only the matching secure enrollment.

The confirmation is a separate EN/TR 48 dp action. It provides a live success
message and remains absent when the route has no trusted enrollment callback.
Copying the one-time secret does not enroll the tablet.

## RED to GREEN evidence

The RED checkpoint `a0d1bf1b` added compile-time tests for the missing explicit
controller action and exact-binding runtime-owner entry point. The GREEN change
wires the route's verified `ServerSession` into `ManagedTabletEnrollment`, adds
the separate tablet confirmation UI, and preserves fail-closed generation and
lifecycle checks. Follow-up RED `259c2820` reproduces route retirement during a
delayed secure write and same-pairing replacement cleanup; the GREEN fix carries
the route guard through authority, egress and broker startup.

```text
flutter test test/features/kiosk_remote/kiosk_remote_client_test.dart \
  test/features/kiosk_remote/managed_tablet_runtime_owner_test.dart \
  test/features/kiosk_remote/managed_tablet_credential_store_test.dart

00:00 +26: All tests passed!

flutter analyze lib/features/kiosk_remote test/features/kiosk_remote
No issues found!
```

## Final K07 status

The production TLS broker setting, live TLS ACL/ACK fixture, native lock and
retained Dart refresh/profile commands now complete the automated chain. K07
software acceptance is `done` at **29/125 (23.2%)**. Real broker deployment,
Huawei background behavior, Samsung DeX, physical keyboard, TalkBack and OEM/DPC
policy delivery remain MANUAL.
