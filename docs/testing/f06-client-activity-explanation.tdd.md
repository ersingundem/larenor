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

## RED and GREEN

| Stage | Evidence | Result |
| --- | --- | --- |
| RED | `72a38846`; focused activity widget suite | The three new tests failed because disclosure, unknown-cause explanation, service/trace evidence, and copy controls did not exist. |
| GREEN | `638cf5f5`; focused activity widget suite | 17 passed, including EN/TR at 600/1280 and 2x text. |
| Contract regression | activity models, read-only API, and widget suite | 26 passed with no skips. |
| Static analysis | owned presentation/model and three focused test files | No issues. |

## Remaining boundary

This slice does not invent rule attribution or claim a physical device cause.
F06 still needs other supported command sources, exact-main review/CI, and its
complete queue evidence before acceptance. Counters remain `15/125` and
`0/63`.
