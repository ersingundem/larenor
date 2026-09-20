# F31 menu and shopping foundation acceptance

This acceptance package now combines the original Today/Home Assistant slice
with an encrypted Core weekly-menu contract and a real isolated-HTTP Client
contract test. Queue progress stays at 17/125 and selected-feature progress at
0/63 until the pull request has required review and full CI evidence; it makes
no physical Home Assistant or tablet claim.

Exactly three user acceptance criteria are in scope:

1. A user can enter 1–32 ingredients with explicit `g`, `kg`, `ml`, `l`, or piece units, scale a recipe between 1–24 servings, and see locale-correct EN/TR shopping summaries. Ambiguous, oversized, control-character, unsupported-unit, and zero input is rejected before any write.
2. Each shopping item is sent once through the existing verified Today action and readback contract. The handoff binds the exact Core, home, account, session family, endpoint, runtime identity, and interaction epoch; account/home/session/route/background changes stop remaining writes and no late success is shown.
3. The Today shopping card exposes a 48dp recipe action. Its tablet sheet supports EN/TR at 600/1200 widths with 2x text, scroll-safe Cupertino layout, keyboard Enter activation, TalkBack labels, and live progress/result announcements.

The follow-up closes three previously missing software gates:

1. Core persists one versioned weekly menu per account with bounded recipes,
   `g`/`kg`/`ml`/`l`/piece units, Turkish text, servings, exact person
   revision/ACL authority, encrypted records and restart/tamper validation.
2. A weekly entry converts directly to a scaled shopping draft. Its entry ID
   derives stable per-item markers, so an accepted retry verifies the existing
   Home Assistant item and sends no duplicate; conflicting markers fail closed.
3. The Client validates the exact Core/home/account/session-family and plan
   revisions across a real loopback HTTP request. Account, route or lifecycle
   invalidation rejects a late result, and malformed, oversized, stale or
   replay-conflicting data cannot be published.

## TDD evidence

The RED phase failed on missing weekly-menu routes and on the absent Client
contract. The GREEN matrix covers Server persistence/restart/ACL/tamper cases,
Client loopback HTTP and late-result rejection, bounded parsing/scaling, stable
shopping replay markers, every existing handoff authority dimension, and the
existing EN/TR 600/1200 at 2x tablet accessibility suite.
