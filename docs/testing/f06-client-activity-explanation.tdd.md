# F06 Android activity explanation TDD evidence

20 September 2026. This local Client slice makes the existing attributed Home
Assistant command history understandable on an Android tablet. It closes three
user-visible criteria without changing queue or selected-feature counters.

## Acceptance slice

1. An expanded activity card shows the verified transaction trace, actor,
   service identity and revision, command, and retained result together. The
   strict history model already rejects a correlation ID that differs from the
   receipt request ID.
2. Current `core_api` and `explicit_command_request` evidence is explained as
   an explicit signed-in actor request. Legacy or unknown attribution says that
   no verified reason exists and never treats nearby timestamps as causality.
3. The EN/TR disclosure and trace-copy controls remain at least 48 dp, work
   from a hardware keyboard, expose copy completion as a live region, and fit
   the 1280 logical-pixel tablet surface at 2x text scaling.

The transaction trace is operational metadata, not a credential. Copying it
does not expose a Home Assistant token, Core access token, endpoint, entity
attributes, or payload bytes.

## Explicit stored rule slice

1. The strict Client union accepts `core_rule/explicit_rule_execution` only
   when the real rule ID, rule revision, service ID/revision, actor and result
   share the receipt trace; missing or mixed provenance fails closed.
2. The activity disclosure presents that verified rule and service evidence
   together. `core_api/explicit_command_request` and `unknown/unknown` cannot
   be relabelled as rule execution, and the explanation never infers a trigger
   from time proximity.
3. The rule disclosure and trace copy remain keyboard operable with at least
   48 dp targets on 600 and 1280 logical-pixel EN/TR tablet surfaces at 2x
   text scale, and copy completion remains a TalkBack live region.

## RED and GREEN

| Stage | Evidence | Result |
| --- | --- | --- |
| RED | `72a38846`; focused activity widget suite | The three new tests failed because disclosure, unknown-cause explanation, service/trace evidence, and copy controls did not exist. |
| GREEN | `638cf5f5`; focused activity widget suite | 17 passed, including EN/TR at 600/1280 and 2x text. |
| Rule RED | `7871d363`; strict rule model and activity UI tests | The model had no closed rule source/reason or rule identity, and the UI could not display the rule evidence. |
| Rule GREEN | `bd9a891b`; focused rule model and activity UI tests | 26 passed; exact rule attribution, one-trace evidence, EN/TR keyboard controls and TalkBack copy status are verified. |
| Client regression | complete `test/features/core_ha` suite | 252 passed with no skips. |
| Server regression | history, Home Assistant, Keenetic, Proxmox, component-egress, migration/context/startup suites | 450 passed; only existing dependency deprecation warnings were emitted. |
| Contract regression | activity models, read-only API, and widget suite | 26 passed with no skips. |
| Static analysis | owned presentation/model and three focused test files | No issues. |

## Remaining boundary

This slice presents only the durable attribution emitted by an explicit stored
rule execution. It does not claim an autonomous trigger or a physical device
cause. F06 still needs exact-main review/CI and complete queue evidence before
acceptance. Counters remain `15/125` and `0/63`.
