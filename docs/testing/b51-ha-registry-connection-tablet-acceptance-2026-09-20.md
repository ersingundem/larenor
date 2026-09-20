# B5.1 Home Assistant registry and connection tablet acceptance

This slice covers the real area list, device list, registry editor, and Home
Assistant connection pane. It records three acceptance criteria without closing
the wider B5.1 milestone; progress therefore remains 17/125 and 0/63 features.

| Criterion | Evidence |
| --- | --- |
| The registry and connection journeys use the shared tablet shell, localized EN/TR copy, 48 dp content actions, keyboard and TalkBack semantics, and remain usable at 600/1200 logical pixels with 200% text. Icon-only navigation actions have localized accessible names, device search has a 48 dp target, and registry switches expose their full 48 dp row with toggle state. The registry detail is capped at 1000 px on wide DeX/tablet windows. | `areas_tablet_accessibility_test.dart`, `devices_tablet_accessibility_test.dart`, `registry_editor_tablet_accessibility_test.dart`, `connection_pane_tablet_accessibility_test.dart` |
| The connection pane labels a locally saved connection separately from an observed server response and a validated data read. Saved credentials alone never claim reachability or successful data. | `connection_pane_tablet_accessibility_test.dart` exercises saved, reachable, and verified evidence from `HealthMonitor`; the widget is passive and performs no probe. |
| Captured actions fail closed after account/client replacement, source changes, covered routes, inactive interaction scope, or lifecycle expiry. Async area-picker and registry-save completions recheck their original authority before publishing state. | Provider replacement tests cover area, device, and connection callbacks. Registry editor tests cover covered-route and lifecycle expiry before a synthetic write can be issued. Existing admin workflow tests cover client replacement during async work. |

Production create, rename, delete, refresh, and registry-update actions remain
available after explicit user activation. Verification uses synthetic providers
and sockets and contacts no physical Home Assistant host, so the review itself
performs no HA write.

## Verification

- Focused Flutter tests for the four tablet surfaces plus admin workflows.
- Targeted `flutter analyze` for their production and test files.
- Queue validation, progress validation, `git diff --check`, gitleaks, and a
  clean `git merge-tree` against the assigned main commit.
