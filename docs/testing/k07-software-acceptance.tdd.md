# K07 paired remote software acceptance

Status: **software implementation complete; exact review and CI pending**

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
  numeric deadlines now return the exact `invalid_mqtt_command` ACK instead of
  escaping the parser without a receipt.
- The Android source accepts only `lockKiosk` natively. Dashboard refresh and
  versioned profile synchronization execute through retained Dart owners; all
  three actions share the exact lease, serialized execution and one bounded
  deadline. Profile activation and its Core ACK are guarded by the same account,
  enrollment, revision and lifecycle identity.

`docs/testing/k07-software-acceptance.json` and `tool/k07_acceptance.py` bind
these claims to current production, adversarial test and review markers. The
manifest deliberately remains `pending` until independent exact-tree review and
both exact-head Android Build and Security runs pass. The validator refuses a
pending manifest without `--allow-pending`, so queue closure cannot precede
those gates.

## TDD checkpoint

RED `6d435246` proves a finite but out-of-range MQTT deadline escaped strict
parsing with `RangeError` and produced no command ACK. GREEN `d37ebb1b` bounds
the conversion before `DateTime` construction; the same regression also rejects
an out-of-range integer sequence. The focused runtime regression passes, and
the owner, live TLS/PUBACK/SUBACK, native action and deadline groups are the
milestone test set for final acceptance.

## Manual boundary

Physical Huawei tablets, DeX pointer/keyboard behavior, TalkBack interaction,
OEM/DPC policy delivery, real broker deployment and device measurements remain
MANUAL. The automated software acceptance does not convert them into queue
evidence.
