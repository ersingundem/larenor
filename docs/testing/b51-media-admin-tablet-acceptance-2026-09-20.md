# B5.1 media administration tablet acceptance

## Scope

This slice covers Bazarr wanted-subtitle management, Jellyseerr request history,
and Prowlarr provider administration. It preserves the real connection
providers, HTTP clients, refreshes, subtitle search writes, and indexer toggle
writes.

## Acceptance criteria

| Surface | Acceptance evidence |
| --- | --- |
| Bazarr management | Movie and episode wanted results use the shared tablet hierarchy. Refresh is bound to the exact movie and episode snapshots. Subtitle search is single-flight and bound to the active route, interaction session, and exact client, so a retained action cannot write through an old or replacement account. Upstream diagnostics are not rendered. |
| Jellyseerr requests | Request history keeps its real provider and localized status labels. Refresh is bound to the exact request snapshot, visible current route, and active interaction session; a retained callback cannot invalidate newer results. |
| Prowlarr providers | Refresh and per-indexer enable/disable writes are bound to the exact list snapshot, client, route, and interaction session. Writes are single-flight per indexer and failure copy is secret-free. Protocol and priority copy is localized in English and Turkish. |

English and Turkish tablet checks cover 600 and 1200 logical pixels at 200%
text, 48 dp targets, keyboard activation, TalkBack headings and actions, private
error suppression, and real state transitions. RED `094ee95b` proves the three
retained callbacks previously crossed result or client authority. GREEN
`d0945147` closes those boundaries; `07356e55` closes the remaining Turkish
Prowlarr copy gap.

## Verification

- `flutter test test/features/media/bazarr/bazarr_wanted_tablet_accessibility_test.dart test/features/media/jellyseerr/jellyseerr_requests_tablet_contract_test.dart test/features/media/prowlarr/prowlarr_indexers_tablet_accessibility_test.dart`
- Targeted `flutter analyze` over the three production screens and tests.
- Queue/progress, diff hygiene, and merge-tree checks against `origin/main`.

The focused tests use synthetic providers and HTTP clients. They do not contact
Bazarr, Jellyseerr, Prowlarr, Larenor Core, or Home Assistant.
