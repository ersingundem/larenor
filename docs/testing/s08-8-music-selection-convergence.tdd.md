# S08.8 music selection convergence TDD evidence

This slice keeps the central Core music manager's explicit provider and player
choices deterministic under overlapping tablet input. It does not close
S08.8 or change the progress counters.

## Three accepted behaviors

1. Rapid provider choices converge on the latest live-verified provider even
   when an older persistent write completes last.
2. Rapid receiver choices converge on the latest available, enabled receiver
   under the same out-of-order completion. The EN/TR 600 and 1200 tablet/DeX
   tests exercise the selected semantic state at 2x text scale.
3. Logout or account-generation retirement during a delayed save clears its
   result after completion, so a later session cannot restore that stale
   choice. Reconciliation rechecks the exact session, manager, provider,
   receiver, controller epoch and selection epoch after every persistence
   await. Cache compare-and-set/compare-and-clear ownership also prevents a
   retired screen from overwriting or clearing a replacement screen's newer
   choice.

## RED

Commit `5790ebd7c1bb879a1b5f357eb2fd910d26eaaad2` added delayed out-of-order
provider/receiver saves and logout-during-save coverage. The older provider
write won and restored the wrong provider.

## GREEN

```text
flutter gen-l10n
dart run build_runner build
flutter test test/features/server/server_music_selection_cache_test.dart test/features/server/server_music_manager_screen_test.dart test/features/server/server_music_manager_controller_test.dart
flutter analyze lib/features/server/music_manager/data/server_music_manager_controller.dart lib/features/server/music_manager/data/server_music_selection_cache.dart test/features/server/server_music_selection_cache_test.dart test/features/server/server_music_manager_screen_test.dart
python3 tool/execution_queue.py validate
git diff --check
```

S08.8 remains pending. Central catalog detail/playback dispatch, remaining
direct Jellyfin surfaces, explicit legacy player mapping, integrated
same-URL replacement/logout E2E, independent review and exact-head CI remain
open. Progress stays 26/125 and 0/63.
