# FINAL.FUNCTION acceptance routing audit — 2026-10-03

## Snapshot and bounds

This is a read-only audit of the live shared working tree. Git HEAD was
`96b18d724d4886b0462922c70946a5e6f06d4378`, but the worktree contained
root-owned uncommitted integration changes. The SHA-256 values in
`source-manifest.json` therefore bind the exact files reviewed more precisely
than HEAD. No test, build, workflow dispatch, source edit, queue edit, or Git
operation was performed.

The audit covered F04/F05/F06/F16/F20/F54 acceptance criteria, their named
normal-runtime evidence, and required workflow reachability. Physical household,
device, Android/OEM, secure-element and target-host gates remain MANUAL and are
not treated as software blockers here.

## Findings

### P1 — F16 cannot be closed by final CI: the current drill neither proves component health nor has a direct drill acceptance test

`IsolatedRecoveryDrillRunner.execute` restores component volume archives into
an ephemeral directory and immediately appends `componentData`
(`drill_runner.py:156-171`). The only health checks afterward instantiate the
isolated Core, reject a recreated bootstrap, run SQLite integrity on the Core
database, and check that the database file is nontrivial
(`drill_runner.py:174-184`). No component process, component database,
service-specific verifier, or component health endpoint is opened. Thus the
success receipt currently equates safe archive extraction with the acceptance
criterion's "component health proof."

A repository-wide search under `server/tests` and `test` found no test
referencing `RecoveryDrill`, `core_recovery_drills`, the drill endpoints, or
`IsolatedRecoveryDrillRunner`. The Flutter backup test only exercises mocked
plan/schedule/history reads; it does not create, dispatch, cancel, restart, or
observe a real drill. The component capture/restore native workflows validate
the Btrfs/restore primitives, not the production drill API, durable scheduler,
effect-disabled isolated Core, or receipt.

Required closure is bespoke software work before CI: define and implement a
truthful component-health verifier (or narrow the criterion/receipt rather than
claiming health), then add a named real Client -> normal Core -> packaged worker
drill covering success, restart, cancellation/expiry/authority change, corrupt
component input, bounded history, and zero production effects. Exact-head
component capture and restore workflows remain necessary after that. Android
Build does not invoke either component-native workflow
(`android-build.yml:16-30`), so they must also be explicit members of the
final exact-source set.

### P1 — the current required CI graph does not execute the F05, F20, or F54 named production gates

The required normal-Core matrix contains only `f04` and `f19`
(`analyze-test.yml:108-152`). Server shards discover only
`tests/test_*.py` (`tool/server_test_shards.py:67-85`), so they cannot
discover executables under `server/tests/support`. No workflow references
`f05_flutter_acceptance.py`, `f20_flutter_acceptance.py`,
`f54_flutter_acceptance.py`, or `f54_native_service_acceptance.py`.

This is material for F54: the production WorkManager/Core test explicitly calls
`assumeTrue` when `LARENOR_F54_NATIVE_FIXTURE` is absent
(`LocalNotificationNormalCoreWorkerTest.kt:38-41`). A broad Android JVM run
can therefore be green while skipping its normal HTTPS Core path.

Consequently, all twelve currently required contexts can be green without
rerunning these exact-head production paths. Legitimate closure requires:

- add F05 and F20 to a source-bound normal-Core required job;
- add F54's Flutter normal-Core runner and its HTTPS Core -> actual WorkManager
  orchestration as required jobs, preserving the exact one-test/zero-skip XML
  check already enforced by the runner;
- bind independent review and resulting CI evidence to the exact final source.

The existing local named runs remain valid scoped evidence; they are not current
required-CI evidence.

### P2 — F20 still lacks Client checkpoint-store/controller failure regressions required by its generic acceptance clause

The F20 named runner covers two happy Client lifetimes, checkpoint pin/rotate,
Core restart, a real audited mutation, and one SQLite actor tamper. Server tests
strongly cover chain deletion/reordering/forgery/whole-valid rollback,
authorization, quotas, and no silent repair.

The entire Client test directory contains only
`core_audit_api_test.dart` and `core_audit_normal_core_test.dart`. Neither
drives a delayed response through account/route disposal or corrupt/oversize/
malformed retained checkpoint storage. The production
`CoreAuditController` and `CoreAuditCheckpointStore` contain explicit
cancellation, epoch, parsing, revision and limit branches, but current evidence
does not execute those branches. This leaves the queue's explicit
authority/cancellation/corrupt-or-late-response/limits clause only partially
proved on the Client boundary.

Before acceptance, add focused Client regressions for late completion after
retirement, corrupt/oversize checkpoint read, failed or uncertain checkpoint
write/rotation, and revision/limit failure without replacing the trusted
checkpoint. The existing normal runner should then execute at exact head in the
required matrix. Physical secure storage remains a separate MANUAL gate; the
test-only file backend is not a physical-keystore claim.

## Feature routing decision

| Feature | What current final required CI can establish | Additional closure |
|---|---|---|
| F04 | After the private same-device dispatch repair is integrated, the new concurrency test is a normal `test_*.py` shard input and the source-bound F04 Client/Core runner is now in required Analyze & Test. | Independent review must pass. F04 also depends on F05, so F04 cannot be accepted while F05 remains unaccepted. Household HA effects remain MANUAL. |
| F05 | Broad shards cover its seven server cases, but not the named two-lifetime Flutter/Core runner. No additional production behavior blocker was found in the sampled workflow/restart/reconcile/authority/limit paths. | Register the named runner in required CI, rerun it at final exact head, and record independent review. Household partial effects remain MANUAL. |
| F06 | Already accepted on exact `2169dd6fd9e3a8b3274413040f2b575600e38540` with test/review/three CI records. Current server shards collect `test_f06_rule_attribution.py`. | No bespoke reopening is justified. Final combined regression protects the new F04 integration; physical causality remains outside the claim. |
| F16 | Component capture/restore workflows can prove native primitives when explicitly run; broad Android Build alone cannot. | Production component-health semantics plus a named real drill lifecycle are missing, so CI alone cannot close it. F05 dependency must also be accepted. |
| F20 | Broad tests cover server integrity; current final CI cannot execute the named Client/Core runner. | Add the Client failure regressions above, register the named runner, run exact-head CI, and record review. Device secure storage remains MANUAL. |
| F54 | Broad Flutter/Kotlin tests cover many local boundaries, but the actual normal-Core Worker test skips without its runner fixture; neither named runner is in required CI. | Register both required production runners, record review, and close F05 first because F54 has `finishDependsOn: F05`. Permission/reboot/Doze/OEM/physical lock-screen/trust remain MANUAL. |

## Bottom-line routing

From this set, F06 may remain accepted. F04 can become implementation-ready
after its repair/review/current CI, but feature acceptance still waits for F05.
F05 and F54 need required-CI routing plus review rather than another production
rewrite. F20 needs both required-CI routing and the missing Client negative
regressions. F16 needs bespoke implementation and end-to-end drill acceptance;
the current final twelve contexts cannot legitimately close it.

## Root reconciliation

The frozen reviewed-source manifest is [recorded here](final-function-routing-audit-source-2026-10-03.json). Root verified its SHA-256 `132d263b4aa2c376a4d0db84b033a11ccfc72dea70311e887c7001e09a89c7b0` and the original report SHA-256 `131a8023ebb728c564877fb354336b40d293bb01ba8ce9098e842ad812ee0380`. This is a historical live-worktree audit, not a current-head passing review. F16/F20 reopen; F05/F54 remain awaiting named required CI and review. No accepted counter changes.
