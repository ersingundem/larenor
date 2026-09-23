# K10 power and thermal snapshot

This slice extends the foreground-only kiosk sensor session with a bounded
battery percentage and Android's closed thermal-status classification. It does
not collect temperature, battery identity, device identity, or a persistent
history.

## Contract

- Snapshot schema v3 has an exact 15-key allowlist. Battery is either `null` or
  an integer in `0..100`; thermal status is one of Android's eight closed states
  plus `unknown`.
- A battery, thermal, camera, or sensor-availability change advances the native
  sequence and monotonic observation time. The client rejects field drift under
  the same sequence.
- Values are read only while the visible, focused kiosk sensor session is
  active. Existing background, route-cover, focus-loss, and provider-replacement
  retirement rules remain authoritative.
- The tablet surface names unavailable values and exposes localized EN/TR power
  and thermal rows at 600 and 1280 logical pixels with 200% text.

## Automated evidence

- Android policy and host boundary: `KioskSensorPolicyTest` — 6/6.
- Flutter parser, ordering, lifecycle, and tablet UI: focused package — 16/16.
- `flutter analyze` and execution-queue/progress checks are required on the
  exact pull-request head.

## Remaining K10 gate

K10 stays pending. Its acceptance still requires a physical 24-hour
battery/thermal measurement on representative Android tablet hardware and the
recorded result must show that no sample is taken after permission, focus, or
foreground authority is lost.
