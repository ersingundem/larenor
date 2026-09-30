# K11 production input retirement — 2026-09-30

K11's production Android bridge is registered in `MainActivity` for foreground
NFC intents, external keyboard events, BLE permission results, activity
lifecycle, window focus and engine disposal. QR uses a separate visible camera
route. Every accepted input remains a bounded `reviewOnly` envelope; none of
these paths execute a command, open a URI, inject JavaScript, connect to a BLE
device, speak, or print.

The missing production boundary was route retirement. Flutter discarded a late
result after a route/account/interaction change, but an armed native NFC, BLE or
HID request could remain active until its 15-second timeout. Window focus loss
also left an outstanding BLE permission request alive. The Client now sends an
idempotent native `retire` message whenever the route, interaction, lifecycle
or widget authority is retired. The Android bridge immediately disables NFC
foreground dispatch, stops BLE scanning, clears buffered HID data, and retires
an outstanding permission result. Flutter clears the matching authority before
waiting for that acknowledgement, so a transport failure cannot revive it.

Focused software gates:

```sh
flutter test test/features/kiosk/kiosk_peripheral_contract_test.dart test/features/kiosk/kiosk_peripheral_screen_test.dart test/features/kiosk/kiosk_hid_scan_session_test.dart
./android/gradlew -p android :app:testDebugUnitTest --tests 'com.ersingundem.larenor.kiosk.KioskPeripheralBridgeTest' --tests 'com.ersingundem.larenor.kiosk.KioskPeripheralContractTest'
```

These tests exercise production channel framing, capability/replay gates,
explicit arm/review behavior, route retirement and idempotent native cleanup.
They do not claim physical QR focus/decoding, NFC antenna behavior, BLE radio
advertisements or permission UI, USB/Bluetooth keyboard routing or unplug,
GMS-free hardware behavior, TTS output, or printer output. Those remain manual
device gates.

Root verification: 19 focused Flutter tests passed with zero skips; both Android
XML reports were archived before another native run: 2 bridge + 4 contract tests,
zero skips/failures/errors. Scoped analysis is clean.

A missing or timed-out native retirement acknowledgement leaves a sticky uncertain
fence: subsequent capability/input/permission I/O remains blocked, even if the old
reply arrives later. Only a new explicit retirement with an acknowledged result
clears that fence. A retirement epoch guards both sides of each async boundary;
a late capabilities response cannot re-arm a retired route or clear its successor.
The regression holds an old response across acknowledged retirement and a fresh
snapshot, then proves only the successor authority can arm input.
