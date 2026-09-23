# S08.8 legacy music migration route TDD evidence

This slice exposes the reviewed legacy-player mapping through the central Core
music manager. It keeps migration explicit and stores only the selected Core
provider and receiver. It does not close S08.8 or change the progress counters.

## Three accepted behaviors

1. The migration action becomes available only after Core has verified the
   current manager and the administrator has selected a current provider and
   receiver. EN/TR 600 and 1200 tablet/DeX coverage verifies a 48-pixel button
   target and button semantics at 2x text scale.
2. Confirmation shows the bounded legacy display name and the selected Core
   provider and receiver. It never displays or copies the legacy URL, token,
   entity id, registry id, device id or config-entry id; confirmation persists
   only the central Core selection.
3. Leaving the current route, losing account ownership or backgrounding while
   discovery is pending retires the operation. The stale result cannot open a
   confirmation, persist a selection or replay after resume.

## RED

Commit `0f69ec154d0b64ee847462980016b49119d71bb4` added the accessible route,
explicit confirmation and lifecycle-retirement expectations before the screen
provided a migration entry point.

## GREEN

Commit `7fe1d8b196f9726d0341706aff3e476a1970e27d` added the guarded migration
route, localized copy and lifecycle/current-result checks.

Independent review found that the multi-target chooser rendered discovery
labels before the mapping's bounded, bidi-safe preview validation and accepted
an unbounded candidate list. RED commit `2c4d0943` proves the unsafe label was
visible. GREEN commit `854cf427` shares the exact preview-shape validator with
the mapping and fails closed above 256 safe candidates before building a
chooser.

```text
flutter gen-l10n
flutter test test/features/server/server_music_manager_screen_test.dart test/features/server/legacy_music_player_mapping_test.dart
# 15 passed
flutter analyze lib/features/server/music_manager/data/legacy_music_player_mapping.dart lib/features/server/music_manager/presentation/server_music_manager_screen.dart test/features/server/server_music_manager_screen_test.dart test/features/server/legacy_music_player_mapping_test.dart
# No issues found
```

S08.8 remains pending. Remaining direct media surfaces, install/configuration
orchestration, emulator E2E, independent review and exact-head CI remain open.
Progress stays 26/125 and 0/63.
