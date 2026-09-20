# B5.1 managed integrations tablet evidence

## Scope

This slice follows `B5.1` in `docs/EXECUTION_QUEUE.md`. It covers the complete
**Manage Integrations** screen group: its eleven service entries, loading and
failure states, passive connection evidence, enable/disable controls, and real
destination routes. The final whole-product visual pass remains a separate
`FINAL` acceptance item.

## User journeys

- A tablet user can distinguish opening a service from enabling or disabling
  it, using touch, a keyboard, or an accessibility service.
- A user never sees a false disabled state while saved choices are loading.
- A failed read can be retried without exposing private storage details.
- A pending or failed write retains one named control, rejects a duplicate
  action, and leaves the prior durable choice visible.
- Every listed service opens its real screen from the shared settings design.

## RED and GREEN evidence

| Stage | Command | Result |
| --- | --- | --- |
| RED | `flutter test test/features/settings/manage_integrations_tablet_accessibility_test.dart` | 7 intended failures: missing named controls and missing loading/error states |
| GREEN | same focused test | 11/11 passed after the screen and write-state changes |
| Related regression | `flutter test test/features/settings test/shared/widgets/settings_action_tile_test.dart test/features/health/integration_health_status_test.dart` | 191/191 passed |
| Static analysis | `flutter analyze` on the four changed Dart targets | no issues |

## Test specification

| Guarantee | Test type | Evidence |
| --- | --- | --- |
| EN/TR at 600/1280 px and 200% text has no overflow; open and switch controls are separate, named, keyboard reachable, and at least 48 px high | Widget | `manage_integrations_tablet_accessibility_test.dart` |
| Loading and read failure never render an invented off state; retry recovers and raw errors stay private | Widget/integration | same test |
| Enter opens the real Jellyfin route without changing visibility | Widget/integration | same test |
| All eleven service buttons push real destination routes | Widget/integration | same test |
| Pending writes keep a stable disabled switch, expose progress, and reject duplicate writes | Widget | same test |
| Failed writes keep the previous state and show localized safe copy | Widget | same test |
| Saved/reachable/verified health evidence stays passive and does not start remote clients | Regression | `integration_health_status_test.dart` |

## Coverage and limits

Focused coverage recorded `145/156` lines (92.9%) for
`manage_integrations_screen.dart`, `29/30` (96.7%) for
`settings_service_tile.dart`, and `36/36` (100%) for
`settings_action_tile.dart`. All remote-service tests use local providers and
synthetic stores; no Home Assistant, media service, router, or Proxmox host was
contacted. Physical Huawei/DeX/TalkBack acceptance and the final app-wide UI
pass remain separate queue items.
