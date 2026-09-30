# F28 household member music access — 30 September 2026

Ready household members can discover ready Music Assistant installations, verify the current provider state, browse/search the catalog, and use existing player and longform controls through normal Core. Provider configuration and legacy administrative migration stay admin-only. The member discovery endpoint projects only ready installations and rechecks the current account/session; refresh checks authority again around provider I/O and before persistence. Account, route and foreground retirement discard late Client responses.

Executed on the completion branch:

- Focused music retained/playback/manager and member authority Server tests: 35 passed.
- Flutter manager controller, screen and existing wire acceptance: 24 passed. The member screen test was rerun after fixing its scroll/tap assertion: 1 passed.
- `PYTHONPATH=server server/.venv/bin/python server/tests/support/f28_member_flutter_acceptance.py`: 1 real Flutter Client → normal Core TCP → production MusicPlaybackRuntime → TCP Music Assistant contract provider passed. Member discovery, verification, search and pause/readback succeeded; the same account's admin inventory request returned 403. The runner verifies all seven actual upstream requests.
- Scoped Flutter analyze: no issues.

The isolated acceptance supplies installation/account setup fixtures and an official-shape local provider. It proves the Client role boundary and real HTTP runtime, not a household device, paid audiobook service or the deployed host IPC package. Host package composition, full exact HEAD CI, longform cross-feature acceptance and physical MediaSession/device/provider gates remain open. No final feature acceptance or progress-counter increase is claimed.
