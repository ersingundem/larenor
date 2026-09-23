# S08.8 verified music command receipt cache TDD evidence

This slice keeps a short-lived, secret-free receipt for a command that the
central Core music manager has already authenticated and confirmed with a
fresh readback. It does not replay an effect, close S08.8 or change the
progress counters.

## Three accepted behaviors

1. Only an authenticated receipt is persisted. The record is bound to the
   exact Core, home and account tuple, installation/Core/manager revisions and
   receiver provider/kind/group/queue identity. It carries no media URI,
   credential, endpoint or display name.
2. Exact integer schema/revisions, strict fields, a two-minute TTL and an
   8 KiB character and UTF-8 quota fail closed. Malformed owned records are
   compare-and-cleared without deleting a replacement owner's value.
3. Restart restoration requires a fresh manager verification with the exact
   session and receiver authority and never resends the command. Delayed reads
   and writes recheck lifecycle authority after awaits; retirement publishes
   no receipt and exact-clears only its own completed stale write.

## RED

Commit `d96d0a71b8105718a897a797a586c093bf6a550d` added persistence,
strictness, restart/no-replay and delayed lifecycle regressions before the
cache contract and controller seam existed. The focused test failed to compile
on the missing types and constructor argument.

## GREEN

Run from the branch head:

```text
flutter test test/features/server/server_music_command_receipt_cache_test.dart test/features/server/server_music_manager_controller_test.dart test/features/server/server_music_manager_cache_test.dart test/features/server/server_music_selection_cache_test.dart test/features/server/server_music_manager_models_test.dart
flutter analyze lib/features/server/music_manager/data/server_music_command_receipt_cache.dart lib/features/server/music_manager/data/server_music_manager_controller.dart test/features/server/server_music_command_receipt_cache_test.dart
python3 tool/execution_queue.py validate
python3 tool/execution_queue.py status --summary-only
git diff --check
```

S08.8 remains pending. Wider direct Jellyfin replacement, integrated same-URL
Core replacement/logout E2E, independent review and exact-head CI remain open.
Progress stays 26/125 and 0/63.
