# B5.1 operations tablet suite

20 September 2026. This integration slice aligns three independent operational
surfaces with the shared Larenor tablet hierarchy without changing their
underlying actions.

## Acceptance criteria

1. **Website Data:** the protected clear action stays PIN-gated, opens from the
   keyboard, and uses the shared service/settings hierarchy.
2. **Energy & Maintenance:** real energy-range and maintenance-scope controls
   remain actionable from the keyboard and expose at least 48 dp targets. A
   callback retained across route, lifecycle, account, idle, or offstage
   authority changes cannot mutate the range, disclosure, scope, or route.
3. **Home Assistant Tools:** the real API Run action executes from the keyboard,
   exposes request/result semantics, and rejects results or live events after an
   account, lifecycle, route, or exact client-authority change. Transport
   failures expose only localized safe copy in a TalkBack live region, while the
   live-subscription control is a named 60 by 48 dp keyboard toggle.

All three surfaces retain English and Turkish coverage at 600 and 1200 logical
pixels with 2x text scaling, TalkBack headers, and actual action semantics. The
combined focused run passed **44 tests**; owned source and test analysis, diff,
progress, security policy, queue validation, secret scan, patch-equivalence,
and merge-tree checks passed.

This package is one B5.1 consistency slice. It does not close the whole design
program or change queue/selected-feature counts; the accepted baseline remains
**17/125** and **0/63**.
