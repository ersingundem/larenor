# F43 real camera provider and Client/Core evidence — 2026-09-30

Normal Core now composes the camera gateway with its private Home Assistant
adapter. An administrator explicitly selects an existing presence resource,
room and Frigate recording/detection resource pair in the Flutter profile's
source settings. Saving bindings performs reads and revision CAS; it does not
change a camera.

The adapter verifies the live HA entity registry: enabled `platform=frigate`,
same config entry/device, and matching official recording/detection unique IDs.
Each action rechecks current administrator/session, resource ACLs, service and
binding revisions. Credentials stay inside Core's encrypted service record.
Actual `switch.turn_on`/`turn_off` commands are followed by state GET polling;
the service acknowledgement alone never establishes completion.

Encrypted durable command intent is saved before a single dispatch. A partial
change, lost acknowledgement or process interruption remains unknown and cannot
be replayed. The settings screen exposes a separately confirmed read-only
reconciliation: two matching current observations clear the camera interlock for
a new explicit action. The original unknown command remains non-replayable.
The sealed inventory detects deletion or corruption of stored command records.
The operation budget is finite, including provenance reads and polling.

## Primary integration sources

- [Official Frigate HA switch implementation](https://github.com/blakeblackshear/frigate-hass-integration/blob/master/custom_components/frigate/switch.py)
- [Official Frigate integration identity helper](https://github.com/blakeblackshear/frigate-hass-integration/blob/master/custom_components/frigate/__init__.py)
- [Home Assistant REST service calls](https://developers.home-assistant.io/docs/api/rest/)
- [Home Assistant WebSocket authentication](https://developers.home-assistant.io/docs/api/websocket/)
- [Frigate Home Assistant integration prerequisites](https://docs.frigate.video/integrations/home-assistant/)

Frigate's switches publish MQTT commands and update from observed MQTT state.
Disabling recording/detection does not turn off a microphone, camera hardware
or another recorder; every Core snapshot and Client receipt preserves that
boundary.

## Executed automated gates

```text
PYTHONPATH=server server/.venv/bin/pytest -q \
  server/tests/test_f43_camera_ha_normal_core.py \
  server/tests/test_f43_camera_recording_profile.py \
  server/tests/test_f43_camera_profile_http.py
# 19 passed

flutter test \
  test/features/camera_profiles/camera_profile_http_api_test.dart \
  test/features/camera_profiles/camera_profile_client_test.dart
# 11 passed

PYTHONPATH=server server/.venv/bin/python \
  server/tests/support/f43_flutter_acceptance.py
# 1 real Flutter Client → normal Core → HA TCP/WebSocket gate passed
```

The last gate starts normal `create_app` and Uvicorn, signs in through the
production Flutter account/API, reads configured sources, returns to a fresh
profile route, applies both switches, observes readback, and restores both.
Exactly four actual external service commands occur. Only the external HA
installation is replaced by an isolated loopback protocol fixture; Core
composition, routes, authority checks, dispatch and receipts are real.

The regular Flutter suite explicitly skips this external-process gate unless
the runner supplies its isolated Core URL. That skip is not acceptance evidence.
Full feature matrix, CI execution on the final exact HEAD and the separately
tracked physical Frigate/device gate remain open. No household device was
modified during these tests.
