#!/usr/bin/env bash
set -euo pipefail

# Never select the first attached device: this target owns synthetic app state.
# Require the caller's explicit disposable emulator and its QEMU proof.
e2e_serial="${1:-}"
if [[ ! "$e2e_serial" =~ ^emulator-[0-9]+$ ]]; then
  echo "E2E requires an explicit disposable Android emulator serial." >&2
  exit 2
fi
# The helper proves QEMU before touching power, then reapplies/reads at most
# five times within one 10-second deadline. Only exact 7 or 15 may begin the build.
# This tolerates transient preparation failures without diagnosing their cause.
# svc stayon also wakes the display; no app focus flag or keyguard is changed.
# https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/cmds/svc/src/com/android/commands/svc/PowerCommand.java
python3 "$(dirname "${BASH_SOURCE[0]}")/android_e2e_preparation.py" "$e2e_serial" || exit 2
mkdir -p build/e2e
# Reuse the warm build's bounded Gradle daemon/cache. Standalone local runs
# retain their developer configuration and still generate/build everything.
# shellcheck source=tool/android_e2e_gradle.sh
source "$(dirname "${BASH_SOURCE[0]}")/android_e2e_gradle.sh"

# Invoked indirectly by the EXIT trap; exercised by failure-status regressions.
# shellcheck disable=SC2329
e2e_finish() {
  local status=$?
  if [[ "$status" != 0 && "${GITHUB_ACTIONS:-false}" == "true" ]]; then
    # Host infrastructure only, before the action removes the emulator. Process
    # names and RSS omit arguments; no global logcat or app data is collected.
    {
      echo 'CI emulator infrastructure at failure:'
      free -m || true
      ps -eo comm,rss --sort=-rss | head -12 || true
      timeout 5s adb -s "$e2e_serial" get-state || true
      sudo -n dmesg --ctime 2>/dev/null |
        awk '/[Oo]ut of memory|[Kk]illed process|oom-kill|segfault/ {lines[++count]=$0} END {start=count>20?count-19:1; for (i=start;i<=count;i++) print lines[i]}' || true
    } 2>&1 | tee -a build/e2e/android-e2e.log || true
  fi
  return "$status"
}
trap e2e_finish EXIT

# Generated Freezed/Riverpod parts are deliberately not committed. A fresh CI
# checkout must build them before compiling the integration-test entry point.
dart run build_runner build 2>&1 | tee build/e2e/android-e2e.log
adb -s "$e2e_serial" shell settings put global window_animation_scale 0
adb -s "$e2e_serial" shell settings put global transition_animation_scale 0
adb -s "$e2e_serial" shell settings put global animator_duration_scale 0
adb -s "$e2e_serial" shell settings put secure show_ime_with_hard_keyboard 0
# Do not collect global logcat, app storage, vault files, or native health data.
# CI retains synthetic runner output and one filtered native focus snapshot.
set +e
flutter test integration_test \
  -d "$e2e_serial" --dart-define=LARENOR_E2E=true \
  --reporter expanded --timeout 180s 2>&1 |
  python3 "$(dirname "${BASH_SOURCE[0]}")/android_e2e_diagnostics.py" "$e2e_serial" |
  tee -a build/e2e/android-e2e.log
e2e_pipeline_status=("${PIPESTATUS[@]}")
set -e
# pipefail alone selects the rightmost failure, which could hide Flutter's
# actual error behind a relay/tee error. A successful Flutter run still fails
# when its evidence pipeline fails; diagnostics must never make it green.
if [[ "${e2e_pipeline_status[0]}" != 0 ]]; then
  exit "${e2e_pipeline_status[0]}"
fi
if [[ "${e2e_pipeline_status[1]}" != 0 ]]; then
  exit "${e2e_pipeline_status[1]}"
fi
exit "${e2e_pipeline_status[2]}"
