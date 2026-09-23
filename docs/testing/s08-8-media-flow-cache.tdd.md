# S08.8 media-flow typed-cache contract

This slice adds a bounded persistent cache for Core's strict media-flow model.
It does not close `S08.8`: the queue baseline remains **26/125** and
selected-feature progress remains **0/63**.

## Accepted behavior

- Each record is bound to the exact Core, home and account tuple plus canonical
  media key, flow revision and the ordered service/snapshot revisions from the
  live Core authority response.
- A caller must provide that freshly verified authority before a cached flow is
  readable. A cache hit therefore cannot replace authority verification or
  authorize direct Jellyfin access.
- Schema 1 records expire after two minutes and are limited to 256 KiB. Exact
  TTL expiry, oversized data, malformed JSON, unknown fields, secret-bearing
  fields, future timestamps and contradictory flow data fail closed.
- Cache records contain only the strict Core flow model. Tokens, passwords,
  service URLs, request headers and provider credentials have no serialization
  path.

## TDD evidence

RED commit `test(s08.8): specify scoped media flow cache` introduced the
SharedPreferences persistence, exact tuple/authority/revision, schema, TTL,
quota and corrupt-record expectations. It failed because the cache contract did
not exist. The following GREEN commit added strict model serialization and the
bounded cache implementation.

Focused verification:

```text
flutter test test/features/server/server_media_flow_cache_test.dart
flutter test test/features/server/server_media_flow_api_test.dart \
  test/features/server/server_media_flow_cache_test.dart
flutter analyze lib/features/server/media_flow/data/server_media_flow_cache.dart \
  lib/features/server/media_flow/domain/server_media_flow_models.dart \
  test/features/server/server_media_flow_cache_test.dart
```

## Remaining S08.8 acceptance

This contract does not publish cached results to a screen or playback command.
Catalog/search UI, remaining direct media client replacement, broader cache
integration, logout/same-URL E2E, independent review and exact-head CI remain
open. Counters therefore stay unchanged.
