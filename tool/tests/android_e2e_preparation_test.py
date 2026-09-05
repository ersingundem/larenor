"""Exercise clean-checkout preparation and failure gates without an Android device."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "run_android_e2e.sh"


class AndroidE2EPreparationTest(unittest.TestCase):
    def run_script(self, *, generation_fails=False, journey_fails=False, diagnostics_fail=False, ci=False, serial="emulator-5554"):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            binaries = root / "bin"
            binaries.mkdir()
            commands = {
                "adb": '#!/bin/bash\necho "adb $*" >> "$COMMAND_TRACE"\n'
                       'if [[ "$*" == *"getprop ro.kernel.qemu" ]]; then echo 1; fi\n',
                "dart": '#!/bin/bash\necho "dart $*" >> "$COMMAND_TRACE"\n'
                        'echo "synthetic source generation"\n'
                        'if [[ "$FAIL_GENERATION" == 1 ]]; then exit 17; fi\n'
                        'touch generated-synthetic-model\n',
                "flutter": '#!/bin/bash\necho "flutter $*" >> "$COMMAND_TRACE"\n'
                           'test -f generated-synthetic-model || exit 31\n'
                           'if [[ "$GITHUB_ACTIONS" == true && "${GRADLE_USER_HOME:-}" != "$RUNNER_TEMP/larenor-e2e-gradle" ]]; then exit 41; fi\n'
                           'if [[ "$FAIL_JOURNEY" == 1 ]]; then exit 23; fi\n'
                           'echo "synthetic journey success"\n',
                "free": '#!/bin/bash\n[[ "$FAIL_DIAGNOSTICS" == 1 ]] && exit 7\necho "synthetic host memory"\n',
                "ps": '#!/bin/bash\n[[ "$FAIL_DIAGNOSTICS" == 1 ]] && exit 7\necho "qemu-system-x86 2097152"\n',
                "sudo": '#!/bin/bash\n[[ "$FAIL_DIAGNOSTICS" == 1 ]] && exit 7\necho "kernel: Out of memory: Killed process 123 (qemu-system-x)"\n',
                "timeout": '#!/bin/bash\nshift\nexec "$@"\n',
            }
            for name, content in commands.items():
                file = binaries / name
                file.write_text(content)
                file.chmod(0o755)
            trace = root / "commands.log"
            result = subprocess.run(["bash", str(SCRIPT), serial], cwd=root,
                                    env={**os.environ, "PATH": f"{binaries}:/usr/bin:/bin",
                                         "COMMAND_TRACE": str(trace),
                                         "GITHUB_ACTIONS": "true" if ci else "false",
                                         "RUNNER_TEMP": str(root / "runner-temp"),
                                         "FAIL_JOURNEY": "1" if journey_fails else "0",
                                         "FAIL_DIAGNOSTICS": "1" if diagnostics_fail else "0",
                                         "FAIL_GENERATION": "1" if generation_fails else "0"},
                                    capture_output=True, text=True, check=False)
            output = trace.read_text() if trace.exists() else ""
            log = root / "build/e2e/android-e2e.log"
            properties = root / "runner-temp/larenor-e2e-gradle/gradle.properties"
            result.gradle_properties = properties.read_text() if properties.exists() else None
            return result, output, log.read_text() if log.exists() else ""

    def test_clean_checkout_generates_models_before_journeys(self):
        result, commands, log = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLess(commands.index("dart run build_runner build"), commands.index("flutter test integration_test"))
        self.assertIn("synthetic source generation", log)
        self.assertIn("synthetic journey success", log)

    def test_generation_failure_is_blocking_and_preserved_in_evidence(self):
        result, commands, log = self.run_script(generation_fails=True)
        self.assertEqual(result.returncode, 17)
        self.assertNotIn("flutter test", commands)
        self.assertNotIn("settings put", commands)
        self.assertIn("synthetic source generation", log)

    def test_invalid_device_is_rejected_before_build_or_device_access(self):
        result, commands, _ = self.run_script(serial="physical-tablet")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(commands, "")

    def test_ci_caps_build_memory_in_its_own_gradle_home(self):
        result, _, _ = self.run_script(ci=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNotNone(result.gradle_properties)
        self.assertIn("org.gradle.jvmargs=-Xmx3G -XX:MaxMetaspaceSize=1G -XX:ReservedCodeCacheSize=256m", result.gradle_properties)
        self.assertIn("org.gradle.workers.max=2", result.gradle_properties)
        self.assertIn("org.gradle.parallel=false", result.gradle_properties)
        self.assertIn("kotlin.compiler.execution.strategy=in-process", result.gradle_properties)

    def test_local_emulator_run_does_not_reconfigure_gradle(self):
        result, _, _ = self.run_script()
        self.assertIsNone(result.gradle_properties)

    def test_journey_failure_stays_blocking_with_bounded_ci_host_diagnostics(self):
        result, commands, log = self.run_script(ci=True, journey_fails=True)
        self.assertEqual(result.returncode, 23)
        self.assertIn("synthetic host memory", log)
        self.assertIn("Killed process", log)
        self.assertIn("adb -s emulator-5554 get-state", commands)
        self.assertNotIn("logcat", commands)
        self.assertNotIn("dumpsys", commands)

    def test_diagnostic_errors_do_not_replace_the_actual_failure(self):
        result, _, _ = self.run_script(ci=True, journey_fails=True, diagnostics_fail=True)
        self.assertEqual(result.returncode, 23)


if __name__ == "__main__":
    unittest.main()
