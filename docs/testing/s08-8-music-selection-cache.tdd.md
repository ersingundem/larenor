# S08.8 scoped music provider/player selection TDD evidence

This slice persists explicit provider and receiver choices from the central
Music Assistant manager. It does not migrate or silently adopt a legacy direct
mapping and does not close S08.8.

## Accepted behavior in this slice

1. The record is bound to the exact Core, home and account tuple plus managed
   installation revision, Core revision, provider setup/revision/domain/
   instance and receiver id/provider/kind/group/queue identity. It contains no
   URL, credential, display name or mutable playback state.
2. Schema-v1 data has a 30-day TTL and 8 KiB UTF-8 quota. Unknown fields,
   malformed or future/expired timestamps, changed provider revisions,
   changed receiver bindings and oversized reads or writes fail closed.
3. User provider and receiver choices are restored only after a fresh manager
   refresh verifies the current Core authority and exact mappings. An
   unverified cached manager keeps safe defaults; logout or authority loss
   during a delayed selection read publishes neither manager nor selection.

The manager revision itself is intentionally not a preference identity: it
changes with playback readback. Every restore instead requires a fresh verified
manager and exact stable installation, Core, provider and receiver bindings.

## RED

Commit `c2f3f7d3` added the tuple/revision/schema/TTL/quota, explicit restart
restore, and delayed authorization-loss regressions before the selection cache
or controller integration existed. The focused test failed to compile on the
missing contract and constructor seam.

## GREEN

Run from the branch head:

```text
flutter test test/features/server/server_music_selection_cache_test.dart test/features/server/server_music_manager_controller_test.dart test/features/server/server_music_manager_cache_test.dart test/features/server/server_music_manager_models_test.dart
flutter gen-l10n
flutter analyze lib/features/server/music_manager/data/server_music_selection_cache.dart lib/features/server/music_manager/data/server_music_manager_controller.dart lib/features/server/music_manager/presentation/server_music_manager_screen.dart test/features/server/server_music_selection_cache_test.dart test/features/server/server_music_manager_controller_test.dart
python3 tool/execution_queue.py validate
```

S08.8 remains pending. Legacy direct provider/player previews still need an
accessible explicit confirmation flow, wider direct Jellyfin replacement and
same-URL Core replacement/logout E2E, review and exact-head CI remain open.
Progress stays 26/125 and 0/63.
