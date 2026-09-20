# F31 menu and shopping foundation acceptance

This independent slice reuses the existing Today/Home Assistant action receipt and readback path. It does not claim the full weekly menu, recipe persistence, import, or isolated Core E2E required to close F31. Queue progress therefore stays at 17/125 and selected-feature progress at 0/63.

Exactly three user acceptance criteria are in scope:

1. A user can enter 1–32 ingredients with explicit `g`, `kg`, `ml`, `l`, or piece units, scale a recipe between 1–24 servings, and see locale-correct EN/TR shopping summaries. Ambiguous, oversized, control-character, unsupported-unit, and zero input is rejected before any write.
2. Each shopping item is sent once through the existing verified Today action and readback contract. The handoff binds the exact Core, home, account, session family, endpoint, runtime identity, and interaction epoch; account/home/session/route/background changes stop remaining writes and no late success is shown.
3. The Today shopping card exposes a 48dp recipe action. Its tablet sheet supports EN/TR at 600/1200 widths with 2x text, scroll-safe Cupertino layout, keyboard Enter activation, TalkBack labels, and live progress/result announcements.

## TDD evidence

The RED phase failed on missing domain, authority, handoff, and tablet UI types before implementation. The GREEN matrix covers bounded parsing/scaling, every authority dimension, once-only verified writes, stale/hidden fail-closed behavior, EN/TR 600/1200 at 2x, 48dp targets, keyboard activation, live-region result, route launch, and late background completion.
