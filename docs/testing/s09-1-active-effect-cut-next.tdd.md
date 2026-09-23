# S09.1 current external-effect backup cut

Date: 23 September 2026

The Core backup cut already rejected several unfinished jobs and remote
commands. Two command blockers ignored their persisted expiry, however, while
an authorized game-stream command was not represented at all. An abandoned
row could therefore either block every later backup or be captured while its
external effect was still authorized.

## Three-job boundary

1. Pending or delivered managed-tablet commands block plan and export only
   while their exact persisted deadline is current.
2. Accepted kiosk-remote commands use the same current-deadline rule; expired
   history cannot leave backup creation permanently blocked.
3. An authorized game-stream command blocks only when its owning session is
   still open and unexpired. Retired sessions and verified, rejected or
   unknown terminal results remain backup-ready, and combined blockers retain
   one public order.

All comparisons use the injected Core clock inside the same database write
reservation as the backup cut. No caller timestamp, request value or mutable
process-local session state participates in the decision.

## RED to GREEN evidence

The corrected RED test reached the real plan endpoint and failed four expiry
and lifecycle cases because old predicates treated persisted rows as active
forever. GREEN passes all focused current, expired, retired, terminal and
ordering cases:

```text
uv run pytest -q tests/test_core_backup_active_effect_cut_next.py
16 passed
```

The final batch also includes the earlier active-effect regressions, the
canonical blocker contract and the base Core backup contract: **46/46 passed**.
Ruff, the security policy, execution-queue validation and `git diff --check`
also passed.

## Remaining acceptance

S09.1 remains pending. Complete managed-component runtime capture, full restore
publication and cross-architecture interruption acceptance remain separate
gates. Queue and selected-feature counters stay at **26/125** and **0/63**.
