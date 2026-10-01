# F01–F03 bounded authenticated history — 1 October 2026

Production drafts and trial journals previously retained terminal records for
the entire Core lifetime. A normal Core HTTP request after restart reproduced
`429 automation_draft_limit_reached` after 256 drafts and
`429 automation_trial_limit_reached` after 128 historical trials. The draft
fixture advanced the trusted clock between requests to respect the existing
120/minute resource rate limit; the final RED was the storage capacity failure,
not a rate-limit or authentication failure.

The correction leaves the production limits at 256 drafts, 128 trials, 4096
events and 512 events per trial. Every bounded parent and child HMAC is checked
before any deletion. A trial child must match its parent's account/family and
its signed result source/key/time; malformed or mismatched history fails
closed. Signed trial period bounds must match the original seven local days.

Only when a new record needs capacity, terminal history strictly older than
an inclusive 24-hour replay window is eligible. Drafts use their expiry;
activated draft receipts can retire while their separately encrypted inert
rules remain. Trials retain their latest period end, creation time and event
creation time. Future/live periods and the trial currently receiving an event
are protected. Whole trial deletion uses the existing child foreign-key cascade;
no provider operation or device command is dispatched. If the remaining history
still fills the bound, or the current trial's per-trial event cap rejects the
append, the same transaction rolls back all attempted pruning. Clock rollback
or nonfinite clock input cannot erase authenticated history.

Root ran against the live checkout explicitly, avoiding a cached installed
Server wheel:

```text
PYTHONPATH=server server/.venv/bin/python -m pytest \
  server/tests/test_f01_f03_automation_retention.py \
  server/tests/test_f01_f03_automation_final.py \
  server/tests/test_f02_f03_ha_trace_provider.py -rA
```

**22 passed, zero failures/skips.** The 14 retention cases (13 functions, one parameterized twice) cover actual default
256-draft and 128-trial normal HTTP creation and same-DB restart; a default
4096-event history (bounded signed fixture copies of genuinely evaluated
results, not 4096 live HA traces) and restart; inclusive cutoff, live/recent
replay, active trials, encrypted rule preservation, current closed trial
protection, whole-child deletion, tamper/no deletion, mismatched signed child
ownership, rollback and clock rollback. The existing eight cases retain the
normal Core/owned HA TCP registry/trace integration and simulation-only evidence.
No household HA account or device was used. `py_compile` and scoped whitespace
checks passed. This closes these software retention gaps, not physical speech
quality, household trace volume or final-HEAD hosted CI.
