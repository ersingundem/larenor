# F55 Zigbee2MQTT host-worker deployment — 30 September 2026

The normal unified deployment now binds Mesh Center to a dedicated host worker
instead of leaving `Core.mesh_center` unavailable. The Core container connects
to `/run/larenor-workers/mesh/runtime.sock` as UID `10001`; the worker runs as
UID/GID `10004`, and both share only the existing IPC group `10002`. The Unix
socket is owned by `10004:10002`, has mode `0660`, and both sides verify the
kernel peer UID. The Core also verifies the socket owner, group and mode before
each request.

The worker reads one owner-only `0600` file at
`/etc/larenor-server/host-workers/mesh/runtime.json`. Its exact schema is:

```json
{
  "schemaVersion": 1,
  "broker": {
    "url": "mqtts://broker.example.internal:8883",
    "baseTopic": "zigbee2mqtt",
    "allowedAddresses": ["192.168.1.20"],
    "usernameFile": "/etc/larenor-server/host-workers/mesh/mqtt.username",
    "passwordFile": "/etc/larenor-server/host-workers/mesh/mqtt.password"
  }
}
```

The credential properties may both be `null` for a broker that authenticates by
another operator-reviewed boundary. When present, both referenced files must be
regular, single-link, worker-owned `0600` files. The hostname remains the TLS
server name while `allowedAddresses` pins the exact broker network targets; DNS
cannot redirect the worker. Configuration parsing never performs broker I/O,
and installation never creates credentials or starts services. Activation
validates the private file under the mesh identity before enabling the unit.

Observation follows Zigbee2MQTT's documented retained `bridge/state`,
`bridge/info` and `bridge/devices` topics. The live health request includes a
transaction value and accepts only its matching non-retained response; the
official request contract permits transaction correlation on bridge requests.
See [MQTT topics and messages](https://www.zigbee2mqtt.io/guide/usage/mqtt_topics_and_messages.html).
Managed OTA remains a separate explicit operation. Zigbee2MQTT documents that
an OTA check addresses an exact device and that an update can take 10–100
minutes and may reboot or reconfigure it; this deployment does not run an OTA
check or update during startup or acceptance. See
[OTA updates](https://www.zigbee2mqtt.io/information/ota_updates.html).

Focused local evidence:

- `uv run pytest tests/test_f55_mesh_worker_ipc.py
  tests/test_f55_mesh_center_runtime.py tests/test_f55_mesh_host_runtime.py
  tests/test_f55_mesh_mqtt_transport.py -q` passed **26 tests**. This includes
  a real TCP MQTT fixture through the worker Unix socket and normal configured
  Core HTTP route and verified stale-socket recovery without replacing a
  foreign path.
- `python3 -m unittest tool.tests.unified_host_worker_package_test
  tool.tests.unified_media_stack_runtime_test` passed **11 tests**.
- The hosted Linux systemd acceptance now launches the worker and Core client
  under the distinct numeric UIDs and proves one kernel-credential-bound Unix
  IPC observation. It stays gated to the isolated GitHub-hosted root runner and
  performs no household or Zigbee network write.
