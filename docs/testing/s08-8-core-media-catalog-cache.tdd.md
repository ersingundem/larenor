# S08.8 scoped Core media catalog cache TDD evidence

This slice adds the bounded persistence contract for one already-verified Core
catalog first page. It does not enable a Direct Jellyfin fallback, cache
pagination, wire cached pages into the tablet route, or close S08.8.

## Three accepted behaviors

1. **Exact Core and resource ownership.** A cached page is bound to the exact
   `(coreId, homeId, accountId)` tuple, query, kind, managed installation id and
   installation/snapshot/Jellyfin service revisions. A different account,
   Core, home, query, kind or revision sees no page. The envelope contains no
   endpoint, header, access token or Direct Jellyfin identity.
2. **Strict bounded persistence.** The schema and every revision require exact
   integers, the first page is reparsed through the closed catalog model, the
   TTL is ten minutes, and both character and UTF-8 byte counts enforce a 16
   KiB quota. Unknown, malformed, expired and oversized owners fail closed;
   cleanup compares the exact raw value so a replacement owner survives.
3. **Lifecycle-safe storage.** Authority is rechecked after delayed reads and
   after compare-and-write. Retirement publishes no cached page. If a write
   completed while the caller retired, only that exact stale value is removed;
   a concurrently installed replacement remains intact.

## RED

Reachable commits `914673fa84c906d566123cbff3e969d707a47fec` and
`916cbb2ed79cb4467ab3e5f55c6c5263826445ff` added persistence, strictness,
replacement-owner and delayed lifecycle tests before the cache contract
existed. The focused target failed to compile because
`ServerMediaCatalogCache` and its scope/resource/backend types were absent.

## GREEN

Run from the branch head:

```text
dart run build_runner build
flutter test test/features/server/server_media_catalog_cache_test.dart
flutter analyze lib/features/server/media_catalog/data/server_media_catalog_cache.dart test/features/server/server_media_catalog_cache_test.dart
python3 tool/execution_queue.py validate
git diff --check
```

The focused package passes 5/5 tests; scoped analysis, queue validation and diff
checking are clean. S08.8 remains pending. The cache still needs active tablet
route integration after fresh resource authority, central catalog playback,
remaining Direct Jellyfin retirement, explicit accessible migration surfaces,
integrated logout/Core-switch E2E, independent review and exact-head CI.
Progress remains 26/125 and 0/63.
