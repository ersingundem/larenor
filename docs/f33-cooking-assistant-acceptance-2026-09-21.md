# F33 cooking assistant acceptance slice

This slice keeps F33 pending. It supplies three independently reviewable
software foundations without claiming the later F31/F32 wiring, ingredient
decrement, multiple timer presentation, Core HTTP route, or physical tablet
acceptance.

## Accepted criteria

1. **Account-owned durable step session.** `CookingSessionStore` snapshots the
   exact recipe revision and ordered steps. Optimistic revisions reject stale
   movement, another account receives no existence signal, and a reopened
   SQLite store restores the same step and revision.
2. **Large tablet step surface.** The injected EN/TR label bundles, 600 and
   1200 logical-pixel layouts at 2x text, 48dp controls, arrow-key navigation,
   and explicit TalkBack labels are covered by widget tests. No feature-local
   locale guess or second slogan is introduced.
3. **Current authority only.** The controller binds every move and timer to its
   current lifecycle epoch. Account/session authority loss discards late
   replies, retirement cancels timers, and no command is retried automatically.

## TDD evidence

- RED: `2b3c1919` compiled the new tests before their production modules
  existed; Flutter failed on the missing cooking domain/controller/screen and
  Python failed on the missing `larenor_server.cooking` package.
- GREEN: `uv run --project server pytest
  server/tests/test_f33_cooking_session.py` passes 3 tests.
- GREEN: `flutter test test/features/cooking_assistant` passes 6 tests.
- Static analysis is limited to the new cooking feature and its tests and
  reports zero findings.

## Deliberately open

F33 stays pending at 17/125 and 0/63. Production Core route wiring overlaps
the active F31/F54 Core files and is not part of this isolated slice. Recipe
selection, ingredient stock mutation, multiple visible timers, application
navigation, isolated Client-to-Core E2E, CI, and Huawei/DeX device evidence
remain required before F33 can close.
