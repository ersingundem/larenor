# K07 trusted MQTT broker settings TDD evidence

Date: 2026-09-23

## Scope

This slice replaces the production-only hardcoded disabled broker with an
explicit, administrator-controlled local broker setting while preserving the
existing secure pairing boundary.

- Shared preferences contain only schema version, enabled state, host, port
  and the mandatory TLS flag. Pairing tokens and MQTT passwords remain in
  Android secure storage and never enter this record, UI diagnostics or URLs.
- The reader accepts the exact versioned shape only. Unknown fields, malformed
  JSON, URL/user-info/path hosts, invalid ports and non-TLS records all restore
  the disabled fail-closed default.
- Editing fields has no network effect. A separate 48 dp Save action is
  required on the current administrator route. If route, account, Core, home
  or foreground authority retires during persistence, the exact previous
  setting is restored.
- A saved setting change retires the old broker/native generation before a new
  one can start. Disabling disconnects without reconnecting. Enabling still
  requires a current verified session, exact secure enrollment, foreground
  app, two Core authority checks and the existing TLS-only egress gate.
- The editor is localized in English and Turkish and exercised at 600 and
  1280 logical pixels with 2x text.

## RED to GREEN evidence

The RED checkpoint `67115ba2` defined strict persistence, retired-write
rollback and runtime replacement behavior before the implementation existed.

```text
flutter test \
  test/features/kiosk_remote/managed_tablet_mqtt_settings_test.dart \
  test/features/kiosk_remote/managed_tablet_runtime_owner_test.dart \
  test/features/kiosk_remote/kiosk_remote_client_test.dart

00:03 +27: All tests passed!

flutter analyze lib/features/kiosk_remote test/features/kiosk_remote
No issues found!

git diff --check
(no output)
```

## Final K07 status

K07 software acceptance is `done`; queue and selected-feature counters are
**29/125 (23.2%)** and **0/63 (0.0%)**. Native lock plus retained Dart
refresh/profile effects and the live TLS ACL/ACK fixture are automated. A real
Mosquitto deployment and physical Huawei/DeX/keyboard/TalkBack evidence remain
MANUAL. See [`k07-software-acceptance.tdd.md`](k07-software-acceptance.tdd.md).
