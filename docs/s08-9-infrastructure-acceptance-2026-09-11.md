# S08.9 infrastructure acceptance draft — 2026-09-11

## Status

S08.9 is **awaiting CI and independent review**. The local software acceptance
matrix below passed on `codex/s08-9-infrastructure-acceptance`, based on fixed
commit `a0523620384476a1e7f91359ea05f2d718b461ee`. This draft does not increase
the queue or feature counters and does not claim physical-device or real-LAN
acceptance.

## Exact local slices

| Slice | Commit | Result |
| --- | --- | --- |
| Cross-adapter Server authority acceptance | `758583bbdb3b89b45fd87a3fe9a249a492bb091e` | Passed |
| Shared Core infrastructure evidence UI | `78eeb40502937952c6497ef887f9e675580fd67b` | Passed |

The Server slice adds 20 synthetic acceptance cases across Proxmox and
Keenetic. The combined focused Server gate ran 103 tests. It proves that an old
binding or command preview cannot cross an endpoint/credential, resource,
ACL, binding, service revision or session change. A late or uncertain result
remains `unknown`, never becomes success and is never replayed. All upstream
reads and effects are owned fixtures; no LAN endpoint was contacted.

The Client slice uses the existing shared connection evidence vocabulary for
Core-backed Proxmox and Keenetic detail, dashboard and command surfaces. A
successful command receipt proves Core reachability; it does not invent a
timestamped device read. Unknown operation results stay stale/unknown. The
combined focused Flutter gate ran 37 tests and targeted analysis reported no
issues.

## Local commands

```bash
PYTHONPATH=server /private/tmp/larenor-server-test-venv/bin/python -m pytest -q \
  server/tests/test_s08_9_infrastructure_acceptance.py \
  server/tests/test_proxmox_resource_adapter.py \
  server/tests/test_keenetic_resource_adapter.py \
  server/tests/test_proxmox_power_commands.py \
  server/tests/test_keenetic_command_authority.py

flutter test \
  test/features/infrastructure/s08_9_infrastructure_ui_acceptance_test.dart \
  test/features/proxmox/proxmox_power_authority_ui_test.dart \
  test/features/dashboard/core_keenetic_dashboard_card_test.dart \
  test/features/core_proxmox/core_proxmox_ui_test.dart \
  test/features/keenetic/core_keenetic_command_panel_test.dart

flutter analyze \
  lib/shared/widgets/core_infrastructure_evidence.dart \
  lib/features/core_proxmox/presentation/core_proxmox_screen.dart \
  lib/features/keenetic/core/presentation/core_keenetic_screen.dart \
  lib/features/proxmox/core_power/proxmox_power_panel.dart \
  lib/features/keenetic/core_command/core_keenetic_command.dart \
  lib/features/dashboard/presentation/tiles/core_keenetic_tile.dart \
  lib/features/dashboard/presentation/tiles/proxmox_tile.dart \
  test/features/infrastructure/s08_9_infrastructure_ui_acceptance_test.dart \
  test/features/proxmox/proxmox_power_authority_ui_test.dart

python3 tool/execution_queue.py validate
python3 tool/execution_queue.py status
git diff --check
```

## Security and user-interface boundary

- The Client receives redacted Core evidence only. The shared mapper has no
  transport, credential, secure-storage or Direct-provider dependency.
- The dashboard and detail screens do not fall back to a local credential or
  stale cache when Core authority disappears.
- Command buttons remain explicit, at least 48 dp, keyboard reachable and
  usable at 600/1280 logical pixels with 2× text. No status color is the only
  carrier of meaning; the shared widget supplies icon, text and live semantics.
- Proxmox high-risk confirmation and Keenetic second confirmation remain
  unchanged. Loading, failure and unknown states cannot trigger a command.

## Evidence still required before completion

1. An independent security and retained-state review on the exact candidate
   commit.
2. Required GitHub Server, Android/Flutter, security and queue checks on that
   same commit.
3. Read-only real Proxmox and Keenetic observations through Larenor Core,
   followed by an explicitly authorized non-destructive command acceptance.
4. Huawei MatePad and Samsung DeX physical checks for 2× text, keyboard,
   TalkBack, lifecycle retirement and PIN-gated command entry.

Until the automated CI and review evidence are attached to the exact commit,
`S08.9` remains `awaiting_ci`, `completionCommit` remains null, and progress
remains **14/125 (11.2%)** and **0/63 (0.0%)**.
