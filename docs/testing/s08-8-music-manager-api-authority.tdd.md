# S08.8 music manager API authority TDD evidence

This slice makes the central Larenor music manager transport reject stale or
foreign provider, player and queue authority at the API boundary. It does not
contact Music Assistant or Jellyfin directly, close S08.8 or change progress.

## Three accepted behaviors

1. Manager reads require the exact requested installation id. Refresh results
   additionally require the requested installation and Core revisions before
   the response can become Client state.
2. Catalog search rejects a provider that is not an exact member of the
   supplied manager before network dispatch. Results are bound to the request
   id, manager revision and provider instance.
3. Playback and queue commands reject foreign, unavailable, disabled or
   capability-forged receivers and incoherent seek/media parameters before
   dispatch. A returned receipt must match the exact request, receiver and
   operation.

No request body includes a direct service address, provider token or Jellyfin
credential. The existing controller still requires authenticated receipt plus
fresh manager readback before accepting an effect.

## RED

Commit `28fbc556bd081537fb293fc36789ca2876b1c2ea` added the three transport
authority regressions. All three failed because mismatched manager, provider,
receiver and receipt identities were accepted.

Commit `20238f388c934449a7ad7e949094f1fc40017e32` added a same-identity
receiver with forged queue capability. It reached the command endpoint before
the receiver comparison covered the complete manager-owned value.

## GREEN

Run from the branch head:

```text
flutter gen-l10n
flutter test test/features/server/server_music_manager_api_authority_test.dart test/features/server/server_music_manager_controller_test.dart test/features/server/server_music_manager_cache_test.dart test/features/server/server_music_selection_cache_test.dart test/features/server/server_music_manager_models_test.dart test/features/server/server_music_manager_screen_test.dart test/features/server/server_music_provider_command_test.dart test/features/server/server_music_provider_command_controller_test.dart test/features/server/server_music_provider_command_screen_test.dart
flutter analyze lib/features/server/music_manager/data/server_music_manager_api.dart test/features/server/server_music_manager_api_authority_test.dart
python3 tool/execution_queue.py validate
python3 tool/execution_queue.py status --summary-only
git diff --check
```

The combined manager, cache, selection, provider-command and EN/TR 600/1200
tablet/DeX package passed 65/65 tests.

S08.8 remains pending. Wider direct Jellyfin replacement, integrated same-URL
Core replacement/logout E2E, independent review and exact-head CI remain open.
Progress stays 26/125 and 0/63.
