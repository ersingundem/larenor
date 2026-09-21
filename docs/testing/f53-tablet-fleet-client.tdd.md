# F53 managed tablet Client and Settings integration

21 September 2026. This Android Client slice consumes the managed-tablet
contract already merged into Larenor Core and exposes it through the shared,
PIN-gated tablet Settings flow. It does not provision Android Device Owner,
execute privileged native commands, or claim a physical Huawei/DeX result.

## Three software acceptance criteria

| Criterion | Production boundary | Automated evidence |
| --- | --- | --- |
| Fleet status is closed, scope-bound and safe to display | Tablet records and command pages accept only the versioned Core schema and exact Core/home scope. Capabilities, management mode, profile state, policy revision, expiry, terminal state and result must agree; malformed, duplicate, unordered, expired or cross-scope data fails closed. | Model/API/controller tests cover exact capability sets, malformed scope, ordered pages, current Core `policyRevision`/`expiresAt` envelopes and explicit expired receipts. |
| Every action retains exact administrator, session and revision authority | The route-owned controller captures account generation, user, endpoint and Core/home context. Profile/revoke operations use exact device revisions and readback; revoke succeeds only after the Core record advances by exactly one revision. Commands use exact device and desired-policy revisions, a bounded one-minute expiry and one stable idempotency key; known Core rejections never replay and uncertain outcomes can only reconcile with that same envelope. | Controller tests cover stale callbacks, exact readback, stable uncertain reconciliation, actionable policy/expiry rejection codes and no retry after a proven rejection. Model tests reject impossible create/expire/complete timestamp order. Core's existing seven-test F53 policy suite remains the server authority. |
| Tablet management is discoverable and accessible without bypassing Settings authority | `/settings/tablet-fleet`, the Settings split-view category and the Server account entry all converge on the same screen. Missing PIN/admin/route/lifecycle authority shows a locked state and sends no fleet request. The screen uses the shared Cupertino shell, semantic live status and 48dp actions. | Widget/navigation tests cover EN/TR at 600 and 1280 logical pixels with 2x text, keyboard activation, TalkBack semantics, destructive confirmation and PIN-protected deep linking. |

## Verification boundary

Focused Flutter tests cover the Core adapter, controller, screen, Settings
split view, accessibility journey, application route and Server account entry.
Targeted analysis, Core F53 tests, queue/progress policy, security policy,
secret scan, diff and merge-tree checks are final commit gates.

F53 stays open in the execution queue. Device Owner enrollment, Huawei OEM
power behavior, physical heartbeat, kiosk enforcement and DeX window
acceptance require provisioned Android hardware. Until that evidence exists,
Larenor reports only Core-proven capabilities and never treats this software
suite as native command execution proof.
