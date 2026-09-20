# B5.1 device and media tablet acceptance — 2026-09-20

This slice keeps the production media controllers and platform bridge behind a
single shared tablet settings surface.

1. **Remote Playback:** refresh, target discovery, item preflight, explicit
   confirmation, play receipt and uncertain outcome remain bound to the current
   Jellyfin account, item, route, interaction epoch and foreground generation.
   A target or refresh callback captured before idle cannot resume after wake.
   English and Turkish 600/1200 layouts expose 48 dp keyboard and TalkBack
   actions at 200% text.
2. **Jellyfin item detail:** folder, series and playable actions retain their
   real navigation and player paths. Account replacement now retires captured
   actions and removes the old item metadata instead of opening it under the new
   account. RED `8d15f7b9` and GREEN `aada0320` cover this boundary.
3. **Playback Power:** refresh and Android battery/notification settings remain
   explicit native bridge calls with visible status. Background or offstage loss
   now permanently retires captured callbacks; idle and bridge replacement do
   the same. Pending reads cannot publish status from a replaced bridge, which
   is refreshed explicitly before new native actions are enabled. Only a newly
   rendered 48 dp keyboard/TalkBack action can open settings. RED `d41224bd`
   and GREEN `dea7ad5e` cover background/offstage; the final acceptance commit
   covers interaction epoch and bridge identity.

The final adversarial pass found and fixed two additional P2 authority gaps.
Remote target/refresh callbacks captured before idle used the new generation
after wake, and playback-power callbacks did not observe interaction epochs or
native bridge replacement. Focused RED tests reproduced both behaviors before
the guards were added. The review also covered retained provider values, late
preflight and power reads, hidden routes, duplicate commands, 2x overflow and
private error text.

The post-rebase pass closed three more P2 surface-authority gaps. A remote
refresh callback retained while the target screen went offstage could clear the
last verified failure; an offstage retained target callback could also enter
preparation and clear that evidence. Both now require the current visible route
or its owned confirmation route before changing state. The passive Jellyfin
receiver launcher likewise rechecks its current `TickerMode` and enabled state,
so a captured callback cannot open receiver discovery from a hidden tablet
pane. None of these guards retries playback or native commands.

The final variable-window audit closed three further P2 gaps. Receiver
discovery now releases its live provider while the tablet is idle or covered
and performs one fresh read after wake. Jellyfin item actions now reflect the
same interaction authority in their enabled semantics instead of merely
rejecting a visually enabled stale action. Playback Power clears retained
device evidence on idle and reads it again after wake. Loading, failure,
disconnected and empty receiver states, plus native power failures, are named
TalkBack live regions; private transport and platform diagnostics remain
hidden.

Focused evidence:

- `flutter test test/features/media/casting/remote_playback_ui_test.dart test/features/media/jellyfin/jellyfin_browse_tablet_contract_test.dart test/features/media/local_audio/playback_power_tablet_accessibility_test.dart test/features/media/local_audio/local_audio_ui_test.dart`
- `flutter analyze lib/features/media/casting/presentation/remote_playback_screen.dart lib/features/media/jellyfin/presentation/jellyfin_item_detail_screen.dart lib/features/media/local_audio/presentation/playback_power_screen.dart test/features/media/casting/remote_playback_ui_test.dart test/features/media/jellyfin/jellyfin_browse_tablet_contract_test.dart test/features/media/local_audio/playback_power_tablet_accessibility_test.dart test/features/media/local_audio/local_audio_ui_test.dart`
- Focused result: **64/64 tests passed**.
- Focused line coverage across the three accepted screens: **377/414
  (91.1%)** — Remote Playback 149/159, Jellyfin item detail 60/75, Playback
  Power 168/180.
- Queue progress remains **17/125** and feature progress **0/63**. Physical
  Huawei/DeX/TalkBack acceptance and the app-wide final visual pass remain
  separate.
