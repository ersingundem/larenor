# F06 Home Assistant rule attribution TDD evidence

## Accepted slice

This Server slice adds a real persisted rule origin to the existing selected
Home Assistant switch command path:

1. A current administrator can create an immutable rule bound to the exact
   Core, home, resource, ACL, binding and service revisions. The rule action,
   creator and target facts are encrypted; the bounded inventory is protected
   by a scope-bound HMAC and survives restart.
2. A current write-authorized user can explicitly execute that stored rule.
   Core derives `core_rule/explicit_rule_execution` itself and stores actor,
   rule ID/revision, execution ID, service ID/revision, command and result under
   the same request trace in the existing encrypted, integrity-checked command
   history. The caller cannot submit source or reason fields, and one request ID
   dispatches at most once.
3. Missing, foreign, stale or unreadable rules never dispatch. Current
   user/resource/binding/service authority is rechecked before the existing HA
   command guard runs. Corrupted rule ciphertext fails closed during live reads
   and restart, while a nearby explicit command remains `core_api` and is never
   relabelled as a rule event.

## RED and GREEN evidence

| Stage | Command | Result |
| --- | --- | --- |
| RED `fdabc63c` | `PYTHONPATH=server server/.venv/bin/python -m pytest -q server/tests/test_f06_rule_attribution.py` | 3/3 expected failures because rule create/read/execute routes and storage did not exist. |
| GREEN `18da43f2` | Same focused command | 3/3 passed. |
| HA/history regression | Command history, integrity/event history, HA adapter/command/contract/safety and this F06 suite | 180/180 passed. |
| Startup regression | Admin migration, Core context and daemon startup suites | 55/55 passed. |
| Static checks | `compileall` for the HA package and focused test, plus `git diff --check` | Passed. |

Home Assistant storage advances from schema v3 to v4 so an older binary cannot
silently read a new rule-origin command. Existing v1/v2 commands migrate with
unknown attribution exactly as before; v3 commands retain their recorded
source. Historical timestamps are not consulted during either migration.

## Boundary

This is an explicitly invoked, stored switch rule. It does not claim a sensor,
schedule, voice or autonomous trigger engine; those belong to the later
automation features. All provider behavior in these tests uses an owned
loopback fixture, and no real home was mutated. Android still needs the
`core_rule` presentation before the full F06 queue item can close. Queue and
selected-feature counters remain `15/125` and `0/63`.
