# F40 shared resource reservation Android Client

Status: **authenticated software integration ready; F40 remains pending**

Program counters remain **21/125** and **0/63** until physical-device and
multi-resource acceptance close the feature.

This package is stacked on the accepted F40 Core foundation and is not
published. It joins the reducer, authenticated HTTP route, account-bound Client
transport, route-owned runtime, app-shell entry and localized tablet surface.

## Three accepted criteria

1. **Authenticated, bounded Core contract.** The versioned API exposes only the
   current authenticated account/home/resource authority. Snapshot, create,
   cancel, receipt and export bind exact revisions; the journal is verified
   before reads, exports stay bounded and secret-free, and a lost acknowledgement
   is reconciled by actor-owned receipt without replaying the command.
2. **Exact route-owned Client runtime.** The transport revalidates endpoint,
   account generation, Core/home/account/session and route ownership before and
   after every request. Window focus, app lifecycle, route, provider container
   or authority changes retire the API and controller before late work can
   publish retained evidence. Writes are never retried automatically.
3. **Discoverable localized tablet workflow.** The verified-Core home shell
   exposes the reservation route. The adaptive Cupertino surface
   renders at 600 and 1200 logical pixels with 2x text in English and Turkish.
   It presents bounded availability, local start, IANA resource timezone,
   explicit earlier/later DST fold, recurrence, capacity units, create, cancel,
   immutable history and read-only export. Narrow layouts scroll; wide layouts
   use two panels without changing state ownership.
   One lease binds Core,
   home, account, session, route, Core/home/account/member/resource revisions
   and the current calendar revision. Binding, route or lifecycle replacement
   invalidates late snapshots and receipts. Overlap/revision failures have a
   distinct conflict state. A lost create/cancel acknowledgement retains one
   command identifier and reads its receipt; it never emits the mutator again.
   Receipt action, actor, event, resource, calendar transition, schedule and
   occurrence content must all match before state advances.
   The server-provided
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
- Core reducer and authenticated API suite: 6 passed.
- Focused Flutter controller/screen/home-entry/transport suite: 12 passed.
- Focused Flutter analyze: no issues.
- Security, queue, progress, diff, redacted gitleaks and merge-tree checks are
  repeated at the final package head.

## Remaining boundary

F40 remains pending and the queue counters stay unchanged. Configurable multiple
resources plus physical Huawei/DeX rotation, DST and accessibility evidence are
still manual acceptance gates. No synthetic result is described as a physical
device or third-party calendar acceptance.
