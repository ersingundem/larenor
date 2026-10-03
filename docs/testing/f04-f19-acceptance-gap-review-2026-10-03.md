# F04/F19 declared software acceptance audit — 2026-10-03

Scope: read-only review of exact test evidence at `3f86082026624d8de6b13c037de203e0c938c158` against current HEAD `7e6d276943a1a34821e7b241ea2e3c5ff0428987`. The reviewed production/test/workflow files are byte-identical at those revisions. No physical or household acceptance is inferred.

## Verdict

Neither feature is ready for acceptance review. Both require implementation/acceptance work before a final CI result can close them; `awaiting_ci` alone is too strong for the remaining explicit criteria.

### P1 — F04 permits a superseded rule/manual decision to reach Home Assistant

`RuleArbitrationService._submit` commits the winning decision and replaces ownership inside a DB transaction (`server/larenor_server/rule_arbitration/service.py:227-294`). `HomeAssistantAdapter.command` then calls `_command_unarbitrated` (`server/larenor_server/home_assistant/service.py:625-655`). Its transport guard rechecks the actor/resource/binding and the caller-provided `authority_guard`, but no arbitration decision/ownership token (`service.py:507-526`; `_fresh` at 183-197). The rule execution caller passes no such arbiter guard (`server/larenor_server/home_assistant/rules.py:197-205`).

Therefore a manual intervention or higher-priority rule can supersede decision A after A commits but before A calls the provider. A still passes the HA guard and can write. Only the post-effect `_complete_arbitration` detects stale ownership (`rule_arbitration/service.py:302-339`; HA `service.py:655-664`), which is too late to prevent the superseded effect. The four-slot semaphore is capacity control, not same-device serialization.

Required closure: bind the exact decision/effect token to the before-send provider guard (or provide equivalent same-device serialization with ownership revalidation), and exercise both orders of held A versus superseding manual/higher-priority B, expiry before send, stale completion, cancellation, and late provider response. The current F04 server test has only two sequential cases (`server/tests/test_f04_rule_arbitration_final.py:27-107`); the named Flutter gate is sequential manual→suppressed rule→restart (`test/features/core_ha/core_ha_rule_arbitration_normal_core_test.dart:108-234`). The evidence doc itself keeps the complete concurrency/expiry matrix open (`docs/testing/f04-normal-core-rule-arbitration-2026-09-30.md:35`).

### P1 — required CI does not execute either named Client→Core runner

`server-test.yml` invokes shards discovered from `server/tests/**/test_*.py`; `tool/server_test_shards.py:67-78` excludes both support executables. There are no workflow references to `f04_flutter_acceptance.py`, `f19_flutter_acceptance.py`, their environment variables, or their named Flutter tests.

`analyze-test.yml:48-106` does collect every `test/**/*_test.dart` through `tool/flutter_test_shard.py:10-18`, but the F04 test skips unless its three F04 environment variables exist (`test/features/core_ha/core_ha_rule_arbitration_normal_core_test.dart:101-109` and trailing skip), and F19 skips unless its five runner variables exist (`test/features/server/server_multi_core_normal_test.dart:101-109,184-191`). Broad CI sets none of them. Consequently broad CI can report green after skipping the two real Client→normal-Core paths. `android-build.yml:17-30` merely calls these reusable workflows; it adds no named F04/F19 job.

Required closure: register source-bound named jobs/steps that run the support executables and aggregate them into the required workflow result. A local exact-commit run remains valid scoped test evidence, not CI evidence.

### P1 acceptance gap / evidence mismatch — F19 does not test declared rejection or restore collision

The named test proves a successful dual-authority check and profile switching: `verifyCrossHomeAuthorization(profileA)` is expected to return normally, followed by successful A/B activation (`test/features/server/server_multi_core_normal_test.dart:156-164`). It does not trigger `independent_authorization_required`, despite the queue evidence label claiming “cross-home rejection.” The production rejection branches are at `server_account_controller.dart:671-721`, and no test references that error code.

The production identity-collision branch at `server_account_controller.dart:856-889` can throw `identity_conflict`, but no test references that code either. The registry rejects duplicate decoded authority tuples (`server_home_registry.dart:74-120`), yet the named F19 runner uses its own plain file store (`server_multi_core_normal_test.dart:11-77`) and tests neither restored duplicate authorities nor the production secure-store collision/migration path. The evidence doc expressly leaves the complete backup-identity matrix open (`docs/testing/f19-two-normal-core-acceptance-2026-09-30.md:36`).

Required closure: add normal-path negative gates for wrong/mismatched cross-home authority and restored duplicate authority identity, including late/cancelled verification isolation. Correct the “cross-home rejection” evidence wording unless such a rejection test is added.

### P2 — F19 covers service/token separation, not the declared data/search/cache matrix

The named path creates one service per Core, validates two distinct Core/home identities, verifies each owned Jellyfin token once, and proves B still works while A is offline (`server_multi_core_normal_test.dart:117-181`; support runner `f19_flutter_acceptance.py:120-138`). That is good service/token and offline independence evidence. It performs no search and inspects no product cache/data projection beyond `/admin/services`. The declared criterion explicitly includes data/token/search/cache isolation, so the current evidence cannot close that matrix. Generic single-session controller tests cover several transport/cancel/late-response cases, but they do not establish multi-home search/cache partitioning.

## Reviewed hashes

- `server/larenor_server/rule_arbitration/service.py` `2fe338ed72ba9a0c74a7362c7a812bb9c34f72463b68537ef46414d889ce2bdb`
- `server/larenor_server/home_assistant/service.py` `eb4115e1ca7f2a76f2c7b18e4f98b3e02c34ef463a05092eb1062dbb05727270`
- `lib/features/server/data/server_account_controller.dart` `f3dd3ecd4d01796cc425425f440184c649f6e74afeefcb6b4b131a080682a4d2`
- `lib/features/server/domain/server_home_registry.dart` `5044c2b067a64ef3def38373715d47b824c8cd7187239c20d24afe05a182c59a`
- `server/tests/test_f04_rule_arbitration_final.py` `a5aa38596db08d9b27cb730d5463cf301b5bba4835590dcaa28ac7eb562763b4`
- `server/tests/support/f04_flutter_acceptance.py` `b1cdf1c12fe5e3f8a7689772831126627852cb87e8c890162b118958cada5a39`
- `test/features/server/server_multi_core_normal_test.dart` `dc48f847701ef619bdc8433ad360a2dc4d64710daac51b41aded2658170b13c7`
- `server/tests/support/f19_flutter_acceptance.py` `56dd308d7235bedff7998328b48fb5ae4eaf956f3f2ee6f9b9e41caeb5fff65e`
- `.github/workflows/server-test.yml` `52ab4631fe9cb710b403ce3f17005d86ca5b685b4e7229648d37720f37749421`
- `.github/workflows/analyze-test.yml` `3c7e78d5ad5c5760e8a71f59c487bedec46dc47365ffa15f4272f784cd24a3c2`
- `tool/server_test_shards.py` `d540f2c79130122104cdcd43d541727e6f31f47d9e7743c88d02bfb39e82321e`
- `tool/flutter_test_shard.py` `3cde9ad1618875d8a68b9fd04942c0a398dc7e6bce9030dbf5d8d0cc84114cab`
- F04 evidence doc `0f20f53209e0e5d9e55326659e4eb6862f429ce9b039acae91456cb27644d47a`
- F19 evidence doc `12c80d081c983376c4d28d227875f7ae88a90ca2af671318d778b98ef9fd2ab2`

Physical Home Assistant, Jellyfin, Headscale, and household effects remain separate MANUAL boundaries and were not evaluated here.
