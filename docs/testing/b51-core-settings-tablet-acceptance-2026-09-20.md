# B5.1 Core settings tablet acceptance — 2026-09-20

This slice keeps the three existing production controllers and their authority
boundaries while moving their screens onto the shared tablet settings surface.

1. **Client Updates:** check, download, verify, install, permission and cancel
   remain real `ClientUpdateController` actions. Signature compatibility,
   account identity and foreground authority are rechecked; a retained callback
   after logout or backgrounding cannot dispatch an install. The English and
   Turkish 600/1200 layouts keep 48 dp keyboard and TalkBack actions at 200% text.
2. **Home Source:** each source row still calls the durable
   `HomeSessionController.choose` path exactly once. Runtime generation, window,
   account, transfer and archive gates reject stale callbacks; the selected
   source remains exposed to TalkBack on both tablet widths and locales.
3. **Screen Program:** add, edit, reorder, enable and confirmed delete still use
   the serialized private store. Idle, background, covered-route and expired
   editor callbacks produce zero writes. The shared section layout remains
   scrollable and keyboard/TalkBack operable with 48 dp targets at 200% text.

Adversarial review covered captured callbacks, account/home replacement,
foreground and route loss, concurrent writes, hidden platform actions, semantic
duplication and narrow DeX overflow. It found two P2 gaps. Existing rule, time,
weekday, mode and confirmation controls inherited the 44 dp Cupertino minimum;
RED `a39366be` reproduces it and GREEN `abdd1c60` gives the content actions
explicit 48 dp bounds. A callback retained after the schedule surface became
hidden could still write because route authority alone did not establish
visibility; RED `e5be4741` captures that boundary and GREEN `a5eaa2a4` binds
schedule actions to the current session, route, and `TickerMode` visibility
while preserving the authorized editor-to-parent save handoff.

The post-rebase review found and closed three further P2 gaps. A cancel callback
captured for an earlier Android Client download could cancel a newer download
after a background/resume cycle; cancel now binds to the exact command
generation and controller. Selecting the already-active home source caused a
redundant durable configuration write; selected rows are inert while failed
source reads still expose recovery choices, and callbacks bind to the captured
runtime identity. The schedule editor's navigation-bar Save target remained 44
dp; Save now uses the shared 48 dp keyboard/TalkBack action surface in content.

The final lifecycle and state audit closed three more P2 gaps. Client Updates
now retires retained release and installed-version evidence whenever route,
window, account, lifecycle, or interaction authority is lost, then performs one
fresh check after authority returns. Home Source exposes recovery and pending
storage state as private, localized TalkBack live regions. Screen Program's
master control is now a 60 by 48 dp keyboard button with named toggled semantics;
loading, empty, saving, read-failure, and safe write-failure states are also
live regions at both tablet widths and 2x text.

Focused evidence:

- `flutter test test/features/client_updates/client_updates_screen_test.dart test/features/home_scope/home_source_tablet_accessibility_test.dart test/features/settings/screen_program_ui_test.dart test/core/home_session_runtime_test.dart`
- `flutter test test/features/settings/screen_program_review_test.dart`
- `flutter analyze lib/features/client_updates/presentation/client_updates_screen.dart lib/features/home_scope/presentation/home_source_screen.dart lib/features/settings/presentation/screen_program_screen.dart test/features/client_updates/client_updates_screen_test.dart test/features/home_scope/home_source_tablet_accessibility_test.dart test/features/settings/screen_program_ui_test.dart test/core/home_session_runtime_test.dart`

The five focused suites pass **67/67** after these fixes. Real update install,
physical Huawei/DeX layout, keyboard and TalkBack acceptance remain manual, so
queue progress stays 17/125 and selected-feature progress stays 0/63.
