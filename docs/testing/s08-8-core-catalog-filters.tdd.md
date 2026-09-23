# S08.8 Core catalog filters TDD evidence

This slice adds bounded kind filtering to the existing read-only Core media
catalog. It does not add playback, fall back to a device-local Jellyfin client,
close S08.8, or change progress counters.

## Three accepted behaviors

1. **User-visible Core filters.** All, Film and TV series controls issue the
   existing Core catalog request with no Direct Jellyfin dependency. The query
   and optional kind stay in the authenticated JSON body and never enter the
   URL.
2. **Exact continuation authority.** A page records the query and kind that
   produced it. A next-page attempt with a different query or kind fails before
   target discovery or any other network request. Valid pagination preserves
   the selected kind and exact Core installation/snapshot authority.
3. **Lifecycle and tablet behavior.** Changing the filter retires an in-flight
   result, starts the selected kind at offset zero and prevents the late result
   from replacing it. EN/TR tests at 600 and 1200 logical pixels with 2x text
   cover the localized three-way control, its 48 dp target, fresh filtering and
   filtered pagination.

## RED

Commit `9995607b5ef1713184e85f85bce4d77ab2b02899` added continuation,
filter-race and EN/TR tablet regressions. They failed because catalog pages did
not bind query/kind and the screen exposed no Core filter control.

## GREEN

```text
flutter gen-l10n
dart run build_runner build
flutter test test/features/server/server_media_catalog_test.dart test/features/server/server_media_catalog_screen_test.dart
flutter analyze lib/features/server/media_catalog test/features/server/server_media_catalog_test.dart test/features/server/server_media_catalog_screen_test.dart
python3 tool/execution_queue.py validate
git diff --check
```

The focused gate passes 14 tests. S08.8 remains pending: central catalog
detail/playback and queue dispatch, remaining Direct Jellyfin surfaces,
explicit legacy player mapping, integrated logout/Core-switch E2E,
independent review and exact-head CI are still open. Progress stays 26/125 and
0/63.
