# F54 Client to Core HTTP acceptance

Status: the pull inbox contract now crosses a real loopback HTTP socket from
`LarenorServerApi` through `LocalNotificationApi` and
`LocalNotificationController`. F54 stays open at **17/125** and **0/63** until
its Android background-delivery, runtime-permission, Huawei/OEM power and
physical-device gates are complete.

| Acceptance | Production behavior | Automated evidence |
| --- | --- | --- |
| Register, pull and acknowledgement readback | A subscription is registered for the exact authenticated Core/home/account, events are pulled in ascending sequence, and an acknowledgement is followed by a bounded pull of the exact event. The Client marks it read only when Core returns the same envelope as delivered and read. | The loopback E2E observes register → pull → acknowledgement → exact one-event readback over real HTTP. |
| Fail closed across every authority boundary | Closed response models reject the wrong Core/home, subscription revision and malformed bodies. A foreign scope returns not found, a foreign session returns unauthorized, and registration replay retains its exact typed conflict instead of becoming a generic error. | One loopback scenario exercises wrong scope response, wrong revision response, malformed response, foreign request scope, invalid bearer and exact replay conflict. No failed response enters controller events. |
| Reconnect and idempotency | A dropped socket leaves no loaded state. Explicit reconnect replays the same persisted registration safely. A late response is discarded after route-owner retirement. Pages remain ordered, and reusing one event ID at a different sequence across pages fails closed. | One loopback scenario drops the socket, reconnects, checks idempotent registration, injects a cross-page duplicate identity, then releases a delayed response after lifecycle retirement and reconnects again. |

The synthetic Core binds only to `127.0.0.1` on an ephemeral port. Tests reset
Flutter's HTTP override so `dart:io` performs real socket I/O; redirects and
non-loopback access remain governed by the production `ServerBoundClient`.

## Verification

```text
flutter test test/features/local_notifications
flutter analyze lib/features/local_notifications lib/features/server/data/larenor_server_api.dart test/features/local_notifications
uv run --project server --offline pytest -q server/tests/test_local_notifications.py
python3 tool/execution_queue.py validate
python3 tool/check_security_policy.py
gitleaks detect --no-banner --redact --source .
```
