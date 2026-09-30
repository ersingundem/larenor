# F55 Home Assistant Thread diagnostics evidence — 2026-09-30

## Production contract

- An administrator selects one currently authenticated `home_assistant`
  service connection. The binding stores the exact service revision and uses a
  binding revision CAS for every change.
- The encrypted binding file is installed atomically with file and directory
  `fsync`. Admin/service authority, binding CAS, and the file install share one
  `BEGIN IMMEDIATE` boundary. A corrupt, oversized, foreign-Core, or
  foreign-home record fails startup before an unbounded payload read.
- Observation uses only Home Assistant WebSocket commands
  `thread/list_datasets` and `thread/discover_routers`. Dataset TLV,
  credentials, mutation commands, Matter commissioning, and arbitrary
  WebSocket commands are outside this contract.
- The stored binding, current administrator authority, verified service record,
  endpoint, and service revision are checked before credential-bearing I/O and
  after provider readback. A change fails closed.
- HTTP and Flutter models expose bounded summaries. Raw Extended PAN IDs,
  extended addresses, border agent IDs, service credentials, and TLV bytes are
  never returned. Provider identifiers are replaced with keyed opaque IDs.
- Thread configuration and readback load independently from the Zigbee
  snapshot, so a temporary broker observation failure does not hide the
  separately backed Home Assistant Thread section.
- The Flutter route derives a separate Thread capability from the exact
  authenticated session, Core/home context, session family, and active route
  generation before any mesh request. It carries no topology or provider
  revision. A household with no Zigbee provider therefore opens the real
  Thread screen and can configure diagnostics without fabricating a mesh
  snapshot.

## Primary provider references

- Home Assistant WebSocket framing and authentication:
  <https://developers.home-assistant.io/docs/api/websocket/>
- Home Assistant's current Thread WebSocket command implementation:
  <https://github.com/home-assistant/core/blob/dev/homeassistant/components/thread/websocket_api.py>
- Home Assistant's current `_meshcop._udp.local` router discovery projection:
  <https://github.com/home-assistant/core/blob/dev/homeassistant/components/thread/discovery.py>

These APIs report Home Assistant's stored Thread datasets and mDNS-discovered
border routers. They do not provide a Thread route map or Matter device graph,
so the product makes neither claim.

## Automated evidence

```text
server/.venv/bin/pytest -q \
  server/tests/test_f55_mesh_center_api.py \
  server/tests/test_f55_mesh_center_runtime.py \
  server/tests/test_f55_mesh_mqtt_transport.py \
  server/tests/test_f55_mesh_worker_ipc.py \
  server/tests/test_f55_zigbee2mqtt_provider.py \
  server/tests/test_f55_zigbee_thread_update_center.py \
  server/tests/test_f55_managed_ota.py \
  server/tests/test_f55_managed_ota_api.py \
  server/tests/test_f55_managed_ota_transport.py \
  server/tests/test_home_assistant_read_only_websocket.py \
  server/tests/test_f55_thread_diagnostics.py \
  server/tests/test_f55_thread_diagnostics_service.py \
  server/tests/test_f55_thread_diagnostics_api.py \
  server/tests/test_f55_thread_diagnostics_normal_core.py
# 67 passed

flutter test \
  test/features/mesh_center/mesh_center_route_test.dart \
  test/features/mesh_center/mesh_center_management_test.dart \
  test/features/mesh_center/mesh_center_http_api_test.dart
# 16 passed

flutter analyze \
  lib/features/mesh_center/domain/mesh_center_models.dart \
  lib/features/mesh_center/data/mesh_center_management_api.dart \
  lib/features/mesh_center/data/mesh_center_management_controller.dart \
  lib/features/mesh_center/presentation/mesh_center_route.dart \
  lib/features/mesh_center/presentation/mesh_center_management_screen.dart \
  test/features/mesh_center/mesh_center_route_test.dart \
  test/features/mesh_center/mesh_center_management_test.dart \
  test/features/mesh_center/mesh_center_http_api_test.dart
# No issues found
```

The normal-Core WebSocket test uses `create_app`, the durable verified Services
record, the production `ThreadDiagnosticsService`, authenticated HTTP routes,
and a controlled loopback Home Assistant TCP/WebSocket protocol fixture. No
home device, real broker, Thread network, or Home Assistant instance was
mutated. The Flutter route test starts from a normal authenticated account,
returns `mesh_provider_unavailable` for both bootstrap and refresh, renders the
first management screen, persists the verified HA selection, and reads the
Thread summary over the actual admin HTTP contract.

## Manual provider gate

On an explicitly authorized Home Assistant instance with the Thread integration
and an OTBR:

1. Verify the Home Assistant service connection is authenticated, then select
   it under **Zigbee & Thread network → Thread diagnostics**.
2. Confirm the preferred network name/channel and discovered border-router
   count match Home Assistant's Thread panel.
3. Stop the OTBR or revoke the token and refresh. The view must show unavailable
   without retaining old diagnostics as current.
4. Restore the same verified service and refresh. Diagnostics must recover
   without a Core restart.
