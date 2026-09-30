# F40 normal Core reservation acceptance — 2026-09-30

## Normal production path exercised

`server/tests/support/f40_flutter_acceptance.py` starts the ordinary Core app
over a real loopback TCP socket. It runs a fresh Flutter test process, stops
Core, opens the same encrypted Core data directory again, and runs a second
fresh Flutter process against the restarted app. There is no injected F40 API,
store, authority, or provider in this path.

The first Client process signs in through `ServerAccountController`, opens
`ResourceReservationAccountApi`, and creates a managed resource with an exact
catalog command. It repeats the same command identifier and byte-equivalent
request and observes one catalog transition. Two independently connected
calendar transports retain revision 1; one creates the reservation while the
other acts as a lost-ack reader and resolves the durable receipt without
calling the mutator.

After Core restarts, the second Client process discovers the persisted managed
resource by its server-owned identifier, reads the live reservation and create
history, and repeats the two-transport pattern for cancellation. It verifies
the cancellation receipt, snapshot, ordered history and bounded export. The
route authority is then retired and a later read fails locally with
`authority_changed`.

The Python runner reads the verified database after the Client exits and
requires exactly one catalog `created` event and exactly one reservation
`created` plus one `cancelled` event. This makes an accidental write retry or
duplicate replay fail the acceptance gate.

## Named evidence

```text
server/.venv/bin/python server/tests/support/f40_flutter_acceptance.py

create phase: 1 passed
restart phase: 1 passed
durable event counts: catalog created=1; reservation created=1,cancelled=1
```

Focused files:

- `server/tests/support/f40_flutter_acceptance.py`
- `test/features/resource_reservations/resource_reservation_normal_core_test.dart`

## Evidence limits

The acceptance uses an isolated Core, synthetic account and loopback TCP. It
does not contact a household calendar, room controller, lock, occupancy sensor
or physical tablet, and it does not claim that a calendar entry enforces
physical access. Huawei/DeX rotation, local-time accessibility and physical
device behavior remain manual evidence. The gate proves the real Client/Core
authority, encrypted restart, exact command, lost-ack receipt and durable
journal behavior.
