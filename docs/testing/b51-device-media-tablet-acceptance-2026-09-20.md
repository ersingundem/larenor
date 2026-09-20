# B5.1 device and media tablet acceptance — 2026-09-20

This slice keeps the production media controllers and platform bridge behind a
single shared tablet settings surface.

1. **Remote Playback:** refresh, target discovery, item preflight, explicit
   confirmation, play receipt and uncertain outcome remain bound to the current
   Jellyfin account, item, route and foreground generation. English and Turkish
   600/1200 layouts expose 48 dp keyboard and TalkBack actions at 200% text.
2. **Jellyfin item detail:** folder, series and playable actions retain their
   real navigation and player paths. Account replacement now retires captured
   actions and removes the old item metadata instead of opening it under the new
   account. RED `8d15f7b9` and GREEN `aada0320` cover this boundary.
3. **Playback Power:** refresh and Android battery/notification settings remain
   explicit native bridge calls with visible status. Background or offstage loss
   now permanently retires captured callbacks; only a newly rendered 48 dp
   keyboard/TalkBack action can open settings. RED `d41224bd` and GREEN
   `dea7ad5e` cover both authority losses.

The adversarial review also covered retained provider values, late preflight and
power reads, hidden routes, duplicate commands, 2x overflow and private error
text. No further P1/P2 issue was found in the rebased diff.

Focused evidence:

- `flutter test test/features/media/casting/remote_playback_ui_test.dart test/features/media/jellyfin/jellyfin_browse_tablet_contract_test.dart test/features/media/local_audio/playback_power_tablet_accessibility_test.dart test/features/media/local_audio/local_audio_ui_test.dart`
- `flutter analyze lib/features/media/casting/presentation/remote_playback_screen.dart lib/features/media/jellyfin/presentation/jellyfin_item_detail_screen.dart lib/features/media/local_audio/presentation/playback_power_screen.dart test/features/media/casting/remote_playback_ui_test.dart test/features/media/jellyfin/jellyfin_browse_tablet_contract_test.dart test/features/media/local_audio/playback_power_tablet_accessibility_test.dart test/features/media/local_audio/local_audio_ui_test.dart`
