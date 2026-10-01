# Current durable-history capacity gaps — 1 October 2026

Independent read-only review and root source verification found the following
implementation gaps. Earlier focused acceptance remains historical evidence;
none proved capacity recovery after long use. These are source findings, not
new hosted or physical-provider test results.

| Feature | Verified production storage path | Fixed lifetime capacity with no pruning path |
| --- | --- | --- |
| F01 | `automation_drafts/service.py`, `_validate` and `create` | 256 expired/activated drafts remain forever; subsequent creation rejects with 429. Underlying activated rules must be preserved. |
| F02/F03 | `automation_trials/service.py`, `create`, `evaluate`, trace ingestion | 128 trials / 4096 events remain forever, including completed historical trials; subsequent creation or ingestion rejects with 429. Per-trial active evidence bounds remain required. |
| F14 | `support_sessions/service.py`, `create` and `_record_event` | 64 sessions / 1024 events remain forever, including revoked/expired sessions; new support creation and eventually reads reject with 429. |
| F57 | `room_presence/repository.py`, `confirm` | 256 applied calibration receipts remain for an active provider; only provider revoke removes them. New confirmations reject with 409. |
| F58 | `epaper_snapshots/management.py`, provider preview and `poll` | 2000 preview/provider-command/poll history rows remain forever; new usage rejects with 409. |
| F59 | `workshop/service.py`, confirmed intent creation | 10000 intents remain forever, including terminal results; new commands reject with 409. |

Corrections must validate authenticated parent/child history before deletion,
preserve active/in-flight/unknown operations and current state, and retain a
bounded recent replay window. They must not increase limits or resend provider
operations. Capacity refusal must roll back any attempted pruning. Named
capacity recovery, replay, tamper, rollback and restart gates are required;
normal Core/provider paths remain separate from mocked unit fixtures.

F14 is now `awaiting_ci`: root live-source 9/9 normal Core/retention tests
passed, including actual 64-session restart and 1024-event capacity recovery,
live/recent replay, old-token rejection and tamper/no-deletion gates. See
[f14-support-session-retention-2026-10-01.md](f14-support-session-retention-2026-10-01.md).
F01/F02/F03 now also await CI: root live-source22/22 tests passed, including
default256/128 creation and restart and signed4096-event recovery. Current/live
history, inclusive24h replay, activated encrypted rules, tamper/child authority
and rollback are protected. See [automation retention evidence](f01-f03-automation-retention-2026-10-01.md).
F57/F58/F59 remain `reworking` until their repair acceptance is complete. F60/F62 have separate runtime/distribution gaps and remain reworking.
Current totals: **64 tasks / 55 selected features awaiting CI**, **5 features
reworking**, **37/127 tasks and 3/63 selected features accepted**. No acceptance
counter was advanced by this review.
