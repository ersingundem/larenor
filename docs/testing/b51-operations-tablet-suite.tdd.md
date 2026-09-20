# B5.1 operations tablet suite

20 September 2026. This integration slice aligns three independent operational
surfaces with the shared Larenor tablet hierarchy without changing their
underlying actions.

## Acceptance criteria

1. **Website Data:** the protected clear action stays PIN-gated, opens from the
   keyboard, and uses the shared service/settings hierarchy.
2. **Energy & Maintenance:** real energy-range and maintenance-scope controls
   remain actionable from the keyboard and expose at least 48 dp targets.
3. **Home Assistant Tools:** the real API Run action executes from the keyboard,
   exposes request/result semantics, and keeps the shared service hierarchy.

All three surfaces retain English and Turkish coverage at 600 and 1200 logical
pixels with 2x text scaling, TalkBack headers, and actual action semantics. The
combined focused run passed **35 tests**; owned source and test analysis, diff,
progress, patch-equivalence, and merge-tree checks passed.

This package is one B5.1 consistency slice. It does not close the whole design
program or change queue/selected-feature counts; the accepted baseline remains
**16/125** and **0/63**.
