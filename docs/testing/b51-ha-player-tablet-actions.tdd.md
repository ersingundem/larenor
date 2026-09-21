# B5.1 Home Assistant and player tablet action acceptance

## Scope

This independent B5.1 slice aligns three high-use action surfaces with the
shared tablet interaction contract: Home Assistant action execution, the
isolated Home Assistant web frontend, and Jellyfin playback controls. The
software matrix targets Huawei MatePad class windows and resizable DeX windows.
Physical device and TalkBack traversal remain release gates.

## Three acceptance criteria

| Criterion | Accepted behavior | Evidence |
| --- | --- | --- |
| Home Assistant actions | Catalog rows, entity selection, and Run use native named controls with explicit 48 dp minimum targets. Enter opens the real action route. The route continues to bind the exact HA configuration, catalog action metadata, entity snapshot, source route, interaction epoch, and lifecycle; a replaced account or stale modal cannot issue a service call. | EN/TR, 600/1200 px, 200% text matrix plus typed-value confirmation and service-call tests in `ha_actions_test.dart` |
| Home Assistant frontend | Back and reload live in the shared Larenor surface with a 56 dp adaptive navigation bar, 48 dp native targets, localized TalkBack names, and keyboard activation. Reload restarts only the current isolated website session. A delayed back result is also bound to its captured route and session generation, while account, loading, error, idle, background, and covered-route transitions retire the old web source. | EN/TR, 600/1200 px, 200% text matrix plus account, lifecycle, covered-route, origin-policy, and late-callback cases in `web_panel_view_test.dart` |
| Jellyfin player | Back, subtitle, audio, quality, and play/pause controls expose localized names, explicit 48 dp targets, and native keyboard activation without changing the full-screen video layout. Every control keeps the existing exact Jellyfin client, item, interaction generation, picker route, foreground, and visible-route authority; late or foreign picker/quality/seek callbacks stay inert. | EN/TR, 600/1200 px, 200% text matrix plus single-flight, account/item replacement, background, idle, track-removal, gesture, and late-quality cases in `jellyfin_player_interaction_test.dart` |

## RED to GREEN evidence

- The RED matrix failed all **12/12** combinations because the three surfaces
  had no stable named action keys and left toolbar/player targets at implicit
  platform sizes.
- GREEN uses the shared settings action tile for the HA catalog, an adaptive
  Larenor navigation surface for the isolated frontend, and localized native
  player controls. All retain the existing fail-closed state owners.
- The three complete focused suites passed **53/53** tests. Targeted
  `flutter analyze` completed with no issues across the three production files
  and their tests.

## Boundaries

Tests use local HTTP, web-view, player, and account fakes. They do not contact a
live Home Assistant or Jellyfin server and do not claim physical Huawei, DeX,
TalkBack, or media-decoder acceptance. Queue progress remains **18/125** and
selected-feature progress remains **0/63**.
