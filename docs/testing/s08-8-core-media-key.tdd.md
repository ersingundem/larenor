# S08.8 canonical Core media key TDD evidence

This slice closes one catalog-to-Core contract gap without claiming the full
S08.8 migration. Existing `MediaIdentity.key` values are local index keys and
can contain `tv:tmdb`, `movie:tvdb`, or IMDb forms that the Core media-flow API
rejects. Client code now has one closed constructor for the exact Core forms:

- movies require a positive, at-most-12-digit TMDB id and serialize as
  `movie:tmdb:<id>`;
- series require a positive, at-most-12-digit TVDB id and serialize as
  `series:tvdb:<id>`;
- missing, mismatched-provider, zero, negative, and over-range ids return no
  key. No IMDb value, Jellyfin item id, URL, credential, or title is copied.

## RED

Commit `7e03b37a` added the focused contract test before the implementation.
`flutter test test/features/media/hub/core_media_key_test.dart` failed to load
because `core_media_key.dart` and `CoreMediaKey` did not exist.

## GREEN

Run from the branch head:

```text
flutter test test/features/media/hub/core_media_key_test.dart
flutter analyze lib/features/media/hub/domain/core_media_key.dart test/features/media/hub/core_media_key_test.dart
python3 tool/execution_queue.py validate
```

The full S08.8 acceptance remains open: catalog/search/provider/player/queue
must still adopt the central APIs end-to-end, legacy settings require an
explicit confirmed transition, and the remaining persistent records need the
tuple/resource/schema/TTL/quota and authorization-loss evidence. Queue and
feature counters therefore remain 26/125 and 0/63.
