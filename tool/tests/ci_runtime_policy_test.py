"""Exercise hosted-runner setup gates using shell stubs, never host devices."""

import os
from pathlib import Path
import re
import shlex
import subprocess
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = (ROOT / ".github/workflows/android-e2e.yml").read_text()
KVM_SCRIPT = textwrap.dedent(WORKFLOW.split(
    "      - name: Enable hardware acceleration\n        run: |\n", 1,
)[1].split("\n      # Reviewed", 1)[0])

# Override every device test and privileged command in the extracted script.
# A stray command or different target fails; this never changes /dev or udev.
HARNESS = r'''
function [ {
  case "$*" in
    '! -c /dev/kvm ]') builtin test "$KVM_TEST_MODE" = absent ;;
    '! -r /dev/kvm ]'|'! -w /dev/kvm ]') builtin test "$kvm_ready" != yes ;;
    *) echo 'Unexpected device test' >&2; exit 97 ;;
  esac
}
sudo() {
  builtin test "$*" = 'chmod 0666 /dev/kvm' || exit 98
  echo 'synthetic permission change'
  builtin test "$KVM_TEST_MODE" != denied || return 23
  builtin test "$KVM_TEST_MODE" != inaccessible && kvm_ready=yes
  return 0
}
ls() { echo 'synthetic device diagnostics'; }
kvm_ready=no
'''


class HostedRuntimePolicyTest(unittest.TestCase):
    def emulator_input(self, name):
        step = WORKFLOW.split("      - name: Run actual app journeys on API 35\n", 1)[1]
        step = step.split("\n      - name:", 1)[0]
        values = re.findall(r"^          " + re.escape(name) + r":\s*(.+)$", step, re.MULTILINE)
        self.assertEqual(len(values), 1, f"Expected one explicit emulator {name} input")
        return values[0]

    def test_gles_lane_excludes_the_reproduced_emulator_host_crash(self):
        # 5deb1e6's real API 35 run lost the whole 37.1.11 SwANGLE host,
        # after all native checks passed. Keep the independently reproduced
        # working binary/profile pair; floating SDK updates reintroduce it.
        # https://github.com/bdero/flutter_scene/issues/314
        with self.subTest("binary"):
            self.assertEqual(self.emulator_input("emulator-build"), "13823996")
        with self.subTest("renderer"):
            options = shlex.split(self.emulator_input("emulator-options"))
            self.assertEqual(options.count("-gpu"), 1)
            self.assertEqual(options[options.index("-gpu") + 1], "swangle_indirect")

    def test_renderer_workaround_preserves_the_actual_device_and_failure_gates(self):
        self.assertEqual(self.emulator_input("api-level"), "35")
        self.assertEqual(self.emulator_input("arch"), "x86_64")
        self.assertEqual(self.emulator_input("target"), "default")
        self.assertEqual(self.emulator_input("disable-linux-hw-accel"), "false")
        self.assertEqual(self.emulator_input("script"), "timeout 18m bash tool/run_android_e2e.sh emulator-5554")
        runner = (ROOT / "tool/run_android_e2e.sh").read_text()
        self.assertIn("flutter test integration_test", runner)
        self.assertNotIn("--no-enable-impeller", runner)
        self.assertNotIn("--enable-software-rendering", runner)
        self.assertIn('exit "${e2e_pipeline_status[0]}"', runner)

    def run_kvm(self, mode):
        return subprocess.run(
            ["bash", "-e", "-o", "pipefail", "-c", HARNESS + KVM_SCRIPT],
            env=dict(os.environ, KVM_TEST_MODE=mode), text=True,
            capture_output=True, check=False,
        )

    def test_accessible_device_allows_the_emulator_gate_to_continue(self):
        result = self.run_kvm("ready")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("synthetic permission change", result.stdout)

    def test_absent_device_fails_without_a_permission_change(self):
        result = self.run_kvm("absent")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no KVM character device", result.stdout)
        self.assertNotIn("synthetic permission change", result.stdout)

    def test_permission_command_failure_is_not_suppressed(self):
        self.assertEqual(self.run_kvm("denied").returncode, 23)

    def test_remaining_access_failure_is_diagnostic_and_blocking(self):
        result = self.run_kvm("inaccessible")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cannot access KVM", result.stdout)
        self.assertIn("synthetic device diagnostics", result.stdout)


if __name__ == "__main__":
    unittest.main()
