# F02/F03 Home Assistant automation trace evidence

Larenor accepts a `real` automation-trial event only by reading an existing,
authenticated Home Assistant service that is already bound to the current
Larenor home resource. The bound entity must be an enabled `automation.*`
entity in Home Assistant's entity registry. A client-created event remains
`synthetic`; its source label cannot promote it to real evidence.

The provider uses the authenticated Home Assistant WebSocket API and only the
fixed read commands `config/entity_registry/list`, `trace/list` for domain
`automation`, and `trace/get` for one exact retained run. Home Assistant makes
the trace commands admin-only. Larenor checks the current actor, session,
account, Core/home context, resource permission, resource revision, binding,
service revision, and authenticated service before and after every WebSocket
request and once more in the transaction that publishes the event.

Only bounded provenance is retained: the resource, binding and service
identities and revisions, entity and registry identities, run and context
identities, occurrence time, and a SHA-256 digest of the exact trace response.
The trace body, automation configuration, changed variables and Home Assistant
attributes are never stored or returned. At most 256 summaries are accepted per
read, existing global/per-trial event limits remain in force, and the exact
service/run pair is deduplicated. If trace support is absent, the entity has
drifted, the retained run is missing, or authority changes during I/O, no real
event is published. Trial evaluation and replay remain read-only and report
zero adapter and queue writes.

Primary contracts:

- [Home Assistant WebSocket API authentication, request and error protocol](https://developers.home-assistant.io/docs/api/websocket/)
- [Home Assistant trace WebSocket command implementation](https://github.com/home-assistant/core/blob/dev/homeassistant/components/trace/websocket_api.py)
- [Home Assistant trace summary/detail models](https://github.com/home-assistant/core/blob/dev/homeassistant/components/trace/models.py)
- [Home Assistant automation trace documentation](https://www.home-assistant.io/docs/automation/troubleshooting/)

Focused verification:

```text
server/.venv/bin/pytest -q server/tests/test_f02_f03_ha_trace_provider.py server/tests/test_f01_f03_automation_final.py
python server/tests/support/f02_flutter_acceptance.py
flutter test test/features/server/server_automation_final_loopback_test.dart
flutter analyze lib/features/server/automation_trials test/features/server/server_automation_final_loopback_test.dart test/features/server/server_automation_ha_normal_core_test.dart
```

Results: 8 Server tests, 2 Flutter loopback tests and 1 actual Client→normal Core→HA WebSocket acceptance passed; scoped analyze clean. Current HEAD CI and broader software acceptance remain open.
