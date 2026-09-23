# F31 meal editing and shopping handoff boundary

The original foundation and this follow-up close the remaining tablet product
flow in three concrete jobs. `F31` remains pending until this exact head has
independent review and full CI evidence, so queue progress remains **26/125**
and selected-feature progress remains **0/63**.

## Accepted behavior

- The tablet can edit an existing meal's slot and serving count from 1 through
  24. The save preserves recipe, date, person and ACL fields, sends a fresh
  bounded request ID, and uses the exact displayed account/plan revision as its
  optimistic concurrency base. A stale revision is rejected and a failed save
  keeps the current menu visible.
- Shopping preview lists only current, readable Home Assistant todo entities
  that support both add and description. The user selects the destination and
  reviews a second explicit confirmation before any effect. Each ingredient is
  written with its stable F31 marker and counted only after an exact fresh Home
  Assistant readback; accepted replay cannot add the item twice.
- Menu load/save and shopping handoff bind account, Core, home, session family,
  runtime identity, interaction epoch, route and foreground lifecycle.
  Callback throws, logout, route retirement, backgrounding or list capability
  drift stop remaining effects and cannot publish a late success.
- Concurrent retries of one F31 request/item idempotency key share the same
  pending HA todo operation. They cannot race two `todo.add_item` effects;
  changed payloads with the same key remain rejected.
- Account/route authority callback failures are contained. A callback failure
  after the save await retires the displayed plan and cannot publish the late
  edited snapshot, error or busy state.

## TDD and integration evidence

RED commit `3aca2a67419c49ff016a183c57a669b3dda2c167` added the edit/save,
concurrent retry, late-authority and loopback update cases. The old Client had
no edit control, concurrent retries collided in `ActionController`, and the
route callback could escape or retain old state. GREEN commit
`090d48f47d8bf34d0c349afa37acddd64fd3304d` adds the revision-bound edit,
bounded in-memory pending-key join and fail-closed authority handling.

The follow-up RED phase compiled against absent shopping destination bindings
and failed the new slot editor, explicit-confirmation, background-retirement
and stale-CAS cases. GREEN wires the existing verified handoff into the saved
menu while preserving its fail-closed Core lease. A real `TodayRepository` and
`TodayActions` fixture observes exactly one `todo.add_item`, injects the exact
summary and F31 marker into the provider readback, and produces a confirmed
action receipt. The isolated loopback Core fixture now rejects the old plan
revision after the successful edit.

The real loopback Client transport writes a Turkish plan, replays the exact
request without another revision, then edits with `expectedRevision: 1` and
observes revision 2 before proving the old revision conflicts. The focused
tablet suite covers English/Turkish layouts at 600/1280 logical pixels with 2x
text, 48dp actions, scrolling, selection, explicit confirmation and late
lifecycle retirement. The grouped meal-planner tests and targeted Flutter
analysis are the local gate; exact-head CI and independent review remain the
formal completion gate.

## Existing F31 foundation confirmed by audit

- Core stores account-owned meal plans and receipts encrypted, scopes them to
  exact Core/home/account/session family, enforces optimistic account/plan
  revisions, validates person revision and ACL revision, and bounds recipes,
  entries, ingredients, text and receipt storage.
- Client parsing is schema-strict and retains the Core authority tuple.
  Turkish unit/portion scaling and the standalone verified HA shopping handoff
  already have responsive, accessible UI evidence.

## Remaining F31 blocker

- Exact-head independent review and full CI are still pending. Those required
  evidence gates prevent `F31` completion and keep both progress counters
  unchanged. Physical Home Assistant/tablet validation remains separately
  tracked and is not claimed by this software acceptance.
