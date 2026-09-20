# B5.1 camera, media library, and metric tablet acceptance

## Scope

This slice covers the Home Assistant camera grid, Jellyfin library browser,
and Keenetic metric detail surface. Each keeps its real provider and route
while binding retained actions to the exact result or controller authority
that rendered them.

## Acceptance criteria

| Surface | Acceptance evidence |
| --- | --- |
| Cameras | Refresh and viewer navigation require the current entity result, foreground session, visible route, and active `TickerMode`. Replacing the entity result invalidates a captured camera callback, and load failures render localized safe copy without raw diagnostics. |
| Jellyfin library | Refresh and item navigation require the current library result and visible session. A captured refresh cannot invalidate or read the replacement account result. |
| Keenetic metrics | Refresh uses the exact displayed telemetry controller. A callback captured before controller replacement cannot refresh either the retired or replacement controller. |

All three screens use the shared tablet surfaces. The focused matrix covers
English and Turkish at 600 and 1200 logical pixels with 200% text, 48 dp action
targets, TalkBack button/header semantics, and keyboard activation. RED
`bd7bc126` demonstrates all three stale-action paths; GREEN `c5ab7d28` closes
them without introducing network calls in the tests.

## Verification

- `flutter test test/features/admin/cameras_tablet_accessibility_test.dart test/features/keenetic/keenetic_metric_detail_tablet_accessibility_test.dart test/features/media/jellyfin/jellyfin_library_tablet_accessibility_test.dart`
- Targeted `flutter analyze` over the three production screens and tests.
- Queue/progress, diff hygiene, and merge-tree checks against `origin/main`.

The tests use synthetic provider data and controllers. No camera, Jellyfin
server, or Keenetic router is contacted.
