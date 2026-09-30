# F47 recorded reserve review evidence (2026-09-30)

## Production contract

Larenor reads the verified evcc service through the fixed
`GET /api/history/energy` route. It requests exactly the previous 168 completed
one-hour slots with `aggregate=hour`, `grouped=false`, and one fixed group per
request: `battery`, then `forecast`. The provider rechecks the current Core,
home, account/session-family, service ID/revision, and connection before each
request and after each response. The API then obtains a second live energy
snapshot. It rejects authority, evcc service, battery identity/catalog,
capacity, reserve-policy, or manual-preference drift. Dynamic meter capture
times, current SoC, and the battery observation revision may advance during
the two bounded history reads and do not cause a false conflict.

The result uses only evcc's recorded `socTemp` value. This value is the battery
state of charge at the start of the slot. It is not calculated from energy,
capacity, or a later sample. Forecast history is reported only as recorded-slot
coverage; it is not used to invent a forecast or a reserve result.

Primary upstream evidence:

- evcc's official Energy history API specifies RFC3339 bounds,
  `grouped=false`, and the `battery` and `forecast` groups. Its generated docs
  show `1h`, while the pinned server implementation passes the token directly
  and accepts `hour`; Larenor follows the pinned executable contract:
  <https://docs.evcc.io/integrations/rest-api/operations/getenergyhistory/>
- the pinned handler passes the aggregate token directly to the metrics query:
  <https://github.com/evcc-io/evcc/blob/d0763ede3e692491de2cef3056ca39258c3e180f/server/http_history_handler.go#L36-L58>
- the pinned evcc history schema includes `socTemp` on a slot and omits it for
  grouped sums:
  <https://github.com/evcc-io/evcc/blob/d0763ede3e692491de2cef3056ca39258c3e180f/core/metrics/db_history.go#L14-L27>
- the pinned evcc collector records `socTemp` at slot start:
  <https://github.com/evcc-io/evcc/blob/d0763ede3e692491de2cef3056ca39258c3e180f/core/metrics/collector.go#L111-L118>
- evcc's own battery history UI treats `socTemp` as the recorded state of
  charge:
  <https://github.com/evcc-io/evcc/blob/d0763ede3e692491de2cef3056ca39258c3e180f/assets/js/components/Battery/history.ts#L15-L24>
- forecast metrics are persisted as exact slot energy by the pinned source:
  <https://github.com/evcc-io/evcc/blob/d0763ede3e692491de2cef3056ca39258c3e180f/core/site_tariffs.go#L194-L231>

## Deliberate uncertainty

- A recorded slot-start sample below the configured reserve is a concrete
  breach at that instant.
- Complete slot-start coverage with no sample below reserve says only that no
  sampled instant was below reserve. It does not prove continuous compliance
  between samples.
- Missing samples, partial forecast records, no forecast records, and multiple
  battery series produce explicit uncertainty. Larenor does not merge multiple
  batteries or select one by title.
- evcc history does not contain the historical Larenor manual preference for
  every slot. The result therefore always marks historical preference coverage
  unavailable and separately reports the current override state.
- Current capacity and configured reserve are returned with exact live
  revisions for context. Their historical values are unavailable and are
  marked as such. The review compares past observations with the current
  reserve; it does not claim that threshold was active in the past. Larenor
  never converts recorded Wh to an inferred SoC percentage.

## Named verification

- `server/tests/test_f47_reserve_backtest.py` covers the exact two-read wire
  contract, slot-start semantics, empty and multiple-series uncertainty,
  malformed data, and service/authority drift after I/O.
- `server/tests/test_f47_evcc_battery_binding.py` covers the normal Core route
  with live evcc binding, fixed query, a clock that advances during both
  history reads, and a revision-bound result.
- `server/tests/test_f47_energy_priorities_api.py` proves that a reserve-policy
  revision changing during the read is rejected before analysis.
- `test/features/energy_priorities/core_energy_priority_api_test.dart` checks
  all 168 public slots, provenance, count/coverage coherence, and malformed
  status rejection.
- `test/features/energy_priorities/energy_priority_controller_test.dart` checks
  route retirement while history is in flight.
- `test/features/energy_priorities/energy_priority_screen_test.dart` checks the
  truthful English and Turkish UI at compact and wide layouts.
- `server/tests/support/f47_flutter_acceptance.py` runs the real Flutter client
  against normal Core over TCP, an owned evcc HTTP fixture, and the existing
  owned Home Assistant fixture across setup and restart lifetimes. The history
  path performs reads only. Its one reserve write is confined to the isolated
  Home Assistant fixture; no household service or device is contacted.

Physical inverter behavior and the quality or retention period of a household
evcc database remain manual deployment evidence. The software gate proves the
bounded read, authority binding, restart behavior, and honest uncertainty; it
does not claim a continuously enforced reserve.

## Root independent verification

All five F47 Server suites passed: 18 tests. The F47/F28 focused Flutter gate passed 37 tests and scoped analysis found no issues. The real Client→normal Core→owned evcc/Home Assistant runner passed setup and restart in two separate Flutter processes; the history path observed six reads and the reserve control performed exactly one owned-fixture POST. F47 is software-complete and awaiting broad exact-HEAD CI. Household inverter/device acceptance remains separately manual.
