# F06 Keenetic command attribution TDD evidence

20 September 2026. This local Server slice extends F06 beyond Home Assistant
commands by adding a closed, resource-scoped attributed view over the existing
tamper-evident Keenetic command journal. It does not change progress counters.

## Three acceptance criteria

1. Every accepted, executing, and final event binds the same 128-bit request
   trace to the authenticated actor, verified service ID and revision, closed
   command action, status, and result code. Caller text and idempotency secrets
   never enter the response.
2. API commands use the closed `core_api / explicit_admin_request` pair.
   Restart recovery uses `core_recovery / interrupted_after_restart`. Existing
   signed events without attribution remain `unknown / unknown`; their target
   service and actor are read only from already authenticated chain fields. No
   reason is inferred from time or nearby events.
3. `/history/attributed` rechecks a ready admin session and the current
   Core/home/resource before and after the bounded journal read. Wrong home,
   unknown/deleted resource, room IDs, unauthenticated callers, and members
   receive no history. The public sequence is local to the selected resource,
   so another resource's event count is not exposed.

The existing `/history` endpoint remains backward compatible. The new response
is a strict Pydantic contract with forbidden extra fields and at most 50 events.
The journal verifies its full HMAC-backed chain before producing the filtered
view.

## RED and GREEN

| Stage | Evidence | Result |
| --- | --- | --- |
| RED | `fbaacb34`; three focused tests | 3 expected failures: missing endpoint and legacy attribution normalizer. |
| GREEN | `67fba89f`; focused F06 suite | 3 passed. |
| Regression | Keenetic authority, persistent HTTP journal, worker IPC/runtime, S08.9 acceptance, and F06 tests | **81 passed**, no skips. |
| Static | `compileall`, progress gate, queue validation, and diff check | Passed. |

The test run emits only the existing upstream Starlette/httpx and AnyIO
deprecation warnings.

## Remaining boundary

This slice does not attribute unsupported rule engines or claim that a
successful router response proves effects outside the existing verified
readback. F06 still requires its remaining real command sources, Android
consumption of this endpoint, exact-main review, and CI before acceptance.
Counters remain `15/125` and `0/63`.
