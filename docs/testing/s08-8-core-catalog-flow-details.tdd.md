# S08.8 Core catalog flow details TDD evidence

This slice connects verified central catalog results to read-only Core media
flow evidence. It does not mount a direct Jellyfin client, send a playback or
request command, close S08.8, or change progress counters.

## Three accepted behaviors

1. **Canonical flow identity.** Movie catalog keys remain unchanged. Episode
   keys are reduced to their already-validated `series:tvdb:<id>` authority;
   season and episode coordinates never become an invented flow identity.
2. **Central read-only drill-in.** A catalog result is a 48-point semantic
   button that opens one Core flow authority/read. The route shows the four
   ordered request, download, import and playable stages with their verified
   provider source. It exposes refresh only, with no request or playback write.
3. **Exact route authority.** The detail route binds the original account
   generation, current route, visibility and app lifecycle into the existing
   flow controller. Popping a route while its read is delayed publishes no
   stale status. English and Turkish at 600/1200 logical pixels and 2x text
   retain reachable semantic catalog and refresh controls.

## RED

Commit `2950965a4964ee14599237b56d4185297e6fb7d6` added the focused widget
journeys. The package ran and failed because catalog rows were not buttons, no
flow route or Core flow calls existed, and no canonical episode-to-series
mapping or route retirement behavior was available.

## GREEN

```text
flutter test test/features/server/server_media_catalog_screen_test.dart
flutter analyze lib/features/server/media_catalog/domain/server_media_catalog_models.dart lib/features/server/media_catalog/presentation/server_media_catalog_screen.dart lib/features/server/media_flow/presentation/server_media_flow_screen.dart test/features/server/server_media_catalog_screen_test.dart
python3 tool/execution_queue.py validate
git diff --check
```

The single focused test package passes 13 tests. S08.8 remains pending: central
request/queue/playback dispatch, remaining Direct Jellyfin surfaces, explicit
legacy player mapping, integrated logout/Core-switch E2E, independent review
and exact-head CI remain open. Progress stays 26/125 and 0/63.
