# F22 personal channel progression evidence — 2026-09-30

## Production behavior

- Starting continuous playback seals the current channel/programme revisions,
  occurrence, selected managed target, account revision, and session family in
  SQLite before any provider I/O.
- Each occurrence receives one durable intent/command reservation. A missing
  acknowledgement remains `dispatching/effect_unknown`; the same occurrence is
  never sent again. Once its boundary has passed, the scheduler can reserve the
  current occurrence instead of replaying the uncertain one.
- Core restart reconstructs the scheduler from the journal. Channel cancel,
  logout/family revocation, actor revision drift, media-source drift, target
  disappearance, and a gap all stop or fence later writes.
- Background progression binds to the durable user revision and current session
  family. It does not store, mint, or depend on an expiring access bearer, so a
  same-family access rotation does not cancel an already-authorized occurrence.
- A successful transition requires the exact request, intent, installation,
  item, target, increasing playback revision, and authenticated provider
  readback. The same authority and cancellation gate is checked inside the final
  receipt transaction. Flutter displays success only for that terminal state
  and restores the durable execution when the channel is selected after restart.

The loopback provider follows Jellyfin's authenticated session control API:
the official stable OpenAPI defines `GET /Sessions` as the session inventory and
`POST /Sessions/{sessionId}/Playing` as the play instruction. The acceptance
fixture implements only these bounded endpoints and keeps its synthetic API key
private.

Primary contract:
https://lon1.mirror.jellyfin.org/main/openapi/jellyfin-openapi-stable.json

## Focused evidence

```text
PYTHONPATH=server server/.venv/bin/python -m pytest -q \
  server/tests/test_f22_personal_channels_api.py \
  server/tests/test_f22_personal_channel_progression.py \
  server/tests/test_media_playback.py
35 passed

flutter analyze lib/features/server/personal_channels
No issues found

PYTHONPATH=server server/.venv/bin/python \
  server/tests/support/f22_flutter_acceptance.py
prepare lifetime: 1 passed
restart lifetime: 1 passed
```

The server gate covers more than 900 seconds without foreground refresh,
same-family bearer rotation between occurrence reservation and playback
preparation, logout/family revocation, exact source and target drift, a
deterministic cancellation inside the final receipt transaction, lost
acknowledgement without replay, and a v1 database restart. The v1 migration
preserves the existing channels and programmes, creates an empty execution
journal, and does not invent a playback receipt.

The combined runner uses the real Flutter API client over TCP to a normal
Uvicorn/Core composition. Core reads and writes an owned loopback Jellyfin HTTP
server, persists the first receipt, restarts from the same SQLite database and
client session, advances exactly once to the second programme, exposes the
causal receipt to Flutter, and accepts explicit cancellation. It asserts exactly
two Jellyfin play writes.

Core revalidates the account, family, occurrence, media authority, target, and
cancellation immediately before handing the private action to the worker. If
authority changes after that IPC handoff, the provider effect may already have
crossed the boundary; Core therefore retains `effect_unknown`/pending state and
never resends. The software contract does not claim a remote cancellation
callback that Jellyfin does not provide.

## Manual boundary

No household Jellyfin player was controlled. Physical player discovery,
device-specific playback support, and long-running media behavior remain a
manual provider/device gate. The software gate proves the authenticated HTTP
contract, authority fences, durable progression, no-replay behavior, and client
restart path with owned fixtures.

Root repeated the final production Client→normal Core→owned Jellyfin runner after the durable-family/final-transaction repair: both Client/Core lifetimes passed, with exactly two owned-fixture playback POSTs and cancellation. The final F22/F28 server gate passed 46 tests (35 F22/media plus 11 timer tests), and scoped F22 analysis found no issues. F22 is software-complete, awaiting broad exact-HEAD CI; physical receiver acceptance remains manual.
