# F21 normal Core watch-party acceptance — 2026-09-30

## Supported contract

F21 uses Larenor Core as the durable room, participant, leader, latency and
revision authority. Jellyfin remains the authenticated source of the selected
media item. The implementation does not claim to create a Jellyfin SyncPlay
group: Jellyfin's official SDK exposes separate create/join/ping/seek/pause
operations through
[`SyncPlayApi`](https://typescript-sdk.jellyfin.org/classes/generated-client.SyncPlayApi.html),
while this feature sends bounded playback directives to each Larenor client.
That separation is intentional and is covered by the acceptance below.

The owned provider fixture exposes only the read paths consumed by the
production `MediaArchiveReadCollector`, including authenticated Jellyfin system,
library and item reads represented by Jellyfin's official
[`SystemApi`](https://typescript-sdk.jellyfin.org/classes/generated-client.SystemApi.html)
and
[`LibraryApi`](https://typescript-sdk.jellyfin.org/classes/generated-client.LibraryApi.html).
It rejects every POST and DELETE. The item and service
facts therefore cross the normal Core provider boundary; the test does not
insert a caller-supplied media authority or canned watch-party response.

## Named acceptance

`server/tests/support/f21_flutter_acceptance.py` runs two production Flutter
clients against Uvicorn and a normally composed Core. Its prepare phase proves:

- authenticated catalog discovery and exact item resolution through the real
  read-only media provider;
- room creation, invite join, two participant reports and bounded receiver
  capabilities;
- stale room revision rejection and explicit refresh recovery;
- an `unsupported` directive when a receiver cannot seek.

The runner then stops the Core, closes every provider fixture, constructs a new
Core over the same durable data directory, and runs a second Flutter process.
That phase proves explicit invite rejoin for new session families, leader command,
leader transfer, leave, remaining-participant readback and live logout rejection.
No provider I/O is allowed after restart while the sealed source snapshot is
fresh.

The first real restart run found that leader rejoin updated the participant
family but retained the old room `leader_family_id`, making the next legitimate
leader command return 403. `WatchPartyService.join` now atomically rebinds that
field only when the rejoining account is the current leader. The focused Python
regression also proves that the previously selected session family no longer has
leader authority.

## Commands and results

```text
server/.venv/bin/pytest -q server/tests/test_f21_watch_party_restart.py
1 passed

server/.venv/bin/python server/tests/support/f21_flutter_acceptance.py
prepare: 1 Flutter test passed
restart: 1 Flutter test passed
exit 0
```

The fixture uses loopback-only synthetic services and accounts. It performs no
household device or provider mutation. Physical multi-device decoder timing,
Wi-Fi jitter and receiver-specific playback behavior remain manual hardware
acceptance.
