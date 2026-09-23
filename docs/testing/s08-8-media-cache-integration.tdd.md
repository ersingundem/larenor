# S08.8 verified media cache integration

Date: 23 September 2026

This slice connects the existing bounded Core catalog and media-flow caches to
the tablet routes. It is stacked on legacy migration head
`49c717ad19cc0b1be5076f7081c3ea4e63c9bf15`. S08.8 remains pending, so queue
progress stays **26/125** and selected-feature progress stays **0/63**.

## Three delivered jobs

1. **Fresh authority before every cache read.** Catalog pages are read only
   after a fresh `/media/catalog/target` response matches the exact
   installation and snapshot revisions. Media-flow records are read only after
   a fresh authority response matches the exact media key, flow revision and
   ordered source revisions. A miss performs the existing Core body read and
   conditionally persists the verified result. No cache path contacts or falls
   back to a Direct provider.
2. **Lifecycle-safe tablet rendering.** Catalog and flow routes render the same
   strict models for a live response and a verified cache hit, with localized
   live-region source labels. A miss followed by Core failure shows a localized
   accessible fallback. EN/TR at 600 and 1200 logical pixels with 2x text scale
   passes without overflow. Route retirement, app pause, logout and exact
   session replacement clear visible state; a write that completed after
   retirement compare-clears only its own exact value.
3. **Real Core boundary evidence.** A real loopback HTTP Core proves first-read
   live persistence, fresh-authority cache hits, logout retirement and a miss
   after a different Core/home replaces the account at the same URL. The
   replacement performs new catalog and flow reads, and media bodies contain no
   password or Direct-provider credential.

## RED and GREEN

- RED `2c7797c86f2871e1fb605586adf3d9084ee2b07c` added controller, tablet,
  lifecycle and real-loopback expectations before cache integration existed.
- RED `8c70e83d3bcb141728bfc073540620fc7513d145` added the explicit accessible
  cache-miss fallback expectation.
- GREEN `d05403843ff9712df5bcf72b951f9c6044c26cff` split fresh authority from body
  reads, integrated both bounded caches, added exact post-write retirement
  cleanup and localized route provenance/fallback UI.

## Focused verification

```text
flutter test \
  test/features/server/server_media_cache_integration_test.dart \
  test/features/server/server_media_cache_loopback_test.dart \
  test/features/server/server_media_catalog_test.dart \
  test/features/server/server_media_catalog_screen_test.dart \
  test/features/server/server_media_catalog_cache_test.dart \
  test/features/server/server_media_flow_api_test.dart \
  test/features/server/server_media_flow_cache_test.dart
```

Result: **50/50 passed**. Focused analysis over the changed production and test
surfaces reports no issues. Queue validation, progress trailers, security,
secret scanning and diff checks are final exact-head gates after restacking on
the accepted migration head.

## Remaining S08.8 boundary

This slice does not claim full retirement of every Direct media client, native
renderer acceptance, every provider/queue path, independent review or
exact-head CI. Those remaining gates keep S08.8 and both counters unchanged.
