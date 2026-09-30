# F55 Zigbee2MQTT provider-managed OTA evidence

Date: 2026-09-30

## Supported production contract

Zigbee2MQTT's normal OTA API does not provide image bytes, an image digest, or
a vendor signature that Larenor can verify. The existing signed firmware
catalog therefore remains empty for this provider. Zigbee2MQTT OTA uses a
separate provider-managed contract and is never described as a signed Larenor
firmware artifact.

The Core sends its opaque device ID and exact current provider revision to the
UID-private worker. The worker resolves the current retained Zigbee2MQTT
inventory back to one IEEE address and only publishes these fixed requests:

- `bridge/request/device/ota_update/check`
- `bridge/request/device/ota_update/update`

Both payloads contain only `id` and `transaction`. There is no Core/client
field for URL, file path, image bytes, hex, downgrade, schedule, or arbitrary
MQTT topic. Broker credentials remain in owner-only worker files.

The check requires an exact live non-retained transaction response, then a
fresh retained observation with `update.state=available` and numeric
`installed_version` / `latest_version`. The UI refreshes to that new provider
generation before creating a confirmation preview. Battery devices require a
known charge of at least 70%; the device and coordinator must be reachable and
fresh. A route map is not required because obtaining one is a disruptive
Zigbee2MQTT operation and is not part of the supported OTA API.

Confirmation persists the dispatch intent before worker I/O and permits one
active update. A restart with an unresolved dispatch records
`uncertain/lost_ack`; confirming or reading it never sends the update again.
Success requires the correlated update response's `from.file_version` and
`to.file_version`, followed by a fresh observation where the installed and
latest numeric versions equal the offered target. Authority and provider
generation are checked before and after I/O.

## Automated evidence

The focused suite covers the real MQTT 3.1.1 bytes over a controlled loopback
TCP broker, as well as deterministic in-memory failure cases. The loopback
config bypasses the production parser in test code because production rejects
loopback broker addresses. No physical Zigbee device or home broker is
contacted.

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
  server/tests/test_f55_managed_ota_transport.py

flutter test \
  test/features/mesh_center/mesh_center_management_test.dart \
  test/features/mesh_center/mesh_center_http_api_test.dart
```

Named assertions include fixed topic/payload allowlists, retained or mismatched
transaction rejection, post-I/O generation checks, battery policy, atomic
dispatch persistence, crash recovery without replay, admin route confirmation,
concrete Flutter HTTP serialization without firmware material, an explicit
Cupertino confirmation dialog, and exact installed-version readback.

## Primary provider sources

- Zigbee2MQTT OTA request, response, progress, battery, and duration contract:
  <https://www.zigbee2mqtt.io/guide/usage/ota_updates.html>
- Zigbee2MQTT request/response transaction contract:
  <https://www.zigbee2mqtt.io/guide/usage/mqtt_topics_and_messages.html>
- Zigbee2MQTT Home Assistant update projection source:
  <https://github.com/Koenkk/zigbee2mqtt/blob/master/lib/extension/homeassistant.ts>

## Manual physical gate

Physical acceptance remains manual. It must use a selected non-critical device
with at least 70% battery or mains power, current backups where applicable, and
an operator watching Zigbee2MQTT and the device throughout its documented
10-100 minute update window. No automated test or development run in this
slice mutates a real home device.
