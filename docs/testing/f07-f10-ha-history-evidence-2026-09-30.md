# F07/F10 Home Assistant history evidence

F07 habit anomalies and F10 evidence diagnostics now obtain production evidence
from an existing Larenor home resource bound to an authenticated Home Assistant
service. Their Flutter clients select a visible bound resource and send only its
Larenor resource ID. They no longer turn client-side service-check timestamps,
states, names, or values into real evidence.

The server verifies the current admin session, account, Core/home context,
resource ACL and revision, binding, service revision and authenticated service.
It then reads the exact enabled entity-registry entry over Home Assistant's
authenticated WebSocket API and performs one bounded REST history request for
that entity. These checks run before and after each network request and again in
the transaction that stores the derived result. The transport has an eight
second deadline, a 256 KiB response cap, no redirect, retry, proxy, cookie jar or
ambient credentials. At most 256 retained states are accepted.

F07 uses a fixed rolling 30-minute UTC window and only completed two-minute UTC
buckets. It counts actual state changes in each bucket and requires at least 13
buckets, giving the robust MAD model a real baseline in one retained-history
read. The initial state supplied by Home Assistant establishes the start of the
period; raw state strings and attributes are not returned or stored. Each real
bucket stores a sealed provenance record and deterministic resource/time key, so
overlapping refreshes do not duplicate baseline samples. Existing schema-v1
observations and feedback migrate transactionally to schema v2 as explicitly
synthetic records.

F10 retains only source identity/revisions, time bounds, sample count and
SHA-256 digests. A literal current `unavailable` or `unknown` state remains
limited evidence; any other domain-specific state is reported as unknown rather
than inferred healthy. The public arbitrary-source endpoint remains available
for simulations, but the server labels every such source `synthetic`, adds an
explicit `synthetic_source_unverified` unknown and cannot return supported
certainty from it. Repair output remains preview-only and cannot execute.

If history or entity-registry support is absent, history is empty or malformed,
the service is not authenticated, or authority changes during I/O, the request
fails without persisting a real observation or diagnosis. Home Assistant raw
attributes, state values, service URLs and credentials never appear in public
results.

Primary contracts:

- [Home Assistant REST history endpoint and bearer authentication](https://developers.home-assistant.io/docs/api/rest/)
- [Home Assistant WebSocket authentication and request protocol](https://developers.home-assistant.io/docs/api/websocket/)
- [Home Assistant history WebSocket/recorder implementation](https://github.com/home-assistant/core/blob/dev/homeassistant/components/history/websocket_api.py)

Focused verification:

```text
server/.venv/bin/pytest -q server/tests/test_f07_habit_anomalies_final.py server/tests/test_f07_ha_history_provider.py server/tests/test_f08_f11_final.py server/tests/test_f10_ha_history_diagnostics.py
server/.venv/bin/python server/tests/support/f07_f10_flutter_acceptance.py
flutter test test/features/server/server_habit_anomaly_core_loopback_test.dart
flutter test test/features/server/server_ai_f08_f11_core_loopback_test.dart --plain-name 'F10 diagnostic client reads HA history and gets preview-only repair'
flutter analyze lib/features/server/habit_anomalies lib/features/server/evidence_diagnostics test/features/server/server_habit_anomaly_core_loopback_test.dart test/features/server/server_ai_f08_f11_core_loopback_test.dart test/features/server/server_ha_evidence_normal_core_test.dart
```
