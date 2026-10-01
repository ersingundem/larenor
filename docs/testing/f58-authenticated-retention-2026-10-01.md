# F58 authenticated receipt retention evidence

Date: 2026-10-01

## Boundary

The e-paper store remains capped at 2,000 previews, provider commands, and
polls. A new insert first validates every device, preview, provider command,
artifact, and poll authentication tag and their parent/child relationships.
No row is deleted if that validation fails.

Expired local previews and provider previews that never left `prepared` may be
removed. The store retains the 32 newest terminal provider receipts, every
`dispatching` or `uncertain` provider command, every pending poll, the latest
poll for each device's current render digest, and the 32 newest terminal polls.
Deleting a preview uses the schema's authenticated parent foreign key and
cascades its provider command, so no provider orphan is created.

The provider capacity preflight calculates whether pruning could make room but
does not mutate storage before the dry run and image read. The final capacity
check, candidate deletion, and new insert share one SQLite transaction. Poll
retention uses the same transaction boundary. If protected records still fill
the cap, the capacity error rolls back all candidate deletion. Uncertain or
dispatching provider effects are never removed to make room and are never sent
again.

## Focused evidence

Command:

```text
cd server
.venv/bin/python -m pytest -q \
  tests/test_f58_epaper_retention.py \
  tests/test_f58_oepl_normal_core.py \
  tests/test_f58_epaper_http.py \
  tests/test_f58_epaper_snapshot_core.py
```

Agent focused result: 17 tests passed. Root independently ran the live checkout
with `PYTHONPATH=server` and added a default2000-row signed preparation-history
case: **18 passed**, zero failures/skips. That case clones one genuine owned
HA/OEPL dry-run preparation, restarts normal Core on the same DB and proves
one new send without replay. It does not simulate2000 physical displays. The retention-specific cases cover a persisted cap
across Core restart, exact recent provider receipt replay, real-shaped
Home Assistant/OpenEPaperLink HTTP dry-run and send counts, expired untouched
preview replacement, uncertain no-resend behavior, signed child mismatch,
tampered receipt rejection, no-orphan cascade, transactional capacity rollback,
and preservation of the current render acknowledgement across restart.

## Limit

An account acknowledgement and an OpenEPaperLink accepted response are not
physical display proof. Retention does not promote either to verified delivery.
Records with an uncertain effect remain protected and can intentionally exhaust
the bounded store until an operator resolves the upstream uncertainty.
