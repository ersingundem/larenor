# K10 critical sensor power guard TDD evidence

This slice keeps foreground-only kiosk sampling bounded when Android reports a
critical device power state. It adds no automation or background authority and
does not close K10 or change the progress counters.

## Three accepted behaviors

1. Dart and Android accept only a canonical 36-character UUID-shaped session
   identifier. The Android channel rejects malformed session identifiers and
   intervals outside 1000..10000 milliseconds before native I/O.
2. One sensor session owns at most one native read at a time. A second read is
   rejected as busy, and a completed newer sequence cannot be replaced by a
   later older observation.
3. Battery at 3 percent or lower, or Android thermal state `critical`,
   `emergency`, or `shutdown`, stops the exact native session once before the
   client publishes another sample. EN/TR tablet UI explains the power guard;
   retirement cannot replay a second stop.

## RED

Commit `32fb5551274c471fedf24d7827abc037e5c0198f` added channel-boundary,
single-read, exact-stop, critical battery/thermal, and localized tablet
expectations. The old controller accepted parallel reads and had no
`powerLimited` result.

## GREEN

Commit `40cae4edd538ff59fe4bef3cd2a2b3d7da44634a` added the bounded channel
contract, serialized reads, exact power-limited retirement, canonical session
shape, and localized result.

```text
flutter gen-l10n
flutter test test/features/kiosk/kiosk_sensor_models_test.dart test/features/kiosk/kiosk_sensor_screen_test.dart
# 23 passed
flutter analyze lib/features/kiosk/domain/kiosk_sensor_models.dart lib/features/kiosk/data/kiosk_sensor_api.dart lib/features/kiosk/data/kiosk_sensor_controller.dart lib/features/kiosk/presentation/kiosk_sensor_screen.dart test/features/kiosk/kiosk_sensor_models_test.dart test/features/kiosk/kiosk_sensor_screen_test.dart
# No issues found
./gradlew -p android :app:testDebugUnitTest --tests com.ersingundem.larenor.kiosk.KioskSensorPolicyTest
# BUILD SUCCESSFUL; 7 focused tests passed
```

K10 stays pending until its physical 24-hour battery, thermal and OEM sensor
matrix is recorded. Progress remains 26/125 and 0/63.
