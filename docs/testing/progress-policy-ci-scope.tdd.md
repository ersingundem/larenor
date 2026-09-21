# Progress policy CI scope — TDD evidence

21 September 2026. Progress and execution-queue tooling has dedicated
platform-policy unit, secret and security checks. It does not alter Android,
Flutter or Server runtime products.

## Three acceptance criteria

1. An exact pull-request diff containing only the six reviewed progress/queue
   scripts and tests reuses Android and Flutter runtime evidence.
2. The same exact policy-only diff reuses Server runtime evidence. Required
   check names still start and report the scope decision.
3. Mixed diffs, unknown tools, runtime files, the scope-policy scripts
   themselves, invalid revisions and unavailable Git evidence continue to fail
   open into the complete suites.

RED `39cf07f9` records both scope decisions running the expensive suites for
every reviewed progress-only path. The full Android and Server scope-policy
unit suites, platform security tests, queue validation, diff and secret scan
are the GREEN gates.
