# F33 durable cooking timers acceptance slice

This independent F33 slice leaves the feature pending. It does not modify F32
stock data or depend on the first cooking-step PR.

## Accepted criteria

1. **Multiple durable monotonic timers.** Up to eight account and recipe-session
   scoped timers persist an exact wall deadline and optimistic revision.
   Runtime countdown uses elapsed monotonic time, so a wall-clock edit cannot
   lengthen or shorten active timers; a fresh controller restores deadlines
   after process restart or app return.
2. **One tablet authority through window changes.** The 600/1200 logical-pixel
   grid at 2x text reflows without restoring or cloning controller authority.
   English and Turkish copy, a 48dp acknowledgement action, and its semantic
   label remain present across repeated window changes.
3. **Idempotent completion boundary.** Completion uses a stable, account and
   recipe-session scoped notification key. The delivery adapter must durably
   deduplicate that key; the retained record is then marked notified with exact
   revision CAS. Acknowledgement is idempotent. Lost lifecycle/account
   authority blocks notification, persistence, and acknowledgement.

## TDD evidence

- RED `0b0a262f`: the timer model, controller, and tablet screen did not exist.
- RED `8bbce6bf`: the concrete restart store did not exist.
- GREEN `6b5e6441`: `flutter test test/features/cooking_assistant/cooking_timers_controller_test.dart
  test/features/cooking_assistant/cooking_timers_screen_test.dart` passes 6 tests.
- Focused analysis reports zero findings; queue, progress, security, diff and
  redacted secret checks are required before publication.

F33 remains pending at 18/125 and 0/63. Core HTTP ownership, step/timer route
wiring, F31/F32 ingredient effects, background Android alarm delivery, full CI,
and physical Huawei/DeX evidence remain separate acceptance gates.
