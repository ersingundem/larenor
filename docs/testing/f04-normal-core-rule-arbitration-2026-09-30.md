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

## Root execution proof, 2026-10-03

Exact source `3f86082026624d8de6b13c037de203e0c938c158` was executed by the root in a disposable, supervised loopback fixture. The named F04 runner completed both manual-suppression and restart Flutter lifetimes successfully. The focused server gate completed 2 tests with 0 failures (2 existing warnings). All supervised commands completed with exit 0. The closed execution record contains these private log hashes; no credential or raw provider log is published:

- `f04-core-tcp`: SHA-256 `2373b38b92d3ce25f89b7e8481ea11366d0061c6dff98abc6cbf2f07c5f2175d`.
- `f04-server`: SHA-256 `bb618fc9fc9352cc349c000f8ee55ec5ed9e26ccf5e9f35e05d8166be9f37938`.

These are scoped software test results. They do not establish a real HA event stream/TLS deployment, the complete concurrent rule/ownership-expiry failure matrix or physical device effects. Final combined exact-commit CI, independent acceptance review and dependency closure remain required. No item is promoted to accepted or merged.
