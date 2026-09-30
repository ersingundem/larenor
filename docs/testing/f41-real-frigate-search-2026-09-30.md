# F41 real Frigate recording search — 2026-09-30

Normal `create_app` now composes the actual Frigate search adapter. Administrator
setup accepts the exact encrypted Frigate service revision and explicit Home
Assistant camera resource IDs. The adapter resolves enabled Frigate camera
registry identities over the actual authenticated Home Assistant WebSocket;
it revalidates account/session, resource/ACL/binding/service revisions and
Frigate profile camera permissions around provider I/O.

Only fixed Frigate paths are used: `/api/profile`, `/api/config`, `/api/events`,
`/api/events/search` and an exact `/api/events/{id}` read. Password credentials
use the official `/api/login` empty-body response and a private JWT cookie as a
Bearer token. Public `/api/version` proves reachability only. Provider names,
raw event IDs, credentials and raw configuration stay inside Core.

Semantic results come from Frigate's own semantic search. If it is disabled,
Core explicitly reports metadata fallback. The 31-day/16-camera/50-page-size
bounds, 1,000 upstream event ceiling, 16-second overall I/O budget, two-MiB
JSON limit and strict response validation prevent unbounded reads. Scoped
opaque evidence identities and expiring signed cursors detect changed/deleted
events; incorrect-result feedback re-reads the current event and binds the
correction to its actual content and original query. Restart preserves sealed
source configuration and requires fresh cursors/evidence lookup.

The EN/TR Cupertino source surface remains reachable before the first search
context exists. Source changes use explicit compare-and-swap and no fabricated
service or camera defaults. Route, foreground and identity changes retire
late callbacks. The share action uses localized text.

## Evidence and remaining boundary

The focused normal-Core tests use a real TCP/WS Home Assistant + Frigate fixture
and retain normal service management, source storage and adapters. They cover
search, registry provenance, password login, restart, deletion, corrections,
changed permissions/revisions, malformed and foreign events. The actual
Flutter acceptance runner starts normal Core over TCP and sends login, source
setup, context, search and feedback through the real Client API. It substitutes
only the external service fixture, not Core providers or route handlers.

Recorded commands:

```text
server/.venv/bin/python -m pytest -q server/tests/test_f41_frigate_normal_core.py server/tests/test_f41_camera_natural_search.py server/tests/test_f41_camera_search_api.py --tb=short
flutter test test/features/camera_search
flutter analyze lib/features/camera_search test/features/camera_search
server/.venv/bin/python server/tests/support/f41_flutter_acceptance.py
```

The earlier focused set passed 24 Python tests, 15 existing Flutter tests and
four new source tests; the real Flutter runner passed its one TCP acceptance.
Password login and first-setup route regressions were added afterwards and
are verified in this commit. Full combined acceptance and exact-head CI remain
open. Physical camera, Turkish model quality, recordings playback and protected
sharing are not established by this metadata fixture. F41 remains active for
the actual authorized clip-view path; F42 owns protected sharing.

## Verified primary contracts

- [Frigate event API source](https://github.com/blakeblackshear/frigate/blob/dev/frigate/api/event.py)
- [Frigate authentication source](https://github.com/blakeblackshear/frigate/blob/dev/frigate/api/auth.py)
- [Frigate Home Assistant camera registry identity](https://github.com/blakeblackshear/frigate-hass-integration/blob/master/custom_components/frigate/camera.py)

These official implementations were read on 2026-09-30; no home-device write
was performed. Fixture output is software contract evidence, not a physical
installation or semantic-model accuracy claim.
