# F31 planned meal shopping handoff acceptance

This slice connects the weekly-menu tablet preview to the existing verified
Home Assistant todo write/readback contract. It does not close F31: recipe and
menu editing, physical Home Assistant/tablet acceptance, and full CI evidence
remain open. Official progress stays at **22/125 (17.6%)** and **0/63**.

Exactly three user acceptance criteria are in scope:

1. A planned meal can be added only when the current Today snapshot exposes a
   non-retained, readable and writable `todo.shopping_list` or `todo.shopping`
   entity and the current Home/Core authority can be captured.
2. The selected entry scales its structured ingredients to its planned
   servings and sends each item through the verified Today readback action with
   stable per-entry idempotency keys. The sheet announces the exact verified
   count and list name only after all accepted writes are confirmed.
3. Home, account, session, writable-list, route, modal or lifecycle retirement
   invalidates the operation. Remaining items are not sent and a late
   completion cannot publish success; EN/TR 600/1280 at 2x stays scroll-safe
   with 48dp add and close actions.

## TDD evidence

Focused tests cover the concrete gateway's mid-handoff list revocation, exact
authority and idempotency behavior, serving-scaled summaries, a successful
tablet action and a backgrounded late completion. The combined meal-plan,
real-loopback Core, handoff, and protected-account regression matrix passes 25
tests, and targeted Flutter analysis reports no issues.
