# S08.8 provider command preview expiry TDD evidence

This slice aligns the Client's central Music Assistant provider command
authority with Core's bounded preview lifetime. It does not execute a provider
effect, contact Music Assistant directly, close S08.8 or change progress.

## Three accepted behaviors

1. A preview uses canonical UTC timestamps and the exact 600-second lifetime
   issued by Core. Shorter, longer or otherwise malformed envelopes fail
   closed in the public model.
2. A response that has already expired, or whose authority has not started at
   the Client clock, never becomes confirmable controller state. The user sees
   the public `music_provider_preview_invalid` code without response details.
3. Confirm checks the same clock boundary before work and again after session
   acquisition. If authority expires across that await, the controller clears
   the preview and sends no confirm POST. Existing route, account and
   single-flight invalidation remain intact.

## RED

Commit `3be9b42246cfa1d60500f11c120a9364b0f0ea65` added exact lifetime,
expired/future response and expiry-during-confirm coverage. The model accepted
off-by-one lifetimes and the controller lacked both a clock seam and expiry
checks.

Independent review found the future-response case had drifted to the machine
clock and therefore duplicated the expired case. Commit `ed50e226` binds both
boundary cases to the same exact UTC instant, so the future-authority rejection
is exercised rather than inferred.

## GREEN

Run from the branch head:

```text
flutter gen-l10n
flutter test test/features/server/server_music_provider_command_test.dart test/features/server/server_music_provider_command_controller_test.dart test/features/server/server_music_provider_command_screen_test.dart test/features/server/server_music_manager_controller_test.dart test/features/server/server_music_manager_models_test.dart
flutter analyze lib/features/server/music_provider_commands/domain/server_music_provider_command_models.dart lib/features/server/music_provider_commands/data/server_music_provider_commands_controller.dart test/features/server/server_music_provider_command_test.dart test/features/server/server_music_provider_command_controller_test.dart
python3 tool/check_security_policy.py
python3 tool/execution_queue.py validate
python3 tool/execution_queue.py status --summary-only
git diff --check
```

The combined provider model/controller, EN/TR 600/1280 tablet screen and
central manager regression package passed 40/40 tests.

S08.8 remains pending. Wider direct Jellyfin replacement, integrated same-URL
Core replacement/logout E2E, independent review and exact-head CI remain open.
Progress stays 26/125 and 0/63.
