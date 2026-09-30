# F04 normal Core rule-arbitration acceptance (2026-09-30)

`server/tests/support/f04_flutter_acceptance.py` is the named F04 production
path gate. It starts an owned Home Assistant HTTP fixture, a normal Core, and a
real Flutter Client process. The Client sends a manual switch command through
`CoreHaApi`, then executes a durable attributed Core rule against the same
resource. Manual ownership suppresses that rule before provider dispatch.

The gate restarts normal Core on the same database and starts a fresh Flutter
process. It reads the durable manual receipt, replays the exact suppressed rule
execution, and checks the arbiter snapshot. The owned provider receives one
POST total. A separately recorded external Home Assistant observation remains
non-authoritative and causes no provider write.

Run it with:

```sh
server/.venv/bin/python server/tests/support/f04_flutter_acceptance.py
```

This uses only the owned loopback fixture and synthetic credentials. It does
not contact or mutate a household Home Assistant instance. It proves Core's
manual-versus-rule ordering, durable restart behavior, idempotent suppression,
and observed-only external writes. It does not claim that a real household
automation has been configured, nor that Home Assistant can identify external
writes as originating from a specific automation.
