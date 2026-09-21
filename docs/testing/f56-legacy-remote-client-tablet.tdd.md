# F56 legacy smart-remote tablet acceptance

This package adds an Android tablet and DeX management surface over the merged
F56 Core boundary. Queue progress remains 22/125 and selected-feature progress
remains 0/63. Physical IR/RF emission, provider-specific bridge setup, learning
administration, and real tablet hardware acceptance remain explicit delivery
gates; the software never claims those outcomes from an HTTP receipt.

Exactly three user acceptance criteria are in scope:

1. An authenticated admin-only Core catalog, preview, confirm, and readback API
   exposes only the exact home/account/session-family authority and the
   secret-free device/profile projection. The trusted provider is registered at
   Core startup; encrypted preview, dispatch-attempt, receipt, and audit state
   survives restart. Stale revisions, foreign route scope, missing providers,
   duplicate authorization headers, and unknown readbacks fail closed without
   dispatch.
2. The user sees stored registration, current reachability, and provider
   verification as separate text-and-icon evidence. Only profile-allowlisted,
   bounded commands appear; raw IR/RF signals, learning payloads, credentials,
   and provider secrets cannot enter the Client device/profile model.
3. A command first obtains an exact Core preview and requires explicit user
   confirmation. Core, home, account, membership, session-family, route,
   device, bridge, provider, profile, code-set, binding, command, repeat, and
   hold values stay bound. Core persists the attempt before invoking the
   provider. Success requires an exact receipt and authenticated readback; lost,
   late, expired, foreign, restart-recovered, or uncertain results fail closed
   without replay. The route is discoverable in the shared Settings shell;
   English and Turkish layouts work at 600 and 1280 logical pixels with 200%
   text, 48 dp actions, keyboard activation, TalkBack semantics, and one- or
   two-column tablet adaptation. Verified delivery never claims verified
   appliance state.

## TDD evidence

The RED contract commit failed because the F56 Client public models, Core API
boundary, controller, and tablet screen did not exist. A second RED contract
proved that the production provider was not registered and receipts disappeared
on restart. The completed matrix now contains nine Core/service/runtime tests,
two authenticated Client transport and
late-callback tests, two controller contract tests, four command-surface
accessibility cases, and four Settings shell cases across EN/TR, 600/1280, and
200% text.
