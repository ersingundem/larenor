# S07.4 exact-tree closure review

Date: 2026-09-23

This review starts from `origin/main` `54abbf34`, whose product tree contains
the PR #328 integration. PR #328 head `e154242d` and merge commit `70c667b5`
have the same tree. The review is limited to the S07.4 queue acceptance and
does not claim live provider, HomePod, Cast, CasaOS, or Proxmox acceptance.

## Adversarial finding and TDD repair

The Server response already carried separate `containerState` and
`serviceState` fields, and rejected a verified service without a started
container. The Client validated both values but then discarded them. Its
tablet row displayed stored, historical reachability, and verified status,
without displaying the retained process state. A started process with an
unverified integration was therefore not explicitly distinguishable on the
Client surface.

RED commit `37ac79a6` added the tablet journey. Before the repair, this command
failed on the expected missing label:

```text
flutter test test/features/server/server_media_recovery_test.dart \
  --plain-name 'started process stays distinct from unverified integration'

Expected: contains 'Process started'
Actual: 'qBittorrent. Stored. Reachability not verified. Not verified.'
```

The repair retains the closed Server values in the Client model and presents
process state separately from integration verification in English and Turkish.
No mutation, retry, service address, token, or provider secret was added.

## Acceptance review

| Queue criterion | Exact-tree evidence | Result |
| --- | --- | --- |
| Client manages only media/operator identifiers and provider settings | `ServerMediaRecoveryScreen` exposes refresh, four bounded operator identifiers, and provider-account navigation. The closed parser rejects extra fields, and the screen exposes no service address, token, install, rollback, or command action. | PASS |
| Running process and verified integration remain separate | Server and Client contracts preserve `containerState` and `serviceState`; the new widget journey proves `started` plus `unverified` remains two explicit states. Historical reachability is separately dated and labelled as not live. | PASS after repair |
| Missing capability is explicit | `test_projection_is_complete_when_services_are_missing` requires all seven rows and explicit `missing/unknown/unverified/configure` state. The EN/TR 600/1200 and 2x tablet matrix renders every row. | PASS |
| Cross-service E2E | `test_projection_covers_core_and_all_six_services_from_durable_readbacks` creates and reads Core plus qBittorrent, Sonarr, Radarr, Jellyfin, Seerr, and Music Assistant through the authenticated API. Client model/controller/widget tests cover the same ordered closed projection. | PASS |
| amd64/arm64 restart | `unified_media_stack_managed_ci_test` proves the exact native chain on both architectures and restart after every packaged peer. `unified_media_stack_managed_workflow_test` proves the GitHub-hosted two-architecture workflow remains mandatory. PR #328 workflow run `35608394742` completed the amd64 and arm64 unified-stack native jobs successfully. | PASS for the merged PR #328 tree |

## Local verification

The repaired working tree passed:

- `flutter test test/features/server/server_media_recovery_test.dart` — 13
  tests.
- `flutter analyze lib/features/server/media_recovery
  test/features/server/server_media_recovery_test.dart` — no issues.
- `uv run --project server --locked python -m pytest -q
  server/tests/test_media_recovery_status.py` — 8 tests.
- `python3 -m unittest
  tool.tests.s07_4_unified_install_settings_acceptance_test
  tool.tests.unified_media_stack_managed_ci_test
  tool.tests.unified_media_stack_managed_workflow_test -v` — 20 tests.
- `python3 tool/execution_queue.py validate` and
  `python3 -m unittest tool.tests.execution_queue_test -v` — queue valid and
  24 tests.

## Exact-head CI and merge closure

PR #330 head `223ff08f49e36fc15c41f38c6af9e5a93e6f5e1f` completed the
required GitHub evidence on that exact commit:

- Android Build run `35812635044` passed static analysis, all four Flutter
  shards, all four Server shards and their aggregate gates, the API 35 app
  journeys, and the debug APK build.
- Security run `35812634919` passed secret scanning, platform policy, and
  dependency scanning.
- Unified Media Stack Native Acceptance run `35812634855` passed the managed
  stack lifecycle and restart chain on both `linux/amd64` and `linux/arm64`.

GitHub merged PR #330 as main `814eaeaca25634e9e7f2eb51f85a7cefd65c5591`
on 2026-09-23. The required test, review, and CI evidence therefore share the
exact completion commit `223ff08f`; S07.4 can move from `awaiting_ci` to
`done`. Live provider, receiver, and physical-home checks remain outside this
software acceptance.
