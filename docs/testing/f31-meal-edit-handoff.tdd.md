# F31 meal editing and shopping handoff boundary

This slice closes three concrete gaps in the existing weekly meal and recipe
foundation. It does not close `F31`: queue progress remains **26/125** and
selected-feature progress remains **0/63**.

## Accepted behavior

- The tablet can edit an existing meal's serving count from 1 through 24. The
  save preserves recipe, person and ACL fields, sends a fresh bounded request
  ID, and uses the exact displayed account/plan revision as its optimistic
  concurrency base. A failed save keeps the current menu visible.
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

The real loopback Client transport writes a Turkish plan, replays the exact
request without another revision, then edits servings with
`expectedRevision: 1` and observes revision 2. The full meal-planner package
plus the focused Today action suite passes **41/41** Flutter tests. This covers
English/Turkish tablet layouts at 600/1200/1280 logical pixels and 2x text,
keyboard/semantics paths, person-bound plan models, shopping scaling,
idempotency and late lifecycle results. The Core meal-plan repository suite
passes **3/3** tests, and targeted Flutter analysis passes.

## Existing F31 foundation confirmed by audit

- Core stores account-owned meal plans and receipts encrypted, scopes them to
  exact Core/home/account/session family, enforces optimistic account/plan
  revisions, validates person revision and ACL revision, and bounds recipes,
  entries, ingredients, text and receipt storage.
- Client parsing is schema-strict and retains the Core authority tuple.
  Turkish unit/portion scaling and the standalone verified HA shopping handoff
  already have responsive, accessible UI evidence.

## Remaining F31 blockers

- A saved menu entry still opens a read-only shopping preview. The existing
  `addPlanEntry` handoff is not wired from that entry to a selected writable HA
  todo list, so the menu-to-shopping connection is not yet an end-to-end user
  journey.
- Exact-head independent review and full CI are still pending. These software
  gates prevent `F31` completion and keep both progress counters unchanged.
