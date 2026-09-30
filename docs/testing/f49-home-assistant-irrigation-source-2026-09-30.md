# F49 Home Assistant irrigation source — 2026-09-30

## Delivered contract

The normal Core now creates an authenticated Home Assistant irrigation source
provider. An administrator can bind exactly one encrypted Home Assistant
service revision and configure one weather entity, one moisture leak entity,
one daily water utility meter, and up to 32 valve/soil-moisture zone pairs.
Each zone is bound to an exact encrypted Home Resource room ID and room
revision. The policy uses that real room reference as its area identity and
reads the room label from the registry; the source cannot supply an unrelated
display area. The authenticated `home_resource_state.revision` is the
authority's home revision.
The source settings use compare-and-swap revision updates and an HMAC envelope
bound to the Core and home IDs. Credentials stay in the existing encrypted
service store and never enter this table or an HTTP response.

Each snapshot reads only fixed packaged routes:

- `GET /api/states/<configured-entity-id>` for weather, leak, daily water,
  soil moisture, and valve observations;
- `POST /api/services/weather/get_forecasts?return_response` with an exact
  configured weather entity and `type=hourly` for forecast response data.

The transport has a five-second request deadline, a 64 KiB response limit,
no redirect, cookie, proxy, or retry behavior. JSON rejects duplicate keys,
non-finite numbers, unexpected content types, and oversized structures.
Current actor, session family, account revision, source CAS revision, and
encrypted service revision are revalidated after upstream I/O. The global
home-resource revision and every referenced room revision are also checked
before and after I/O, so room deletion, replacement, or rename discards the
late observation.

The projection accepts only documented Home Assistant units and classes:
moisture `%`, weather `°C` / `m/s` / `mm`, a moisture binary sensor, and a
daily water meter in liters with a current reset window no longer than 24
hours. Missing, stale, malformed, over-budget, or changed observations fail
closed. Provider snapshot hashes form bounded content revisions; they are not
synthetic upstream counters.

## Honest control boundary

Home Assistant's generic valve contract exposes explicit
`valve.open_valve` and `valve.close_valve` actions and observable valve states,
but it does not promise a bounded run duration, delivered-flow evidence, or a
causal command receipt. The provider therefore returns `manual_required` and
does not enable the existing confirmed valve command endpoints. A controller
specific executor must provide a timed one-shot operation, flow evidence, and
closed-valve readback before `verified_control` can be advertised.

## Official sources

- [Home Assistant REST API](https://developers.home-assistant.io/docs/api/rest/)
  documents authenticated entity-state reads, action calls, response data via
  `return_response`, and the `weather.get_forecasts` REST example.
- [Home Assistant Valve](https://www.home-assistant.io/integrations/valve/)
  documents valve states and the explicit open/close actions.
- [Home Assistant Weather](https://www.home-assistant.io/integrations/weather/)
  documents weather units and the `weather.get_forecasts` response fields.
- [Home Assistant Sensor entity](https://developers.home-assistant.io/docs/core/entity/sensor/)
  documents moisture `%`, water/volume totals, `total` /
  `total_increasing`, and reset semantics.
- [Home Assistant Utility Meter](https://www.home-assistant.io/integrations/utility_meter/)
  documents daily reset cycles for water-source sensors.

## Focused evidence

No real home or device write was performed. The fixture exercises the normal
HTTP routes through Core, the encrypted service connection seam, exact Home
Assistant request paths, strict projection, source CAS conflict, and service
revision drift.

```text
cd server
.venv/bin/python -m pytest -q \
  tests/test_f49_irrigation_water_budget.py \
  tests/test_f49_irrigation_http.py \
  tests/test_f49_home_assistant_provider.py

12 passed
```
