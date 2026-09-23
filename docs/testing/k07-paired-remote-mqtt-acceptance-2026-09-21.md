# K07 paired remote API and MQTT acceptance

Status: **software pairing, protocol, tablet management and managed MQTT runtime slices complete; app lifecycle, live broker and physical-device acceptance pending**. K07 stays `pending` until the secure app wiring and manual gates pass. The runtime evidence is recorded in [`k07-mqtt-runtime.tdd.md`](k07-mqtt-runtime.tdd.md).

## Three accepted criteria

1. **Paired identity and authority.** A current admin can pair only an active managed tablet at its exact revision. The one-time 43-character secret is encrypted at rest, HMAC-identified, returned only for the exact idempotent create request, and omitted from inventory, discovery, URLs, logs and exports. Pairings have closed read/control/admin scopes, bounded expiry and request rates, exact-revision revoke, and fail closed after expiry or revocation. No separate remote or MQTT network listener starts by default.
2. **Replay-safe MQTT contract.** Discovery exposes a bounded four-sensor topic contract and explicitly permits retained sensor state while denying retained commands. Commands require increasing sequences, 5-minute maximum expiry and the needed scope. Byte-identical lost-ACK retries return the recorded acknowledgement without inserting or executing another command; changed requests, old sequences and conflicting completion acknowledgements fail closed. An ACK rechecks the pairing inside its write transaction, so revocation between token authentication and ACK storage cannot complete the command.
3. **Tablet management and lifecycle safety.** Display settings exposes an EN/TR pairing manager for registered tablets. Read is always selected; control/admin scopes require explicit switches. The surface lists public MQTT identity and state, creates a 30-day pairing, shows its secret once with an explicit copy action, and revokes at the exact revision. Tests cover 600/1280 logical pixels at 2x text, 48 dp actions, TalkBack live status, keyboard-compatible controls and late-result retirement when account/Core/home/session/route/lifecycle authority changes.

## Automated evidence

- `python -m pytest -q server/tests/test_k07_paired_remote_mqtt.py server/tests/test_tablet_fleet.py server/tests/test_f53_tablet_fleet_policy.py` — 11 passed, including the revocation/ACK race.
- `flutter test test/features/kiosk_remote/kiosk_remote_client_test.dart test/features/kiosk_remote/kiosk_remote_http_test.dart` — 6 passed.
- Targeted Flutter analyze, Ruff/compile, security policy, execution queue, progress policy, diff, merge-tree and redacted gitleaks are required before publication.

## Remaining gates

- Wire the concrete TLS MQTT adapter into the app/session lifecycle with secure pairing-token retrieval and a current component-egress grant, then prove it against a live local Mosquitto ACL/TLS fixture. The runtime rechecks egress and pairing authority before explicit reconnects, but does not claim a live broker acceptance run.
- Bind the tested telemetry and command-ACK runtime ports to real Android battery/network/app/kiosk readings and native kiosk command effects.
- Verify broker loss, Huawei background behavior, Samsung DeX resize and physical keyboard/TalkBack on hardware.
