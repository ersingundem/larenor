# K07 managed-tablet MQTT runtime TDD evidence

Source: the K07 acceptance row in `docs/execution-queue.json` and the remaining
broker/runtime gates in
`docs/testing/k07-paired-remote-mqtt-acceptance-2026-09-21.md`. This is a
narrow software slice from `origin/main` `54abbf34`; K07 remains pending.

## User journeys

1. A managed tablet does not open a network connection until an administrator
   explicitly enables a local broker configuration.
2. An active read-scoped pairing publishes bounded battery, network, app
   version and kiosk state telemetry without putting its token in a URL, log or
   public metadata.
3. A control/admin pairing consumes only its own non-retained command topic,
   acknowledges the result, and never executes a duplicate after a lost ACK,
   reconnect or process restart.
4. Broker reconnect, pairing revision change, expiry and revocation recheck
   authority before a new socket or device effect. A command left pending by a
   process death becomes `execution_unconfirmed`; it is not executed again.

## RED and GREEN

| Guarantee | RED evidence | GREEN evidence |
| --- | --- | --- |
| Managed-tablet runtime and broker port exist | `flutter test test/features/kiosk_remote/kiosk_remote_mqtt_runtime_test.dart` at `9417b0ae` failed to compile because both runtime modules were absent | The same target passes 16 tests |
| Discovery names command and ACK topics | `uv run pytest -q tests/test_k07_paired_remote_mqtt.py` at `9417b0ae` failed with `KeyError: 'commandTopic'` | The focused Server matrix passes 11 tests |
| Restart/replay/rate-limit/revoke behavior is durable | New runtime tests fail before the runtime types exist | Runtime test recreates the owner with the same state store, rejects changed/old/rate-limited commands, and proves one device effect |
| Token stays out of URL/log/export surfaces | New default-disabled and broker-settings tests fail before the credential/settings types exist | Public metadata and diagnostic strings are token-free, broker logging is disabled, and credential-bearing host strings are rejected |

## Implemented boundary

- `MqttClientLocalBroker` uses MQTT 3.1.1 over TLS, passes client identity and
  token separately from the host, disables package payload logging, and leaves
  reconnect to the authority-owning runtime.
- Every connect/reconnect calls the required egress authorizer before opening a
  socket. The runtime starts disabled unless configuration explicitly enables
  it.
- Telemetry uses retained state on five bounded topics. Commands and ACKs are
  non-retained. Read pairings never subscribe; `lockKiosk` requires admin.
- SharedPreferences persists only command sequence, digest, result and bounded
  rate timestamps. It never stores broker credentials. The pairing secret must
  be supplied by the existing secure credential boundary.
- Start, reconnect, disconnect, command and telemetry callbacks carry a runtime
  generation. Retirement wins over delayed authority, egress, connect and
  telemetry work. A late connect is disconnected again, and any subscribe or
  initial telemetry failure closes the partial broker connection.
- Connect and reconnect attempts share one serialized Future chain. A newer
  generation waits until the stale attempt has completed cleanup before it can
  reuse the broker, so stale disconnect cannot close the replacement socket.

## Verification

- `flutter test --coverage test/features/kiosk_remote/kiosk_remote_mqtt_runtime_test.dart`
  — 16 passed; runtime line coverage **297/312 (95.2%)**. The external package
  socket glue is excluded from unit coverage and remains a live-broker gate.
- `flutter test test/features/kiosk_remote/kiosk_remote_mqtt_runtime_test.dart test/features/kiosk_remote/kiosk_remote_client_test.dart test/features/kiosk_remote/kiosk_remote_http_test.dart`
  — 11 passed.
- `uv run pytest -q tests/test_k07_paired_remote_mqtt.py tests/test_tablet_fleet.py tests/test_f53_tablet_fleet_policy.py`
  — 11 passed.
- `flutter analyze lib/features/kiosk_remote/runtime test/features/kiosk_remote/kiosk_remote_mqtt_runtime_test.dart`
  — no issues.

## Remaining K07 gates

- Wire the runtime into the app/session lifecycle with secure pairing-token
  retrieval and a current Core authority reader. The real Android telemetry
  source is implemented in `k07-native-tablet-source.tdd.md`; native command
  execution intentionally remains disabled.
- Run a real local Mosquitto TLS/ACL fixture and physical broker restart test;
  the adapter is concrete, but this slice tests the broker boundary through a
  deterministic port.
- Verify Huawei background/process-death behavior and Samsung DeX/keyboard/
  TalkBack behavior on physical tablets. K07 must not move to `done` until
  these gates and exact-head CI pass.
