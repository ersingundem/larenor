# B5.1 media and Core tablet acceptance

## Scope

This slice covers the Core home status surface, Jellyseerr discovery/request
entry points, and qBittorrent download/import management. It keeps the real
routes, provider reads, action receipts, file picker flow, and service writes.

## Acceptance criteria

1. **One tablet shell.** Core home, Jellyseerr, and qBittorrent use
   `ServiceRootScaffold`, `SettingsSection`, `SettingsActionTile`, and the shared
   spacing and typography tokens. `ServiceRouteStatusScaffold` now uses that
   same large-title and inset-card grammar, so loading and failure do not switch
   to a visually different compact route. The Core inventory action introduced
   on `origin/main` remains present after the rebase.
2. **Tablet, DeX, keyboard, and TalkBack.** English and Turkish checks mount at
   600 and 1200 logical pixels with 200% text, then resize the same mounted
   route in the opposite direction. Primary controls remain at least 48 dp,
   section labels remain headings rather than buttons, and Enter activates the
   focused action without overflow or rebuilding service authority.
3. **One state and authority grammar.** Loading, empty, error, and available
   content use the same inset-card layout. Stored, reachable, and verified
   evidence remains distinct wherever the backing provider exposes it; this
   slice never promotes a stored config or transport response to verified
   success. Retry, route, modal, picker, and mutation callbacks require the
   exact provider/client, session generation, visible route, and current
   lifecycle before acting.

| Surface | State and action evidence |
| --- | --- |
| Core home status | Verified/recovery state, people, inventory, account management, source selection, and resource cards remain on the shared tablet surface. Navigation is constrained by the active interaction epoch, current route, and visible `TickerMode`. |
| Jellyseerr | Search and request writes retain the exact-client, receipt, replay-blocking, and account guards. Retry and My Requests navigation are bound to the exact connection result and current media session, so retained callbacks cannot cross accounts. |
| qBittorrent | List refresh, add/import, pause, resume, and delete continue through the authenticated client, bounded modal, action receipt, and delete-files-off contract. An error-state retry retained across account replacement cannot invalidate the replacement account. |

The branch is rebased on `origin/main` at `43fa2a44`. Merge-tree checks against
`codex/s072-auto-media-flow` and `codex/s073-music-client-tablet` are required
before handoff so the shared media shell and Core contracts can land in either
order. This acceptance slice remains recorded at product progress `17/125` and
feature closure `0/63`; physical receiver and end-to-end service gates remain
outside this UI acceptance proof.

## Verification

- `flutter test test/features/home_scope/core_home_status_tablet_accessibility_test.dart test/features/media/jellyseerr/jellyseerr_home_tablet_state_test.dart test/features/media/qbittorrent/qbittorrent_ui_test.dart`
- Targeted `flutter analyze` over the shared state scaffold, three production
  screens, and focused tests.
- Queue/progress, diff hygiene, and merge-tree checks against `origin/main`.

The focused tests use synthetic providers and HTTP clients. They do not contact
a Core, Jellyseerr, qBittorrent, or Home Assistant host.
