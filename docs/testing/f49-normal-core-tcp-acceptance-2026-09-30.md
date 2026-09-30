# F49 normal Core TCP acceptance — 2026-09-30

## Accepted software boundary

This gate starts the normal `create_app` composition, provisions one real Core
room and one encrypted Home Assistant service through authenticated admin
routes, and talks over loopback TCP to isolated Home Assistant and
OpenSprinkler fixtures. The Flutter client then performs the production source
and controller setup calls, loads the live irrigation projection, previews the
current plan, confirms it, and strictly decodes the measured-flow receipt.

The provider fixture implements only the production adapter's bounded routes:
Home Assistant entity states and `weather.get_forecasts`, plus OpenSprinkler
`/jo`, `/jn`, `/jc`, `/js`, and timed manual-station `/cm`. The run completes
through the controller timer, advances the documented cumulative flow pulse
counter, reports program 99 as the exact last run, and closes before Core emits
an applied receipt. Reconfirming the same preview returns the retained receipt
and the fixture observes exactly one `/cm` request.

Additional normal-Core tests close the two indeterminate boundaries. A TCP
connection can disappear after the fixture accepts `/cm`; Core reconciles the
actual timer and flow readback and does not resend. Source replacement or
session revocation on the worker's final pre-dispatch controller snapshot is
observed by the post-read/send guard; no `/cm` request reaches the fixture and
the public receipt remains conservatively `unknown`.

No household service or physical controller was contacted or mutated.

## Revision compatibility

Home Assistant content revisions are derived observations, not persisted CAS
counters. They now retain 52 digest bits and add one, so their JSON number is
exact on Dart VM and JavaScript. Persisted source, controller, and durable
command revisions keep their existing monotonic database contracts. A restart
acceptance test reopens the same Core database, reads the identical encrypted
source/controller metadata, obtains fresh JS-safe observations, and advertises
verified control without dispatching a command.

The Flutter irrigation parser accepts revision fields only through JavaScript's
safe integer maximum (`2^53 - 1`). Water, duration, cost, and other quantity
bounds are unchanged. The >32-bit parser regression passes on Dart VM, and the
standalone web probe compiles to JavaScript and round-trips the deterministic
52-bit revision exactly. A full `flutter test --platform chrome` is not claimed:
the repository currently contains unrelated signed-64 literals in shared
server/home-resource client files, and existing irrigation timestamp/cost
bounds also exceed JavaScript's exact integer range. The acceptance evidence
therefore establishes the F49 revision wire contract, not a whole-app Flutter
Web release gate.

## Primary contracts

- [Home Assistant REST API](https://developers.home-assistant.io/docs/api/rest/)
  defines authenticated `GET /api/states/<entity_id>` and action response data
  via `return_response`.
- [Home Assistant weather entity](https://developers.home-assistant.io/docs/core/entity/weather/)
  states that forecasts come from a separate forecast API and documents hourly
  forecast support.
- [Home Assistant `weather.get_forecasts`](https://www.home-assistant.io/actions/weather.get_forecasts/)
  defines the response keyed by weather entity and the forecast precipitation
  fields used by the fixture.
- [OpenSprinkler firmware 2.2.1 API](https://opensprinkler.github.io/OpenSprinkler-Firmware/2.2.1/221_5_api/)
  defines the password digest, controller/status routes, timed `/cm` manual
  station command, manual program 99, last-run fields, and flow counters.
- [OpenSprinkler firmware 2.2.1 manual](https://opensprinkler.github.io/OpenSprinkler-Firmware/2.2.1/221_6_manual/)
  documents flow-pulse conversion and the controller-wide flow sensor.

## Evidence

```text
PYTHONPATH=server server/.venv/bin/python -m pytest -q \
  server/tests/test_f49_irrigation_water_budget.py \
  server/tests/test_f49_irrigation_http.py \
  server/tests/test_f49_home_assistant_provider.py \
  server/tests/test_f49_opensprinkler_executor.py \
  server/tests/test_f49_irrigation_normal_core.py
# 27 passed

flutter test test/features/irrigation_budget
# 13 passed, 1 explicit normal-Core-runner skip

PYTHONPATH=server server/.venv/bin/python \
  server/tests/support/f49_flutter_acceptance.py
# 1 passed; normal Flutter Client -> create_app Core -> TCP providers

flutter analyze lib/features/irrigation_budget test/features/irrigation_budget
# No issues found

dart compile js -O2 -o /tmp/f49_revision_web_roundtrip.js \
  server/tests/support/f49_revision_web_roundtrip.dart
node /tmp/f49_revision_web_roundtrip.js
# f49-js-revision-exact:2045001812074020
```
