# K07 secure runtime owner TDD evidence

Date: 2026-09-23

## Scope

This slice binds the existing managed-tablet MQTT runtime to a verified app
session without enabling a listener by default.

- `ManagedTabletEnrollment` binds the pairing to the exact server, Core, home,
  account and managed-tablet identity. The token is persisted only in
  `FlutterSecureStorage`; public metadata and diagnostic strings omit it.
- `CoreManagedTabletAuthority` sends the pairing token only in the
  `X-Larenor-Pairing-Token` header to the exact Core discovery endpoint. It
  rejects redirects through `ServerBoundClient`, bounds the response to 64 KiB,
  applies one total deadline across connect and response streaming, and
  validates every topic, sensor and pairing identity.
- `ManagedTabletRuntimeOwner` performs one Core authority check when resolving
  the credential and another after selecting the exact TLS broker but before
  opening the socket. Logout, account/Core/home replacement, app background,
  disposal and revoke invalidate the generation and retire the broker/native
  lease.
- `ManagedTabletRuntimeScope` is mounted at the application root and follows
  the verified `ServerAccountController` plus `AppLifecycleState`. The provider
  remains disabled by default.
- A successful admin revoke retires the matching runtime and deletes only the
  exact secure-store enrollment. An unrelated pairing ID cannot retire the
  active runtime. SharedPreferences continues to contain only bounded
  replay/rate-limit metadata.
- Account identity follows the existing `ServerUser` contract: non-empty,
  control-free and at most 128 characters. Core and home identities retain
  their exact 32-hex contract.

## RED to GREEN evidence

The focused tests were written against the secure-store, Core authority and
owner contracts before their implementations. They cover secure round-trip,
malformed records, replacement-safe deletion, header-only token transport,
typed revoke, a total response deadline under drip traffic, double Core/egress
validation, background/account retirement, delayed authority, pending broker
connect, exact revoke cleanup and non-hex account IDs through the app scope.

```text
flutter test test/features/kiosk_remote/managed_tablet_credential_store_test.dart \
  test/features/kiosk_remote/managed_tablet_runtime_owner_test.dart \
  test/features/kiosk_remote/kiosk_remote_client_test.dart \
  test/features/kiosk_remote/kiosk_remote_http_test.dart \
  test/features/kiosk_remote/kiosk_remote_mqtt_runtime_test.dart \
  test/features/kiosk_remote/native_managed_tablet_source_test.dart

00:01 +46: All tests passed!

flutter test test/core/core_logout_runtime_test.dart
00:02 +10: All tests passed!

flutter test test/features/core_ha/core_ha_activity_ui_test.dart \
  --plain-name 'backgrounded pending history cannot publish late success'
00:00 +1: All tests passed!

flutter analyze
No issues found!

git diff --check
(no output)
```

## Final K07 status

Explicit secure enrollment, trusted local TLS broker settings, Core authority,
production runtime ownership, native lock and retained Dart refresh/profile
commands now close the automated boundary. K07 is `done` at **29/125 (23.2%)**.
Real Mosquitto deployment, Huawei/DeX/TalkBack and OEM/DPC managed-hardware
validation remain MANUAL.
