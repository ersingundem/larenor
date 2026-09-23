# S08.8 Core media catalog tablet route TDD evidence

This slice makes the existing central Core catalog search reachable from the
verified Core home. It does not add playback dispatch or close S08.8.

## Three accepted behaviors

1. **Fresh exact target discovery.** Every explicit first/next page discovers
   the current installation set and accepts exactly one ready managed Jellyfin
   installation. Unknown fields, duplicate ids, pagination, malformed steps,
   ambiguous targets, or stale/non-ready state fail closed before catalog
   authority/search. The query remains in bounded request bodies, never URLs.
   A next-page offset remains bound to the first page's installation,
   installation revision, snapshot revision and Jellyfin service revision; a
   replacement source fails before another authority request.
2. **Central tablet search.** The Core home exposes an administrator-only
   catalog route. Search and bounded next-page actions use
   `ServerMediaCatalogController.searchCurrent`; the route never reads direct
   Jellyfin configuration, credentials, clients, or fallback results.
3. **Policy, lifecycle and accessibility.** Members issue no installation or
   catalog request. Logout, account replacement, route loss, backgrounding and
   disposal retire delayed target/search results. Existing EN/TR strings fit
   the 600 and 1200 tablet/DeX surfaces at 2x text scale, with a semantic
   48-point next-page action and real Core router coverage.

## RED

Commit `d92cc278a0d1458afcb7b54cde5765dd71e46d0a` added exact target,
pagination, ambiguous-target/logout, member-policy, tablet and semantics tests.
The focused test failed to compile because `searchCurrent` and
`ServerMediaCatalogScreen` did not exist.

Follow-up RED commit `7ab036fa` paired a valid ready target with every
state/phase/revision/cancellation/error coherence violation from the Server
`MediaInstallation` contract. The first malformed sibling was accepted and
authority plus catalog search still ran.

## GREEN

Run from the branch head:

```text
flutter gen-l10n
dart run build_runner build
flutter test test/features/server/server_media_catalog_screen_test.dart test/features/server/server_media_catalog_test.dart test/features/home_scope/core_home_status_tablet_accessibility_test.dart
flutter analyze lib/core/router.dart lib/features/home_scope/presentation/core_home_status_screen.dart lib/features/server/media_catalog test/features/server/server_media_catalog_screen_test.dart test/features/server/server_media_catalog_test.dart test/features/home_scope/core_home_status_tablet_accessibility_test.dart
python3 tool/execution_queue.py validate
```

The focused batch passes 17 tests. Scoped analysis and queue validation are
clean. Target discovery now mirrors the Server coherence matrix before it
selects the single ready Jellyfin installation, so any malformed sibling
fails closed before authority or search.

S08.8 remains pending. Catalog detail/playback dispatch, non-admin product
policy if required, remaining direct Jellyfin surfaces, explicit player
mapping approval, integrated same-URL replacement/logout E2E, independent
review and exact-head CI remain open. Progress stays 26/125 and 0/63.
