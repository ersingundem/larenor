# S08.11 authority cross-flow closure

S08.11 closes the single-home Core resource path across search, room, and
dashboard-card surfaces. The product remains intentionally outside the F19
multi-Core federation scope and does not claim physical media-receiver
acceptance.

## Accepted contract

- Core dashboard backup schema v3 binds capture, preview, restore, and recovery
  to the exact `coreId`/`homeId`/`userId` owner and one scoped preference key.
- A same-URL Core A to Core B replacement retires A catalog and search results.
  A foreign A backup cannot preview or apply while B owns the scope, and neither
  scoped key is changed by the rejected operation.
- Returning to A, restoring, and remounting `ConfigurationScope` leaves restored
  cards inert until a fresh current revision arrives. Logout retires them again,
  and delayed callbacks cannot publish through an old owner.
- The Dart and Python vault boundaries admit only the strict v3 ownership wire
  shape. Retired upload authority, unknown fields, malformed identities, and
  future versions fail closed without exposing private values.

## Exact evidence

PR #488 source `5e440235b6f7cc39cb638ea5ac9fd2f033a667f1`
completed the contract and squash-merged as
`1d603365e1c794e5fe3130dfab39901163c53384`. Source and squash aggregate stable
patch-id are both `7d9be065b6c8a6bdc6cbb95ab48868511d988fd4`.

Local validation on the accepted source included the 378-test Flutter
backup/vault package, 49 focused Core replacement/restore tests, and 39 Python
vault storage tests. The final independent audit repeated 92 controller,
account, and UI tests plus 8 cross-flow tests and the 39 Python tests; it found
no remaining P1/P2 blocker.

Android Build run
[`35966881025`](https://github.com/ersingundem/larenor/actions/runs/35966881025)
passed static analysis, four Flutter shards and aggregate, four Server shards
and aggregate, debug APK, and the API 35 emulator journey on the exact source.
One unrelated durable Docker-adapter authority test failed once in the first
Server shard attempt; the exact isolated test plus 12 serial repeats passed
13/13, and failed-job attempt 2 passed on the same SHA without a code change.
Security run
[`35966880542`](https://github.com/ersingundem/larenor/actions/runs/35966880542)
passed secret, platform-policy, and dependency checks.

S08.11 is therefore accepted as a software queue item. Physical HomePod, Cast,
Apple TV, Huawei, DeX, and OEM journeys remain separate MANUAL gates.
