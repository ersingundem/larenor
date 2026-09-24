# K07 paired remote software acceptance

Status: **accepted on exact reviewed and CI-tested source `0a6c2b296714eda0896dba3b277e331f129e38a6`**

## Current software boundary

- Managed-tablet enrollment is explicit, secure-storage backed and bound to the
  exact account, Core, home, pairing revision and foreground runtime owner.
  Core authority and local-broker egress are revalidated before each TLS
  connection; revoke, logout, route replacement and lifecycle retirement stop
  the native lease and MQTT generation before reuse.
- The local MQTT adapter requires TLS, passes credentials outside URLs and
  logging, waits for SUBACK and matching QoS 1 PUBACK receipts, and fails closed
  on rejection, timeout or disconnect. Runtime topics, command schema, replay,
  rate limit, state persistence and ACK publication are bounded. Out-of-range
  numeric deadlines return the exact `invalid_mqtt_command` ACK instead of
  escaping the parser without a receipt.
- The Android source accepts only `lockKiosk` natively. Dashboard refresh and
  versioned profile synchronization execute through retained Dart owners; all
  three actions share the exact lease, serialized execution and one bounded
  deadline. Profile activation and its Core ACK are guarded by the same account,
  enrollment, revision and lifecycle identity.

`docs/testing/k07-software-acceptance.json` and `tool/k07_acceptance.py` bind
these claims to exact production, adversarial test, review and CI markers. The
validator rejects a missing marker, stale source, mismatched CI SHA, incomplete
required-job set or MANUAL-boundary drift.

## TDD and focused evidence

RED `6d435246` proves a finite but out-of-range MQTT deadline escaped strict
parsing with `RangeError` and produced no command ACK. GREEN `d37ebb1b` bounds
the conversion before `DateTime` construction; the same regression also rejects
an out-of-range integer sequence. Stable patch IDs survived the #480 rebase:
RED `413a6246890c3c0abc88e10e3a959d4ef65da402`, GREEN
`c23908ab3221b69d17d339d1b2cc6c84b1ce97fc`.

- 67 focused Flutter tests passed for the runtime owner, live TLS
  PUBACK/SUBACK, MQTT command/ACK path, native source and bounded deadlines.
- 10 focused Core tests passed for paired MQTT authority and versioned profile
  publication.
- Acceptance-validator tests passed 4/4; queue validation, progress policy,
  targeted analysis and `git diff --check` passed.

## Independent review and exact CI

Independent P1/P2 review passed exact `0a6c2b296714eda0896dba3b277e331f129e38a6`. It rechecked secure
enrollment/runtime ownership, Core and egress authority, TLS ACK/ACL behavior,
replay/rate/scope persistence, native lock plus Dart refresh/profile commands,
and the separation of physical MANUAL gates.

- Android Build [35953409201](https://github.com/ersingundem/larenor/actions/runs/35953409201)
  passed on exact `0a6c2b296714eda0896dba3b277e331f129e38a6`: static analysis, four Flutter shards, four Server
  shards and aggregate, API 35 emulator journeys, and debug APK.
- Security [35953408908](https://github.com/ersingundem/larenor/actions/runs/35953408908)
  passed on the same exact source: secret scan, platform policy and dependency
  scan.

## Manual boundary

Physical Huawei tablets, DeX pointer/keyboard behavior, TalkBack interaction,
OEM/DPC policy delivery, real broker deployment and device measurements remain
MANUAL. They are not claimed as software queue evidence.
