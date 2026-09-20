# B5.1 admin editors tablet acceptance

Status: software slice complete on current `origin/main`; queue progress remains
**17/125** and feature progress remains **0/63**.

## Acceptance 1 — integration flow editor

- The integration picker, menu and forms use the shared Cupertino tablet shell,
  settings sections and 48 dp action rows.
- EN/TR at 600 and 1200 logical pixels with 200% text covers TalkBack header and
  button semantics plus native Enter activation.
- Every request and progress timer is bound to the exact HA admin client,
  interaction epoch, route visibility and app lifecycle. Returning from idle or
  a lifecycle round trip cannot revive an old handler, retry, form or refresh
  callback.

## Acceptance 2 — automation JSON editor

- The scalable JSON editor and 48 dp save/delete actions remain usable at the
  same tablet matrix; parse and server errors are announced as live regions.
- Load, save and delete use one captured HA administrator authority. Client,
  interaction or lifecycle replacement disables the editor and drops late
  results without navigation or provider invalidation.
- Delete confirmation verifies both the owned dialog route and current admin
  authority before it can issue a destructive request.

## Acceptance 3 — pending discovery and reauthentication flows

- The pending-flow route now uses `ServiceRootScaffold`, `SettingsSection` and
  `SettingsActionTile` for the same spacing, typography, 48 dp targets,
  keyboard behavior and TalkBack structure as the other admin surfaces.
- Loading, empty, error/retry and populated states remain explicit and use live
  status semantics where state changes require announcement.
- A pending flow opens only under the exact captured authority; returning from
  the child route reloads through a fresh generation, while old callbacks fail
  closed after route, client, interaction or lifecycle changes.

## Automated evidence

```text
flutter test \
  test/features/admin/add_integration_tablet_accessibility_test.dart \
  test/features/admin/automation_editor_tablet_accessibility_test.dart \
  test/features/admin/pending_flows_tablet_accessibility_test.dart \
  test/features/admin/admin_workflows_test.dart
```

The focused suite passes 33 tests. Targeted `flutter analyze`, commit progress,
queue validation, `git diff --check`, gitleaks and open-PR merge-tree checks are
required before handoff.

Registry editor files are intentionally excluded because PR #196 owns their
current B5.1 authority and tablet changes. Physical Huawei MatePad, Samsung DeX,
hardware keyboard and TalkBack acceptance remain device gates, so no progress
counter advances in this package.
