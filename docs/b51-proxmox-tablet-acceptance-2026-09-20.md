# B5.1 Proxmox tablet surface acceptance

**Rebased base:** `bae12c01dd3eb3e9d3a618623fab84f0e8878ef0`
**Progress boundary:** 17/125 queue items, 0/63 selected features. This UI
hardening does not close a feature or replace physical device acceptance.

## Three acceptance criteria

1. **Real actions and current state — local PASS.** Nodes, tasks and backups
   keep their existing Proxmox providers and routes. A captured node action
   reads the current connection and node collection before navigation, and
   refuses loading, failed, removed or changed state. Task-log refresh remains
   available as an explicit action while its first request is pending.
2. **Authority and lifecycle — local PASS.** Account, route source,
   foreground visibility and interaction authority retire captured actions.
   Task reads and log polling stop off-screen; an old operational-settings
   callback, removed node, old backup target or changed account cannot navigate
   or mutate. No UI callback retries a Proxmox command.
3. **Tablet accessibility — local PASS.** EN/TR node, task and backup
   hierarchies render at 600 and 1200 logical pixels with 200% text. Primary
   actions expose one button semantic node, accept keyboard activation and use
   at least 48 dp targets, including task-log refresh.

## Automated evidence

- `proxmox_tasks_lifecycle_test.dart`: polling ownership, pending-log closure,
  refresh hit target and EN/TR 600/1200 tablet matrix.
- `proxmox_nodes_tablet_accessibility_test.dart`: hierarchy, semantics,
  keyboard refresh, removed-node and lost-interaction rejection.
- `proxmox_backups_tablet_accessibility_test.dart`: backup hierarchy and
  keyboard/TalkBack action surface.
- Existing focused mutation/session suites retain account, source, background,
  late-result, no-replay and console trust boundaries.

## Manual boundary

Real Proxmox authentication, backup completion, console launch, Huawei MatePad,
Samsung DeX, physical keyboard and TalkBack device checks remain manual. No
physical result is inferred from widget tests, so this package does not advance
the execution queue.
