# S08.8 explicit legacy track preference migration UI

Date: 23 September 2026

This slice turns the existing retained Jellyfin language preference reader and
confirmed Core merge into an accessible, user-controlled player journey. It is
stacked on the exact receipt-finalizing playback head
`180dcc04b870b7c5bd1c94533c494d946d9eebef`. S08.8 remains pending, so queue
progress stays **26/125** and selected-feature progress stays **0/63**.

## Three delivered jobs

1. **Strict retained preview/controller.** The controller exposes only the
   normalized audio/subtitle choices and a bounded phase. The direct Jellyfin
   URL, user, token, device identity, raw JSON and storage key remain private.
   Cancel expires the in-memory confirmation receipt without deleting or
   importing the retained record. A throwing callback, route generation drift,
   account logout or exact session replacement retires the controller; results
   arriving after retirement cannot publish state.
2. **Explicit accessible tablet/DeX choice.** The player shows a localized
   English/Turkish card only when a strict retained record exists. It explains
   that the old address and credentials stay on device, lists the sanitized
   choices, and offers separate 48 dp confirm and cancel actions. The 600 and
   1200 logical-pixel matrix passes at 2x text scale with button semantics and
   no overflow.
3. **Real Client-to-Core lifecycle evidence.** A loopback HTTP Core accepts the
   confirmed CAS preference write, including the existing same-request retry
   after a lost response. The wire carries no legacy provider identity or raw
   record. Successful confirmation removes the exact retained record. A real
   account logout followed by sign-in replacement retires the old controller,
   performs no second Core write and preserves the unconfirmed source.

## RED/GREEN and verification

- RED `c2510d10d9698313eddb1ed04cc3297a9af1d986` added the controller,
  EN/TR 600/1200 at 2x, real-loopback and logout/replacement tests before the
  controller and card existed.
- GREEN `09ef79304b984df92e330d03ca015410e6e140fd` implements the lifecycle
  controller, player card, localization and exact confirmation retirement.

```text
flutter test \
  test/features/media/jellyfin/legacy_jellyfin_track_preferences_preview_test.dart \
  test/features/media/jellyfin/legacy_jellyfin_track_preferences_migration_test.dart \
  test/features/media/jellyfin/legacy_jellyfin_track_preferences_controller_test.dart \
  test/features/media/jellyfin/legacy_jellyfin_track_preferences_migration_card_test.dart \
  test/features/media/jellyfin/jellyfin_core_track_preferences_test.dart \
  test/features/media/jellyfin/jellyfin_provider_neutral_preferences_loopback_test.dart \
  test/features/media/jellyfin/jellyfin_player_interaction_test.dart \
  test/features/media/jellyfin/jellyfin_player_lifecycle_test.dart
```

Result: **63/63 passed**. Focused analysis over the seven changed
production/test surfaces reported **no issues**.

## Remaining S08.8 boundary

This slice migrates one retained language-preference record only after explicit
confirmation. It does not claim removal of every direct Jellyfin/other media
client, native renderer acceptance, or complete catalog/search/queue migration.
Those remaining queue gates keep S08.8 and the counters unchanged.
