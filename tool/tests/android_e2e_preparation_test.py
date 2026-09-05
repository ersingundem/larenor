"""Exercise clean-checkout preparation and failure gates without an Android device."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "run_android_e2e.sh"


class AndroidE2EPreparationTest(unittest.TestCase):
    def run_script(self, *, generation_fails=False, serial="emulator-5554"):
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
                           'echo "synthetic journey success"\n',
            }
            for name, content in commands.items():
                file = binaries / name
                file.write_text(content)
                file.chmod(0o755)
            trace = root / "commands.log"
            result = subprocess.run(["bash", str(SCRIPT), serial], cwd=root,
                                    env={**os.environ, "PATH": f"{binaries}:/usr/bin:/bin",
                                         "COMMAND_TRACE": str(trace),
                                         "FAIL_GENERATION": "1" if generation_fails else "0"},
                                    capture_output=True, text=True, check=False)
            output = trace.read_text() if trace.exists() else ""
            log = root / "build/e2e/android-e2e.log"
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


if __name__ == "__main__":
    unittest.main()
