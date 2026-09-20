# S08.10 Client event checkpoint TDD evidence

20 September 2026. This slice closes the software-only event cursor trust
criteria. It does not close S08.10 or change either progress counter.

## Acceptance boundary

- The retained cursor is encrypted by platform secure storage and bound to the
  exact Core, home, resource, actor and role view.
- A verified forward read atomically advances the retained chain head. A gap,
  rollback, concurrent replacement or malformed record fails closed.
- A chain change requires a failed comparison followed by an explicit
  `Refresh and verify` action. It is never accepted by an automatic first read.
- A failed refresh immediately removes current trust from the screen while the
  retained cursor remains available for a later comparison.
- Account, home, role, endpoint, lifecycle or operation epoch retirement stops
  a late response before it can update storage or visible trust.

## RED

The RED commit introduced failing tests for secure checkpoint persistence,
restart continuation, failed-refresh invalidation and retired-session writes.
The test target failed because the event checkpoint store and controller
binding did not exist.

## GREEN

The GREEN commit added the bounded store and connected it to the route-owned
activity controller. Verification completed with:

```text
flutter test \
  test/features/core_ha/core_ha_activity_ui_test.dart \
  test/features/core_ha/core_ha_activity_api_test.dart \
  test/features/core_ha/core_ha_activity_models_test.dart \
  test/features/core_ha/core_ha_checkpoint_store_test.dart \
  test/features/core_ha/core_ha_event_checkpoint_store_test.dart \
  test/integration_support/synthetic_core_history_checkpoint_test.dart

37 tests passed
```

Targeted `flutter analyze` reported no issues. The existing EN/TR, 600/1280,
2x text, keyboard and semantics matrix remained green. No direct Home
Assistant request or write path was added.

## Remaining S08.10 work

Persistent transfer receipts and unified command/transfer history, media
specific protocols, physical Android SAF, Huawei tablet, DeX and real LAN
acceptance remain open. Queue progress stays 15/125 and selected-feature
progress stays 0/63 until the whole acceptance item closes.
