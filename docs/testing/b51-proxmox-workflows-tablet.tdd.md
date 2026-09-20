# B5.1 Proxmox workflow tablet acceptance

This slice aligns three related Proxmox workflows with Larenor's shared tablet
surface. It changes presentation only; the existing account, lifecycle,
mutation and polling authority remains the source of truth.

## Three acceptance criteria

1. **Node workflow:** refresh, create-from-template, task history and backup
   storage navigation use named native buttons with at least 48 dp targets.
   The page uses the same adaptive surface and grouped hierarchy as the service
   root while retained callbacks continue to reject a changed account or route.
2. **Guest workflow:** the configuration form keeps its digest-bound update
   behavior and unknown-result state. Console and save are explicit named
   actions on the shared surface, remain disabled outside the current session,
   and expose at least 48 dp targets.
3. **Task workflow:** refresh and task-log navigation retain the existing
   foreground polling and source-session guards on the shared surface. Status
   uses text and icon shape in addition to color.

## TDD evidence

RED commit `02ee437f` added the EN/TR matrix at 600 and 1200 logical pixels
with 200% text. All eight node and guest cases failed because the routes did
not use `AppSurface` or expose the required named actions; the four task cases
passed and became the preservation baseline.

GREEN runs the 12-case matrix together with the existing guest mutation,
session retirement, task lifecycle, overview and node tablet suites. The
combined focused run passes **44 tests** and targeted static analysis reports
no issues. Physical Huawei MatePad, Samsung DeX, keyboard and TalkBack checks
remain in their manual acceptance tasks, so this slice does not close B5.1 or
change either progress counter.
