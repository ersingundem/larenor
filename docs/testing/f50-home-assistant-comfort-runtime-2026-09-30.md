# F50 Home Assistant comfort runtime evidence — 2026-09-30

## Production contract

- The administrator persists one exact authenticated Home Assistant service
  revision, current Home Resource room/area revisions, fixed entity IDs, and
  bounded comfort policy thresholds through a revision CAS. Credentials are
  resolved privately from Services and never enter the source record or HTTP
  response.
- A configured source replaces client-authored policy/device bindings. A plan
  refresh reads temperature, humidity, CO2, VOC, smoke, occupancy, weather,
  AQI, climate mode, and cover state through fixed `/api/states/<entity>`
  requests. The client receives the resulting plan, not authority to supply
  another device or Home Assistant path.
- Clean-install setup lists only authenticated Home Assistant services and
  current Home Resource room/area records. Entity choices come from one fixed,
  bounded `config/entity_registry/list` WebSocket read. Saving re-reads every
  selected entity through the fixed state endpoint and verifies domain, unit,
  weather condition, climate modes, cover open/close support, and binary sensor
  device classes before the source CAS is allowed to commit.
- The Cupertino editor stays inside the current Room Comfort route authority.
  New configurations start with no entity or policy defaults; each value is an
  explicit administrator choice or entry. Existing configurations retain their
  exact revisions and use the same server-side live preflight on update.
- Confirm first commits a tamper-evident `dispatching` intent for every exact
  command. SQLite is released before network I/O. A crash or lost response
  leaves an uncertain intent that recovery records as `worker_ack_unknown` and
  never resends. Exact provider readback is checked against the timestamp taken
  after I/O.
- The normal worker supports only `climate.set_hvac_mode`,
  `cover.open_cover`, and `cover.close_cover` for the persisted entity. Before
  every credential-bearing I/O it re-resolves the source, service revision,
  and current Home Resources, initiating account revision and session token. The
  production public plan publisher is closed; only server-derived refresh may
  propose device changes. Logout during readback causes zero mutation POSTs. Foreign device/binding records fail before the
  network boundary.

## Primary provider references

- Home Assistant REST authentication, entity state, and action endpoints:
  <https://developers.home-assistant.io/docs/api/rest/>
- Home Assistant WebSocket authentication and correlated command/result
  contract: <https://developers.home-assistant.io/docs/api/websocket/>
- Current Home Assistant Core implementation of the fixed entity-registry list
  command: <https://github.com/home-assistant/core/blob/dev/homeassistant/components/config/entity_registry.py>
- Home Assistant climate entity and action contract:
  <https://www.home-assistant.io/integrations/climate/>
- Home Assistant cover entity and action contract:
  <https://www.home-assistant.io/integrations/cover/>

## Automated evidence

```text
server/.venv/bin/pytest -q \
  server/tests/test_f50_room_comfort.py \
  server/tests/test_f50_room_comfort_http.py \
  server/tests/test_f50_home_assistant_executor.py \
  server/tests/test_f50_home_assistant_normal_core.py
# 17 passed

flutter analyze lib/features/room_comfort test/features/room_comfort
# No issues found

flutter test test/features/room_comfort
# 26 passed
```

The normal-Core test uses `create_app`, encrypted Services, authenticated source
configuration, current Home Resources, the production bounded transport, and a
real loopback Home Assistant fixture serving both TCP REST and an authenticated
WebSocket entity registry. It exercises setup discovery, entity candidates,
live preflight, configuration save, cold-room observation, one fixed climate
action after explicit confirm, and exact state readback. Provider-derived
numeric revisions are also asserted to survive a JSON round trip within the
JavaScript safe-integer range. No home device was contacted.

## Manual provider gate

On an explicitly authorized Home Assistant instance, select an authenticated
connection and current room/area records, then bind the required entities.
Refresh the plan and compare every input with Home Assistant. Confirm one
change and verify the target entity plus resulting mode/state. Revoke the
token, change the service revision, and change a Home Resource revision in
separate runs; each must fail closed without repeating an earlier command.
