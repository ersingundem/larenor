# S08.8 Core media archive entry

This slice makes the existing central, read-only media archive evidence
discoverable from a verified Core home. It does not close `S08.8`: queue
progress remains **25/125** and selected-feature progress remains **0/63**.

## Accepted behavior

- Only a verified Core administrator sees the archive-health entry. The route
  owns the existing `mediaArchiveHealthControllerProvider`; it never acquires a
  direct Home Assistant, Jellyfin, Arr, qBittorrent or Music Assistant client.
- Refresh remains explicit. The existing Core API discovers one exact ready
  Jellyfin installation, binds its installation and snapshot revisions, and
  fails closed on ambiguous, stale or malformed evidence.
- Signing out retires the route and its auto-disposed controller before any old
  snapshot can remain visible. The central music route remains unchanged.
- The existing English/Turkish card and detail surfaces retain TalkBack,
  keyboard, 2x text and 600/1280 logical-pixel coverage. Archive review stays
  read-only; this route adds no cleanup or playback mutation.

## TDD evidence

RED commit `6cc14c77b1e4772b53aea6219c5c6a467ee7abae` added the verified-Core
journey and failed because `core-home-media-archive-action` did not exist.
GREEN commit `4e26568db17dd5648ff972ac92247c0320343181` added the administrator-only
entry, Core router destination and route-owned archive card.

The focused Core route, central archive API/controller/model/card/detail and
adjacent Core music regression package passed **25/25** tests. It covers exact
authority binding, explicit refresh, stale/denied/offline distinctions, late
result retirement, EN/TR tablet/DeX accessibility and zero direct connection
reads in the Core journey. Targeted Flutter analysis passed for all changed
production and test files.

## Remaining S08.8 acceptance

Direct Jellyfin catalog/search/playback and remaining direct media service
clients still need central API replacements. Explicit legacy provider/player
mapping confirmation, wider tuple/resource/schema/TTL/quota persistence,
same-URL replacement/logout E2E, independent review and exact-head CI remain
open. These gates prevent any progress-counter change in this slice.
