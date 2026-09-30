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
sharing are not established by this metadata fixture. That first slice left the authorized clip-view path open; the second slice
below implements it. F42 owns protected sharing.

## Verified primary contracts

- [Frigate event API source](https://github.com/blakeblackshear/frigate/blob/dev/frigate/api/event.py)
- [Frigate authentication source](https://github.com/blakeblackshear/frigate/blob/dev/frigate/api/auth.py)
- [Frigate Home Assistant camera registry identity](https://github.com/blakeblackshear/frigate-hass-integration/blob/master/custom_components/frigate/camera.py)

These official implementations were read on 2026-09-30; no home-device write
was performed. Fixture output is software contract evidence, not a physical
installation or semantic-model accuracy claim.

## Authorized recording view — second slice

The fixed Core POST `/camera-search/{core}/{home}/clip` accepts only exact recent
opaque search evidence from the same account/session. It re-reads the event,
fetches the actual Frigate `/api/events/{id}/clip.mp4`, and revalidates current
provider permissions, camera registry, local ACL/source/service and event content
before releasing video bytes. Binary reads are bounded at 64 MiB; the generic
service JSON transport retains its prior 16 MiB hard ceiling. Core sends no
provider URL, cookie or provider credential. Content is no-store, scoped by clip
ID and protected by a SHA-256 receipt verified by Client. Capture hash revisions
use a JavaScript-exact 52-bit projection; persisted source revision counters are
unchanged and search evidence must be renewed after restart.

The inline recording view keeps the parent route current. Production playback
uses the existing media_kit native/browser player. Cupertino transport controls
provide play/pause, seek, elapsed/total time and Space/Escape keys. At 200% text
the screen stays scrollable. Closing, foreground or authority retirement removes
the surface, disposes the player, cancels download and deletes the owned native
file or revokes the browser Blob URL. Bytes received after retirement are wiped.
Native cache uses an app-owned temporary namespace; crash remnants are cleaned
on the next first open.

Validation: focused F41 plus transport set passed 122 Server tests. The 29
Flutter tests passed (one explicit normal-Core test is skipped in default runs);
the isolated runner then passed that real Client→normal Core→TCP Frigate test
with genuine MP4 bytes. The checked-in test pattern is FFmpeg-generated H.264,
160×90, two seconds, verified using ffprobe. It is only an external service
fixture, not production dummy media. Native media_kit decode and rendered video
on the target platform are still part of the final device/UI gate; widget tests
substitute only the player rendering boundary. Full combined tests, exact HEAD
CI, physical cameras and protected F42 sharing remain open.

- [Frigate official media API](https://github.com/blakeblackshear/frigate/blob/dev/frigate/api/media.py)
- [Apple video interaction guidance](https://developer.apple.com/design/human-interface-guidelines/playing-video)

F41 is implementation-complete awaiting named final validation; it is not added
to the accepted-feature counter by this slice.
