# B5.1 camera, media library, and metric tablet acceptance

## Scope

This slice covers the Home Assistant camera grid, Jellyfin library browser,
and Keenetic metric detail surface. Each keeps its real provider and route
while binding retained actions to the exact result or controller authority
that rendered them.

## Acceptance criteria

| Surface | Acceptance evidence |
| --- | --- |
| Cameras | Refresh and viewer navigation require the current entity result, foreground session, visible route, active interaction scope, and active `TickerMode`. Hidden or inactive routes release their camera cards, replacing the entity result invalidates a captured callback, and load failures render localized safe copy without raw diagnostics. Loading, empty, and failure states use one TalkBack live-region contract. The grid keeps bounded card widths while DeX resizes. Every camera name sits over a tested bottom scrim, preserving contrast over bright or changing snapshots instead of relying on the image content. |
| Jellyfin library | Refresh and item navigation require the current library result, Jellyfin account configuration, and visible session. Account replacement expires the route, removes old posters, and blocks captured refresh/navigation before either can reach the new account. |
| Keenetic metrics | Refresh uses the exact displayed telemetry controller. Hidden or inactive routes release metric demand, and a callback captured before controller replacement or interaction expiry cannot refresh either the retired or replacement controller. |

All three screens use the shared tablet surfaces. The focused matrix covers
English and Turkish at 600 and 1200 logical pixels with 200% text, 48 dp action
targets, TalkBack button/header semantics, and keyboard activation. Dedicated
regression tests cover result, account, controller, and interaction expiry
without introducing network calls.

## Verification

- `flutter test test/features/admin/cameras_tablet_accessibility_test.dart test/features/keenetic/keenetic_metric_detail_tablet_accessibility_test.dart test/features/media/jellyfin/jellyfin_library_tablet_accessibility_test.dart`
- The focused suite passes 19/19 tests.
- Targeted `flutter analyze` over the three production screens and tests.
- Queue/progress, diff hygiene, and merge-tree checks against `origin/main`.

The tests use synthetic provider data and controllers. No camera, Jellyfin
server, or Keenetic router is contacted. This software evidence does not claim
physical tablet, DeX, TalkBack, camera, server, or router acceptance. Queue
progress remains 17/125 and feature progress remains 0/63.
