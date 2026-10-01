# F14 support-session retention evidence — 2026-10-01

## Scope

This slice closes a persistent lifetime-capacity failure in the production
support-session service. Expired and revoked sessions were retained forever,
including their activity rows. After 64 sessions or 1,024 events, normal Core
could no longer create a support session or record an authorized read, even
after every token had expired and Core had restarted.

No external supporter, household device, shell, screen-control channel, or OS
clipboard was used. The integration test uses normal Core HTTP and local
HMAC-authenticated SQLite state with hashed access tokens.

## RED

Before the production change, this command exercised the normal Core route:

```text
server/.venv/bin/python -m pytest -q \
  server/tests/test_f14_support_sessions_retention.py -x
```

`test_normal_core_restart_releases_expired_session_capacity` created the exact
maximum 64 sessions through HTTP, advanced the trusted clock beyond expiry and
the intended replay window, restarted `create_app(settings)`, signed in again,
and attempted session 65. The expected `201` was an actual
`429 support_session_limit_reached`. This was the storage defect; the final RED
used a fresh valid login and did not fail on authentication or setup.

## Retention contract

Retention runs inside the same `BEGIN IMMEDIATE` transaction as session create
or activity recording. Before its first delete, the service verifies the HMAC
of every bounded session and event row. A bad session or event therefore fails
closed and the transaction retains all rows.

The service preserves:

- every unexpired active session;
- every expired session through 24 hours after its exact expiry;
- every revoked session through 24 hours after its authenticated update time;
- the exact request-key/token single-issuance result throughout that inclusive
  replay window; and
- every event whose parent session is preserved.

Only terminal history strictly older than the 24-hour replay cutoff is
eligible. Deleting that authenticated parent uses the existing foreign-key
cascade for its activity rows. Limits remain 64 sessions and 1,024 events. If
protected rows alone fill a limit, Core still returns the existing bounded
error; it does not evict a live session, increase a cap, or replay a request.
An old token remains unusable before and after retention.

## GREEN

```text
server/.venv/bin/python -m pytest -q \
  server/tests/test_f14_support_sessions_retention.py \
  server/tests/test_f14_support_sessions_normal_core.py
```

Result: **9 passed**, zero failures or skips.

The six new retention cases prove normal-Core capacity recovery across restart,
live/recent-terminal capacity rejection, exact request-key replay protection,
the inclusive 24-hour boundary, recovery from a full 1,024-event history,
old-token rejection, and session/event tamper failure with zero deletion. The
three existing normal-Core cases continue to prove bounded permission reads,
one-view token behavior, activity, restart, revoke, live admin authority and
startup tamper rejection.

`py_compile` for both changed Python files and scoped `git diff --check` also
completed without errors. The local environment does not include the
`coverage` command, so no new numeric coverage percentage is claimed.

## Remaining limits

The 24-hour terminal replay window is a software retention guarantee. Current
sessions and their events are never removed merely to make capacity. Physical
clipboard behavior and a real external supporter remain manual boundaries;
this retention slice makes no new claim about either.
