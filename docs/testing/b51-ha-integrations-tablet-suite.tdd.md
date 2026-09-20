# B5.1 Home Assistant integrations tablet acceptance

## Scope

This independent B5.1 slice reviews the Home Assistant settings pane,
integration registry, config-flow detail, and pending-flow list against the
shared tablet shell and accessibility tokens. The software matrix represents
Huawei MatePad and resizable DeX windows; physical device and TalkBack
acceptance remain separate.

## Three acceptance criteria

| Criterion | Accepted behavior | Evidence |
| --- | --- | --- |
| Registry and detail | The shared service root presents real config entries and actual options, reconfigure, rename, enable/disable, reload and confirmed delete paths. Handler, menu, form and result actions use at least 48 dp targets, native button semantics and physical-keyboard activation. | EN/TR, 600/1200 px, 200% text matrices in `integrations_tablet_accessibility_test.dart` and `add_integration_tablet_accessibility_test.dart` |
| Evidence and authority | The registry exposes saved, reachable and verified HA evidence as separate states. Registry sheets, pending flows and config-flow detail bind one HA client, route, TickerMode and interaction epoch; replacement-account responses and captured submits fail closed. | Three-stage evidence test, destructive-sheet rejection, pending-flow replacement, late detail response and captured-submit tests |
| Shared shell and responsive settings | HA settings, registry and pending flows use the same `SettingsSection`, `SettingsActionTile`, `ServiceRootScaffold` and typography tokens. Real settings routes remain usable at both target widths without 2x text overflow; stale idle/wake navigation does nothing. | EN/TR × 600/1200 × 2x matrix plus settings navigation epoch test in `home_assistant_pane_tablet_accessibility_test.dart` |

## RED to GREEN evidence

- Integration authority RED: selecting Disable from an already-open old-account
  sheet sent `config_entries/disable` to the replacement client. GREEN binds
  the entire sheet/prompt/write chain to one client and current entry, and
  serializes sheets while the chain is active.
- Pending-flow isolation RED: replacing the HA client left `old-flow` visible
  and its callback live. GREEN binds the future and callback to the watched
  client, replacing the list with `new-flow` and rejecting the old action.
- Settings navigation RED: a Tools callback captured before idle/wake still
  opened `HaToolsScreen`. GREEN makes the shared settings row capture and
  validate interaction identity/epoch, route, and TickerMode.
- Config-flow authority RED: the detail screen could accept an old response or
  send an old `flow_id` through a replacement account's client. GREEN binds
  the complete handler/start/submit/poll chain to its original client and
  interaction epoch; old callbacks neither render nor send.
- Final focused run passed **23/23** suite tests across the four files named in
  the matrix. The existing admin workflow regression also passed. Focused
  `flutter analyze` completed with no issues.

## Boundaries

Tests use provider overrides, synthetic WebSocket commands, and an in-memory
HTTP client; no real Home Assistant instance is contacted. This slice does not
claim physical Huawei/DeX/TalkBack acceptance or close the final app-wide B5.1
visual pass. Queue progress therefore remains **17/125**.
