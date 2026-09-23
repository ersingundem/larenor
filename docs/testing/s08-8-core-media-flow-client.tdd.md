# S08.8 Core media-flow Client contract

This slice adds the first Client adapter for Core's existing revision-bound
request-to-playable media-flow API. It does not close `S08.8`: the current
queue baseline remains **26/125** and selected-feature progress remains
**0/63**.

## Accepted behavior

- The Client accepts only canonical `movie:tmdb` and `series:tvdb` identities.
  A URL, token-bearing value or other legacy service identifier fails before
  network I/O.
- One explicit read performs the Core authority handshake first, then sends the
  exact flow revision and ordered Seerr/qBittorrent/Sonarr/Radarr/Jellyfin
  source revisions to the read endpoint. There is no retry or direct media
  service fallback.
- Response parsing is exact and bounded. Unknown or secret-bearing fields,
  reordered sources/stages, mismatched revisions, contradictory aggregate
  state, malformed episode coverage and authority drift fail closed.
- The controller binds the read to the exact signed-in administrator account,
  account generation and route callback. Logout or authority loss retires a
  delayed result; an active HTTP 401 follows the normal exact-session
  retirement path.

## TDD evidence

RED commit `6aacc7088ba1c8c49f70aedb70c0b1812938c2d9` introduced the
authority/read and fail-closed expectations and failed because the Client
adapter did not exist. GREEN commits
`1da7efb8e58d230c37d5ab1548912aa905e2334c` and
`4de88dbdac02543899326f65083d5b60445c1e3b` added the strict model/API and
account-bound controller.

The focused Flutter package passed **8/8** tests. The unchanged Core media-flow
implementation passed **22/22** focused Server tests, covering stable double
reads, source revisions, replay/high-water checks, missing seasons, partial
imports and verified hardlink delivery. Targeted Flutter analysis passed.

## Remaining S08.8 acceptance

The adapter is not yet a catalog/search screen or playback dispatcher. Direct
Jellyfin catalog/search/playback and remaining direct media clients still need
central replacements. Explicit legacy provider/player mapping confirmation,
wider tuple/resource/schema/TTL/quota persistence, integrated same-URL
replacement/logout E2E, independent review and exact-head CI remain open.
