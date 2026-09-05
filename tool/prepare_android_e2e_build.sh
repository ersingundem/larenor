#!/usr/bin/env bash
set -euo pipefail

# Host-only warm build, before QEMU starts: resolve/compile Android plugins and
# native dependencies without competing with the launcher's boot workload.
# This APK is not installed or published. flutter test still rebuilds its own
# generated harness and performs every real device assertion afterward.
# shellcheck source=tool/android_e2e_gradle.sh
source "$(dirname "${BASH_SOURCE[0]}")/android_e2e_gradle.sh"
mkdir -p build/e2e
dart run build_runner build 2>&1 | tee build/e2e/android-precompile.log
flutter build apk --debug --no-pub --target-platform android-x64 \
  --target integration_test/platform_storage_test.dart \
  --dart-define=LARENOR_E2E=true 2>&1 | tee -a build/e2e/android-precompile.log
