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
duplication and narrow DeX overflow. It found one P2 accessibility gap: existing
rule, time, weekday, mode and confirmation controls still inherited the 44 dp
Cupertino minimum. RED `714a139f` reproduces it and GREEN `7bdf83d7` gives the
content actions explicit 48 dp bounds without changing their callbacks.

Focused evidence:

- `flutter test test/features/client_updates/client_updates_screen_test.dart test/features/home_scope/home_source_tablet_accessibility_test.dart test/features/settings/screen_program_ui_test.dart test/core/home_session_runtime_test.dart`
- `flutter analyze lib/features/client_updates/presentation/client_updates_screen.dart lib/features/home_scope/presentation/home_source_screen.dart lib/features/settings/presentation/screen_program_screen.dart test/features/client_updates/client_updates_screen_test.dart test/features/home_scope/home_source_tablet_accessibility_test.dart test/features/settings/screen_program_ui_test.dart test/core/home_session_runtime_test.dart`
