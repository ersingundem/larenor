# K02 safe launcher navigation and kiosk action bar

Date: 2026-09-21

This slice closes three software acceptance criteria from the K02 profile and
safe-exit scope. The durable queue item named K11 remains the separate
QR/NFC/BLE/USB/TTS/print peripheral package and is not marked complete here.

## Acceptance

1. Android publishes only two static launcher shortcuts: Home and Kiosk
   controls. The native bridge maps exact action constants to a closed Flutter
   enum; arbitrary routes, URLs, arguments and malformed actions are rejected.
   The Kiosk shortcut opens `/settings/kiosk`, which is still protected by the
   existing settings PIN gate.
2. Shortcut delivery is one-shot and foreground-owned. The bridge retains at
   most one pending user launch while paused or before the event listener is
   ready. Flutter drops background or late events, re-reads the bounded pending
   value on resume and cancels its subscription on disposal. It never retries a
   route or turns shortcut data into a command.
3. The kiosk screen exposes localized Home, Settings and Exit controls at 48dp
   or larger on 600/1280-wide tablets at 200% text. Keyboard activation and
   TalkBack semantics are covered. Exit reuses the existing observed-capability,
   explicit PIN and exact native receipt path; all actions become disabled while
   one callback is pending.

## TDD evidence

RED commit: `4af6285f`.

- `LauncherShortcutContractTest`: exact Android action allowlist and foreign
  action rejection.
- `launcher_shortcut_runtime_test.dart`: closed parsing, initial/live delivery,
  background rejection, resume ownership and disposal.
- `kiosk_quick_action_bar_test.dart`: EN/TR, 600/1280, 2x text, 48dp, keyboard
  activation and single-flight behavior.
- `settings_gate_screen_test.dart`: the launcher Kiosk destination cannot render
  the kiosk controls until the settings PIN succeeds.
- Existing `kiosk_screen_test.dart` continues to prove observed capability,
  PIN-protected exit, late callback invalidation and truthful receipts.

## Honest remaining boundaries

OEM launcher rendering and shortcut invocation, Android Home-role selection,
managed DPC lock-task behavior, Huawei process policy and Samsung DeX hardware
remain physical/manual acceptance gates. This slice neither claims device-owner
status nor changes the queue or feature progress counters.
