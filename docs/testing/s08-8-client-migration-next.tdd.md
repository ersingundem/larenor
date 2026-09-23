# S08.8 central music Client route slice

This slice makes the already implemented Larenor Core music manager reachable
from the verified Core home runtime. It does not close `S08.8`: queue progress
remains **25/125** and selected-feature progress remains **0/63**.

## Accepted behavior in this slice

- A verified Core administrator opens music from the Core home screen and lands
  directly on `ServerMusicManagerScreen`. That screen uses the authenticated
  `/api/v1/admin/media/music-assistant/manager` contract for provider catalog,
  receiver, queue and playback state.
- The Core route never mounts the legacy `MusicCenterScreen` or reads the direct
  Home Assistant connection configuration.
- Losing the exact Core account authority rebuilds the home runtime, removes the
  manager route and publishes no retained manager UI.
- The existing Direct Home Assistant music route remains available only inside
  the explicitly selected direct-home runtime.

## TDD evidence

RED commit `d919d53879ca773a1ba87b007034a9cd1e72a796` added the Core navigation and
authority-loss journey. It compiled and failed because
`core-home-music-action` did not exist. GREEN commit
`916e08991e00fab26a9024a293c27ae22b7c7f59` added the verified-Core route and
admin entry. The same focused test then passed.

The focused Core/music package passed **82/82** tests. It covers the new route,
Core identity and logout retirement, central manager parsing/controller/UI,
and the existing direct music UI. Targeted `flutter analyze` passed for the two
production files and the new test. The one-test coverage run executed **10/10
changed executable lines (100%)**.

## Remaining S08.8 acceptance

The queue item stays pending until all of these are evidenced together:

- the wider media catalog and search, including non-admin user policy, use the
  Larenor API rather than direct Jellyfin or Music Assistant onboarding;
- legacy provider/player mappings move through an explicit preview and user
  confirmation instead of silent adoption;
- persistent media and music records and typed caches enforce exact Core/home/
  account tuple, resource identity, schema/revision, TTL and quota boundaries;
- same-URL Core replacement, authorization loss, restart and approved legacy
  migration pass real Client-to-local-Core E2E, independent review and CI.
