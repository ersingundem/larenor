# F57 Home Assistant MQTT room presence runtime evidence — 2026-09-30

## Supported production contract

The first production room-presence source is an authenticated Home Assistant
`mqtt_room` sensor. Home Assistant's documented contract makes the sensor state
the selected room and exposes the selected observation's `distance` attribute.
Core discovers only enabled entity-registry entries whose exact platform is
`mqtt_room`, then reads the selected entity through the authenticated states API.

The admin selects an opaque registry candidate and a current Home Resource room
while the tracked device is observed in that room. Core verifies the live state,
distance, service revision, room revision, account revision, session, and explicit
consent before encrypting the private unique ID and provider room token. The app
never receives either private value. Replacing the selected entity clears prior
provider-token mappings.

The encrypted provider binding and its privacy-reduced reducer policy commit in
one SQLite `BEGIN IMMEDIATE` transaction after live preflight completes. A reducer
registration failure rolls both records back, so a new source cannot be paired
with the previous policy. Explicit consent revocation uses an exact source-revision
CAS in the same transaction, marks the retained binding inactive, and removes all
device evidence, calibration previews, and receipts for that source. Configuration
metadata and revocation remain available while Home Assistant is offline; inactive
sources never initiate provider I/O. Re-enabling requires a fresh live candidate
discovery, preflight, and explicit consent.

Normal reads repeat the actor/session/service/resource/consent checks immediately
before and after network I/O. A fresh Home Assistant `last_updated` value is the
observation revision. Two distinct current observations are required before the
reducer reports `present`; repeats are idempotent. Outage, stale state, unknown
room tokens, changed revisions, or revoked consent make capability evidence
unavailable without fabricating absence.

All public evidence is advisory: `advisoryOnly=true`, `grantsAccess=false`. It is
never an unlock or authentication authority. Raw provider identifiers, RSSI, distance,
and location history are not exposed to Flutter or retained in public evidence.

## Deliberately unavailable sources

Generic Home Assistant `person` and `device_tracker` entities express home/zone
presence, not a verified room-ranging contract, so they are excluded. Home
Assistant Bluetooth discovery also does not define a generic authenticated room
or UWB ranging entity contract. UWB therefore remains unavailable until a named
provider offers a documented, revisioned room observation schema; no local
distance, token, or room is invented.

## Primary references

- [Home Assistant MQTT room presence](https://www.home-assistant.io/integrations/mqtt_room/)
- [Home Assistant `mqtt_room` implementation](https://github.com/home-assistant/core/blob/dev/homeassistant/components/mqtt_room/sensor.py)
- [Home Assistant WebSocket API](https://developers.home-assistant.io/docs/api/websocket/)
- [Home Assistant Bluetooth](https://www.home-assistant.io/integrations/bluetooth)
- [Home Assistant Person](https://www.home-assistant.io/integrations/person/)
- [Home Assistant device tracker](https://www.home-assistant.io/integrations/device_tracker/)

## Verification

- `server/.venv/bin/pytest -q server/tests/test_f57_room_presence_fusion.py server/tests/test_f57_room_presence_http.py server/tests/test_f57_mqtt_room_normal_core.py`
  proves reducer privacy/freshness behavior and a normal `create_app` loopback
  boundary with real WebSocket authentication, registry discovery, REST state
  reads, source replacement, transaction rollback on reducer-registration failure,
  account-session revocation before state I/O, offline exact-CAS consent revocation,
  evidence removal, encrypted restart recovery, and no HA mutation. `19 passed`.
- `flutter test test/features/room_presence`
  proves strict opaque-candidate parsing and that the inline Cupertino setup keeps
  the parent route authority through picker overlays and a save, plus the explicit
  revoke and fresh-discovery re-enable interaction. `18 passed`.
- `flutter analyze lib/features/room_presence test/features/room_presence`
  reports no issues.

Actual Client acceptance: `server/.venv/bin/python server/tests/support/f57_flutter_acceptance.py` passed 1 Flutter test through the production account APIs, normal Uvicorn Core and authenticated HA TCP/WebSocket registry/state fixture. Two distinct fresh observations moved candidate→present. After HA went offline, exact-CAS consent revoke emptied evidence with zero further upstream calls; a stale re-enable revision was rejected before provider I/O. This does not prove physical BLE ranging.
