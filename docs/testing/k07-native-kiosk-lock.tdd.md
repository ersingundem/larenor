# K07 native kiosk lock boundary

## Scope

This slice adds one native command to the existing paired MQTT runtime: `lockKiosk`. The MQTT authority still requires the `admin` scope before the command executor is reached. The Android MethodChannel accepts only the current 32-character session ID and the exact `lockKiosk` kind; it carries no token, URL, package name, or arbitrary arguments.

The command remains unavailable by default because the managed tablet source is opt-in. A backgrounded, replaced, stopped, or retired source invalidates the native session. Late native replies resolve as denied and are never replayed.

## Native policy

Android starts lock task only while Larenor is resumed and focused on the primary display, outside multi-window, picture-in-picture, and desktop mode, with an unlocked keyguard and `DevicePolicyManager.isLockTaskPermitted(packageName) == true`. This prevents Android's user-removable screen-pinning fallback. An already managed lock is idempotently reported as succeeded; a pinned or ineligible state is denied. Runtime uncertainty is reported as failed.

No enrollment, allowlist mutation, device-owner grant, reboot, reset, wipe, or lock-task exit is exposed by this remote command.

## TDD evidence

- RED `762cb901`: Flutter proved the previous executor returned unsupported and Android tests required an exact, session-bound command.
- GREEN `04f3b97b`: Flutter source tests pass 11/11; Android `ManagedTabletSourceBridgeTest` passes.
- Focused Dart analysis, queue validation, per-commit progress, and diff checks are required before merge.

The full paired API/runtime/profile chain is now accepted and K07 is `done`.
Physical managed-device acceptance remains MANUAL.
