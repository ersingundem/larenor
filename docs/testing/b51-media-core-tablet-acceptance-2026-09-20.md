# B5.1 media and Core tablet acceptance

## Scope

This slice covers the Core home status surface, Jellyseerr discovery/request
entry points, and qBittorrent download/import management. It keeps the real
routes, provider reads, action receipts, file picker flow, and service writes.

## Acceptance criteria

| Surface | Acceptance evidence |
| --- | --- |
| Core home status | Verified/recovery state, people, account management, source selection, and resource cards remain on the shared tablet surface. Navigation is constrained by the active interaction epoch, current route, and visible `TickerMode`. |
| Jellyseerr | Search and request writes retain the existing exact-client, receipt, replay-blocking, and account guards. Retry and My Requests navigation are additionally bound to the exact connection result and current media session, so retained callbacks cannot cross accounts. |
| qBittorrent | List refresh, add/import, pause, resume, and delete continue through the authenticated client, bounded modal, action receipt, and delete-files-off contract. An error-state retry retained across account replacement cannot invalidate the replacement account. |

English and Turkish tablet checks cover 600 and 1200 logical pixels at 200%
text, 48 dp targets, keyboard navigation, TalkBack headings/actions, narrow DeX
layout, private-error suppression, and real action-state transitions. RED
`8b21e36a` covers the Jellyseerr stale routes and RED `fc81f3cc` covers the
qBittorrent recovery callback. GREEN `af691cf4` and `2794bb8b` close those
boundaries.

## Verification

- `flutter test test/features/home_scope/core_home_status_tablet_accessibility_test.dart test/features/media/jellyseerr/jellyseerr_home_tablet_state_test.dart test/features/media/qbittorrent/qbittorrent_ui_test.dart`
- Targeted `flutter analyze` over the three production screens and tests.
- Queue/progress, diff hygiene, and merge-tree checks against `origin/main`.

The focused tests use synthetic providers and HTTP clients. They do not contact
a Core, Jellyseerr, qBittorrent, or Home Assistant host.
