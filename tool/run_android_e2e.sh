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
# The hosted emulator shares memory with Gradle. The repository's developer
# defaults permit an 8 GiB heap plus 4 GiB metaspace; keep the disposable CI
# build bounded without changing a developer's Gradle configuration.
# User-home properties override project properties:
# https://docs.gradle.org/current/userguide/build_environment.html
if [[ "${GITHUB_ACTIONS:-false}" == "true" ]]; then
  e2e_gradle_home="${RUNNER_TEMP:?CI requires RUNNER_TEMP}/larenor-e2e-gradle"
  mkdir -p "$e2e_gradle_home"
  cat > "$e2e_gradle_home/gradle.properties" <<'PROPERTIES'
org.gradle.jvmargs=-Xmx3G -XX:MaxMetaspaceSize=1G -XX:ReservedCodeCacheSize=256m -Dfile.encoding=UTF-8
org.gradle.workers.max=2
org.gradle.parallel=false
kotlin.compiler.execution.strategy=in-process
PROPERTIES
  export GRADLE_USER_HOME="$e2e_gradle_home"
fi

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
# Only this synthetic test runner's output is retained by CI.
flutter test integration_test \
  -d "$e2e_serial" --dart-define=LARENOR_E2E=true \
  --reporter expanded --timeout 180s 2>&1 | tee -a build/e2e/android-e2e.log
