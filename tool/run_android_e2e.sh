#!/usr/bin/env bash
set -euo pipefail

# Never select the first attached device: this target owns synthetic app state.
# Require the caller's explicit disposable emulator and its QEMU proof.
e2e_serial="${1:-}"
if [[ ! "$e2e_serial" =~ ^emulator-[0-9]+$ ]] ||
   [[ "$(adb -s "$e2e_serial" shell getprop ro.kernel.qemu | tr -d '\r')" != "1" ]]; then
  echo "E2E requires an explicit disposable Android emulator serial." >&2
  exit 2
fi
mkdir -p build/e2e
# Generated Freezed/Riverpod parts are deliberately not committed. A fresh CI
# checkout must build them before compiling the integration-test entry point.
dart run build_runner build 2>&1 | tee build/e2e/android-e2e.log
adb -s "$e2e_serial" shell settings put global window_animation_scale 0
adb -s "$e2e_serial" shell settings put global transition_animation_scale 0
adb -s "$e2e_serial" shell settings put global animator_duration_scale 0
adb -s "$e2e_serial" shell settings put secure show_ime_with_hard_keyboard 0
# Do not collect global logcat, app storage, vault files, or native health data.
# Only this synthetic test runner's output is retained by CI.
flutter test integration_test \
  -d "$e2e_serial" --dart-define=LARENOR_E2E=true \
  --reporter expanded --timeout 180s 2>&1 | tee -a build/e2e/android-e2e.log
