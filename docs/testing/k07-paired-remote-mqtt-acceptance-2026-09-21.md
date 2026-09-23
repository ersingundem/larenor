# K07 paired remote API and MQTT acceptance

Status: **software pairing, protocol and tablet management slice complete; live broker and physical-device acceptance pending**. K07 stays `pending` and progress remains **22/125** and **0/63** until a supported MQTT broker adapter and device journey pass the manual gates.

## Three accepted criteria

1. **Paired identity and authority.** A current admin can pair only an active managed tablet at its exact revision. The one-time 43-character secret is encrypted at rest, HMAC-identified, returned only for the exact idempotent create request, and omitted from inventory, discovery, URLs, logs and exports. Pairings have closed read/control/admin scopes, bounded expiry and request rates, exact-revision revoke, and fail closed after expiry or revocation. No separate remote or MQTT network listener starts by default.
2. **Replay-safe MQTT contract.** Discovery exposes a bounded four-sensor topic contract and explicitly permits retained sensor state while denying retained commands. Commands require increasing sequences, 5-minute maximum expiry and the needed scope. Byte-identical lost-ACK retries return the recorded acknowledgement without inserting or executing another command; changed requests, old sequences and conflicting completion acknowledgements fail closed. Command acceptance and ACK completion both recheck the exact pairing record, revision, active state and expiry inside their write transaction, so a changed pairing cannot win either authentication race or leave a queued command behind.
3. **Tablet management and lifecycle safety.** Display settings exposes an EN/TR pairing manager for registered tablets. Read is always selected; control/admin scopes require explicit switches. The surface lists public MQTT identity and state, creates a 30-day pairing, shows its secret once with an explicit copy action, and revokes at the exact revision. Tests cover 600/1280 logical pixels at 2x text, 48 dp actions, TalkBack live status, keyboard-compatible controls and late-result retirement when account/Core/home/session/route/lifecycle authority changes.

## Automated evidence

- `python -m pytest -q server/tests/test_k07_paired_remote_mqtt.py server/tests/test_tablet_fleet.py server/tests/test_f53_tablet_fleet_policy.py` — 11 passed, including the revocation/ACK race.
- `flutter test test/features/kiosk_remote/kiosk_remote_client_test.dart test/features/kiosk_remote/kiosk_remote_http_test.dart` — 6 passed.
- Targeted Flutter analyze, Ruff/compile, security policy, execution queue, progress policy, diff, merge-tree and redacted gitleaks are required before publication.

## Remaining gates

- Connect a supported local MQTT broker through an explicit component-egress permission and prove TLS/client identity, reconnect and broker restart behavior. The current slice defines and persists the transport-neutral envelopes but does not claim a live broker connection.
- Publish real Android battery/network/app/kiosk sensor readings and consume command acknowledgements from the managed tablet runtime.
- Verify broker loss, Huawei background behavior, Samsung DeX resize and physical keyboard/TalkBack on hardware.
