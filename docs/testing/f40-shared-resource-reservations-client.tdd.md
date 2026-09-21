# F40 shared resource reservation Android Client

Status: **stacked Client software package ready; F40 remains pending**

Program counters remain **21/125** and **0/63** until the HTTP, app-route and
physical-device acceptance packages close the feature.

This package is stacked on the F40 Core foundation and does not publish either
branch. It adds an independently testable tablet presentation/controller
boundary; route wiring and a real HTTP adapter remain part of the later E2E
package.

## Three accepted criteria

1. **Tablet calendar and DST-visible workflow.** The adaptive Cupertino surface
   renders at 600 and 1200 logical pixels with 2x text in English and Turkish.
   It presents bounded availability, local start, IANA resource timezone,
   explicit earlier/later DST fold, recurrence, capacity units, create, cancel,
   immutable history and read-only export. Narrow layouts scroll; wide layouts
   use two panels without changing state ownership.
2. **Exact authority and uncertain-result behavior.** One lease binds Core,
   home, account, session, route, Core/home/account/member/resource revisions
   and the current calendar revision. Binding, route or lifecycle replacement
   invalidates late snapshots and receipts. Overlap/revision failures have a
   distinct conflict state. A lost create/cancel acknowledgement retains one
   command identifier and reads its receipt; it never emits the mutator again.
   Receipt action, actor, event, resource, calendar transition, schedule and
   occurrence content must all match before state advances.
3. **Role-scoped accessible actions and bounded reads.** The server-provided
   create/cancel grants gate writes while permitted members keep read access.
   Export requests are capped at 256 and must be an exact subset of the current
   authority-bound snapshot. User actions have at least 48 dp height, explicit
   TalkBack semantics, live status announcements and Enter/Space activation.

## Evidence

- RED `bdc3aff3`: controller and screen imports failed before production files
  existed.
- GREEN `ee8883cc`: domain contract, lifecycle controller and responsive tablet
  surface made the focused suite pass.
- Adversarial repair `d8b4ef89`: exact receipt actor/event/resource validation,
  canonical UTC window checks, ordered history, duplicate rejection and
  byte-equivalent export comparison were added.
- Focused Flutter suite: 7 passed.
- Focused Flutter analyze: no issues.
- Security, queue, progress, diff, redacted gitleaks and merge-tree checks are
  repeated at the final package head.

## Remaining boundary

F40 remains pending and the queue counters stay unchanged. The versioned HTTP
adapter, app route/AppLocalizations adapter, isolated Client-to-Core E2E and
physical Huawei/DeX evidence are follow-up acceptance packages. No mock success
is exposed as a connected Core result.
