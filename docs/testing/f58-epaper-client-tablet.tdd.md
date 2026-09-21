# F58 e-paper tablet management acceptance

This package adds an Android tablet and DeX management surface over the F58
Core boundary. Queue progress remains 20/125 and selected-feature progress
remains 0/63. A concrete authenticated HTTP adapter, durable Core storage,
bridge firmware, device rotation support, and physical e-paper acceptance stay
open gates.

Exactly three user acceptance criteria are in scope:

1. The screen presents stored registration, current reachability, and snapshot
   trust as separate text-and-icon evidence. Every response is bound to the
   exact Core, home, account, session-family, device, bridge, layout, data, and
   policy revisions; malformed, foreign, late, hidden, or retired results clear
   trusted state.
2. Refresh and rotate first obtain a bounded Core preview and require an
   explicit user confirmation. Success appears only after an exact receipt and
   a fresh verified readback; expiry, lost responses, revision drift, and
   uncertain results fail closed and are never replayed automatically.
3. English and Turkish layouts work at 600 and 1280 logical pixels with 200%
   text, 48 dp actions, text labels alongside status icons, keyboard Enter or
   Space activation, TalkBack button/header/state semantics, and live status
   announcements.

## TDD evidence

The RED commit `ed4b0dd2` failed because the F58 Client models, API boundary,
controller, and screen did not exist. The GREEN matrix contains one authority
and stale-callback test, one preview-confirm-readback test, and one parameterized
EN/TR tablet accessibility test across both target widths at 200% text.
