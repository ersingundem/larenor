# K11.remaining — tablet HID scan session

This slice is a memory-only tablet reader for keyboard-emulating USB/Bluetooth
scanners. It does not claim physical hardware acceptance or close K11; K08
native bridge and peripheral capability evidence remain separate.

## Acceptance

1. Scanning starts only after an explicit user action. A bounded printable ASCII
   code is captured locally, redacted until a separate review action, and never
   used as a URL, JavaScript message, command, or backend request.
2. Duplicate input, malformed/pasted/control input, length overflow, inactivity,
   app background, focus loss, route loss, and interaction epoch change discard
   pending or revealed data. Restarting scanning creates a fresh session.
3. The Kiosk surface exposes the reader in EN/TR at 600/1280 logical pixels and
   2x text. Start, stop, and review are at least 48dp; status is a live region;
   Enter finishes and Escape cancels keyboard capture.

## TDD evidence

- Domain RED: missing `KioskHidScanSession` before implementation.
- Domain GREEN: `flutter test test/features/kiosk/kiosk_hid_scan_session_test.dart`.
- Widget matrix: `flutter test test/features/kiosk/kiosk_hid_scan_screen_test.dart`.

Manual gate: actual USB/Bluetooth scanner, Android keyboard routing, unplug and
GMS-free tablet testing must be performed on hardware. This slice does not
increment execution queue completion counters.
