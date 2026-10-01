# F18/F27 offline download power-hold composition — 1 October 2026

## Scope

F18 promises that downloads and active work are protected before database
checkpoint and ordered shutdown. F27 later introduced normal-Core offline media
grants and chunk reads. The original F18 gate covered bounded transfers and
administrative media jobs, but did not cover `offline_media_grants` or the
`/api/v1/media/offline` flow.

This change composes those two existing contracts. It does not add a new media
source, change the provider authority, or claim a physical UPS shutdown.

## Guarantees

- A new offline grant checks the durable power gate before provider work and
  again in the same `BEGIN IMMEDIATE` transaction as the grant insert. Exact
  replay of an already admitted request remains read-only and idempotent.
- The first chunk checks the same gate in the transaction that changes the
  durable grant from `granted` to `transferring`. A direct progress request
  cannot bypass this first-transfer admission while the gate is held.
- The admission marker does not increment the public manifest revision because
  the client has not acknowledged any bytes. Existing expected-revision,
  authority, offset, content-integrity and HMAC checks remain in force.
- A transfer admitted before the hold may finish subsequent chunks and progress
  updates, or be explicitly revoked. `drainActiveWork` treats an unexpired
  durable `transferring` grant as active across Core restart and does not advance
  to checkpoint. Completion, revoke, or exact grant expiry releases the durable
  marker; any still-running process-local worker remains active until it exits.
- The exact Core process also registers a bounded active-work observer. Its
  counter is incremented before the first-transfer admission transaction
  commits and decremented in `finally` on every rollback, worker failure, or
  normal return. Expiry or revoke can retire the durable grant while a worker
  body is still running, but cannot make that real in-flight I/O disappear from
  the drain decision.
- Active-work observer registration is duplicate-safe and capped at 16. An
  observer exception or a non-boolean observation keeps the drain blocked,
  because invalid/lost observation cannot establish that the underlying effect
  stopped.
- A crashed or abandoned transfer is never inferred complete. It blocks the
  ordered shutdown until recovery/revoke/expiry; the existing 30-second F18
  drain deadline then fails the run closed instead of skipping the work.

## TDD evidence

The new normal-Core/SQLite test was first executed against the old production
sources:

```text
server/.venv/bin/pytest -q \
  server/tests/test_f18_offline_media_power_hold.py
# 4 failed
```

The failures were the intended gap: held Core still returned 201 for a new
grant, first chunk reached the worker, the transfer was absent from durable
drain work, and revoke/completion could not demonstrate release of that work.

After the minimal production change:

```text
server/.venv/bin/pytest -q \
  server/tests/test_f18_offline_media_power_hold.py
# 9 passed

server/.venv/bin/pytest -q \
  server/tests/test_f18_nut_bridge.py \
  server/tests/test_f18_nut_normal_core.py \
  server/tests/test_f18_offline_media_power_hold.py \
  server/tests/test_f27_jellyfin_offline_worker.py \
  server/tests/test_f27_offline_media_api.py \
  server/tests/test_f27_online_playback_lease.py \
  server/tests/test_power_recovery_proxmox_executor.py \
  server/tests/test_power_recovery_restart.py
# 57 passed, 1 existing platform skip
```

The new cases exercise held admission, a real SQLite writer race, blocked
progress bypass, in-flight worker I/O, durable restart readback, an actual
queued `drainActiveWork` step, multi-chunk completion while held, revoke, and
expiry. A separate pre-fix regression expired and revoked a grant while its
worker body remained blocked: durable state stopped reporting work and the old
source incorrectly returned inactive. The production observer now keeps that
exact process flight active until its `finally` path. The focused suite also
proves duplicate/capped observer registration and exception fail-closed
behavior (including invalid `None` and truthy integer returns), plus transaction
rollback before worker dispatch with zero leaked
activity and zero worker I/O. The platform skip is the existing Linux-only
pinned executable case; none of the new tests is skipped.

No coverage tool was run for this bounded integration slice. Physical UPS,
Proxmox targets and storage-pressure behavior remain their existing deployment
or MANUAL acceptance gates.

## Independent root verification

The root focused 9-case hold suite passed, and pinned Ruff 0.14.1 passed for
all four Python sources/tests. A broader independent run produced 72 passed,
1 existing Linux-only skip and 1 failure in the pre-existing NUT notification
socket startup test. Source review identified a separate bind/chmod/listen
publication race; it is being repaired separately. That broader run is not
recorded as green, and this document does not close the notification race.
Private root output: `/private/tmp/larenor-root-verify-20261001/server.log`
and `f18-focused.log`.
