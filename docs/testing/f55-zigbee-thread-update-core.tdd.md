# F55 Zigbee/Thread network and update Core acceptance

This package establishes a fail-closed Core foundation for read-only Zigbee
and Thread diagnostics plus explicitly supported Zigbee OTA. Queue progress
remains at 21/125 and selected-feature progress remains at 0/63. Durable command
storage, authenticated HTTP APIs, coordinator backup/restore, production radio
workers, Android tablet UI, and physical device validation remain open delivery
gates; Thread health does not claim Matter ownership or universal Thread OTA.

Exactly three user acceptance criteria are in scope:

1. A user can inspect coordinator, border-router, device, and interference
   health only when the exact Core, home, account, session, topology, provider,
   node, device, route, and interference revisions still match. Channel advice
   is read-only and never applies a radio change.
2. A supported Zigbee firmware preview requires an unexpired Ed25519-signed
   catalog, exact catalog and provider revisions, SHA-256 digest, newer semantic
   version, matching manufacturer/model/hardware/source version, a safe route,
   and sufficient mains or battery power. Thread OTA and incompatible targets
   fail closed.
3. An administrator must preview and explicitly confirm an OTA command. Success
   requires exact device, provider, route, version, and digest readback; a lost
   acknowledgement becomes uncertain and is never replayed in-process, while a
   broken HMAC audit chain blocks every later effect.

## TDD evidence

The RED commit `e5f52322` failed collection because the
`larenor_server.mesh_center` package did not exist. The GREEN matrix contains
exactly three focused tests covering nested topology drift and channel advice,
signed catalog/compatibility/power/route boundaries, and confirmed or uncertain
OTA outcomes with idempotency, exception redaction, and audit tamper rejection.

## Production provider and restart follow-up (2026-09-30)

The normal Core route previously existed only when a test or embedding caller
injected `MeshCenterProvider`. The first concrete production slice now projects
Zigbee2MQTT retained `bridge/state`, `bridge/info`, `bridge/devices`, device
state, and availability evidence without inventing facts the provider did not
report. Unknown routes, last-seen time, firmware version, battery charge, and
channel interference remain explicitly unavailable; the provider publishes an
empty signed catalog and therefore cannot dispatch OTA until exact image bytes,
size, digest, compatibility, and post-install readback are available.

This follows the official Zigbee2MQTT contracts: bridge state and device
inventory are retained, per-device availability is optional, request/response
transactions can correlate explicit commands, and network-map collection is a
manual scan that can reduce network responsiveness for 10 seconds to 2 minutes.
It is not run during the normal read path. Home Assistant's official Thread
documentation also describes Thread as the network protocol rather than the
device control protocol, and says its Thread integration remains work in
progress, so this slice does not claim Matter ownership or Thread OTA.

OTA durability now persists a `dispatched` audit entry and dispatch timestamp
before calling the irreversible worker. If Core exits after that point without
an exact result, startup persists `lost_ack`/`uncertain`; a later confirmation
returns that result and never calls the worker again.

Focused evidence:

- `server/.venv/bin/pytest -q server/tests/test_f55_zigbee2mqtt_provider.py server/tests/test_f55_zigbee_thread_update_center.py server/tests/test_f55_mesh_center_api.py server/tests/test_f55_mesh_center_runtime.py` — 15 passed.
- `flutter test test/features/mesh_center/mesh_center_management_test.dart test/features/mesh_center/mesh_center_http_api_test.dart` — 8 passed.
- `flutter analyze lib/features/mesh_center test/features/mesh_center` — no issues.

The bounded MQTT wire reader, broker credential provisioning, and default Core
composition remain the next software gate. No physical coordinator, border
router, or device was mutated by this evidence run.

## Bounded MQTT and normal Core composition follow-up (2026-09-30)

The normal server now enables Mesh Center only after its private worker proves
a current broker connection with a transaction-matched, non-retained
`bridge/response/health_check` response and receives retained
`bridge/state`, `bridge/info`, and `bridge/devices`. The worker subscribes only
to the configured fixed Zigbee2MQTT base prefix, never requests a network map,
and exposes only bounded retained observation bytes to Core over a UID-checked
Unix socket. Broker addresses are exact numeric egress pins; credentials are
read from owner-only files inside the worker and never cross IPC.

Core binds that observation to the authenticated administrator's current user,
session-family, Core, and home revisions. The concrete provider still advertises
an empty signed catalog and `canUpdateMesh=false`, so this production slice
does not imply OTA support. A configured socket without a current broker health
proof leaves the public capability unavailable rather than synthesizing a
topology. The Home Assistant Thread limitation above is unchanged: this Zigbee
inventory path does not claim a Thread or Matter control provider.

Runtime configuration uses `LARENOR_MESH_WORKER_SOCKET` and
`LARENOR_MESH_WORKER_UID` in Core. The worker additionally requires
`LARENOR_MESH_CORE_UID`, `LARENOR_MESH_MQTT_URL`,
`LARENOR_MESH_MQTT_ALLOWED_ADDRESSES`, and optional paired owner-only
`LARENOR_MESH_MQTT_USERNAME_FILE` / `LARENOR_MESH_MQTT_PASSWORD_FILE` values.

Focused evidence:

- `server/.venv/bin/pytest -q server/tests/test_f55_mesh_center_api.py server/tests/test_f55_mesh_center_runtime.py server/tests/test_f55_mesh_mqtt_transport.py server/tests/test_f55_mesh_worker_ipc.py server/tests/test_f55_zigbee2mqtt_provider.py server/tests/test_f55_zigbee_thread_update_center.py server/tests/test_runtime.py` — 51 passed.
- `server/.venv/bin/python -m compileall -q server/larenor_server/mesh_center server/larenor_server/app.py server/larenor_server/config.py server/larenor_server/core.py server/larenor_server/runtime.py` — passed.
- No broker, coordinator, border router, or end device was contacted or mutated;
  wire behavior was exercised against a deterministic scripted broker.
