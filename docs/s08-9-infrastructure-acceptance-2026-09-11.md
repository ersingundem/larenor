# S08.9 infrastructure acceptance draft — 2026-09-11

## Status

S08.9 is **accepted on main**. The local software acceptance
matrix below passed on `codex/s08-9-infrastructure-acceptance`, based on fixed
commit `a0523620384476a1e7f91359ea05f2d718b461ee`. This acceptance increases the
queue counter by one, keeps the feature counter unchanged, and does not claim
physical-device or real-LAN acceptance.
Independent review closed all P1/P2 findings, PR #136 passed the exact-head
required checks, and merge commit `addead6732383d7b61356b56dd18e9738c762f67`
passed Android, Server Container and Security workflows on `main`.

## Exact local slices

| Slice | Commit | Result |
| --- | --- | --- |
| Cross-adapter Server authority acceptance | `758583bbdb3b89b45fd87a3fe9a249a492bb091e` | Passed |
| Shared Core infrastructure evidence UI | `78eeb40502937952c6497ef887f9e675580fd67b` | Passed |
| Saved/reachable proof, live child guard and denied mapping regressions | `f8f2323983219a018422dcd6076d8e048fb20931` | Passed |
| API replacement and late-preview authority ownership | `a00dc041356ca268dbd879113a1abaabd74b6aee` | Passed |
| Exact HTTP status/error-code preservation | `c70417ab5be838efa6bd7b6cb8e8cf27c1df6ec4` | Passed |

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
first combined focused Flutter gate ran 37 tests. The three review-fix commits
added six regression cases: a stored binding remains configured rather than
reachable, the Keenetic child rechecks its live parent authority and owns
cancellation across API replacement, `keenetic_upstream_denied` stays
permission-denied, and only exact HTTP status/error-code pairs retain their
typed failures. The final focused S08.9 Flutter gate ran **43 tests**; targeted
analysis reported no issues.

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

## S08.9 software acceptance evidence

1. Independent security and retained-state review on the exact candidate
   found no remaining blocker, P1 or P2 after the recorded fixes.
2. [PR #136](https://github.com/ersingundem/larenor/pull/136) passed all
   required checks and merged as
   `addead6732383d7b61356b56dd18e9738c762f67`.
3. Main [Android Build](https://github.com/ersingundem/larenor/actions/runs/34746636418),
   [Server Container](https://github.com/ersingundem/larenor/actions/runs/34746636414)
   and [Security](https://github.com/ersingundem/larenor/actions/runs/34746636323)
   workflows passed on that merge commit. Android E2E completed normally and
   the signed beta release was published and verified.

S08.9's declared `requiredEvidence` is limited to `test`, `review` and `ci`.
Read-only real Proxmox/Keenetic observations and any explicitly authorized
non-destructive command acceptance are tracked separately by
`MANUAL.SERVICES`. Huawei MatePad and Samsung DeX checks for 2× text, keyboard,
TalkBack, lifecycle retirement and PIN-gated command entry are tracked by
`MANUAL.TABLET`; neither manual track is silently counted as S08.9 software
evidence.

S08.9 is therefore `done` with completion commit
`addead6732383d7b61356b56dd18e9738c762f67`. Queue progress is **15/125
(12.0%)**; selected-feature acceptance remains **0/63 (0.0%)**.
