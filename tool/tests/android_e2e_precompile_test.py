"""Exercise host-only Android preparation without selecting any device."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "tool/prepare_android_e2e_build.sh"


class AndroidE2EPrecompileTest(unittest.TestCase):
    def run_script(self, *, generation=0, build=0, ci=True):
        with tempfile.TemporaryDirectory(prefix="larenor warm build ") as folder:
            root = Path(folder)
            binaries = root / "bin"
            binaries.mkdir()
            for name, body in {
                "dart": 'echo "generated"; exit "$GENERATION_EXIT"',
                "flutter": 'echo "compiled"; exit "$BUILD_EXIT"',
                "adb": 'exit 99',
            }.items():
                file = binaries / name
                file.write_text(
                    '#!/bin/bash\nprintf "%s\\n" "$0 $*" >> "$COMMAND_TRACE"\n'
                    'printf "%s\\n" "${GRADLE_USER_HOME:-unset}" >> "$GRADLE_TRACE"\n'
                    + body + "\n"
                )
                file.chmod(0o755)
            trace = root / "commands"
            gradle_trace = root / "gradle"
            result = subprocess.run(
                ["bash", str(SCRIPT)], cwd=root, capture_output=True, text=True,
                env={**os.environ, "PATH": f"{binaries}:/usr/bin:/bin",
                     "GITHUB_ACTIONS": "true" if ci else "false",
                     "RUNNER_TEMP": str(root / "runner temp"),
                     "GRADLE_USER_HOME": str(root / "developer gradle"),
                     "COMMAND_TRACE": str(trace), "GRADLE_TRACE": str(gradle_trace),
                     "GENERATION_EXIT": str(generation), "BUILD_EXIT": str(build)},
                timeout=5, check=False,
            )
            props = root / "runner temp/larenor-e2e-gradle/gradle.properties"
            log = root / "build/e2e/android-precompile.log"
            return (result, trace.read_text() if trace.exists() else "",
                    gradle_trace.read_text() if gradle_trace.exists() else "",
                    props.read_text() if props.exists() else None,
                    log.read_text() if log.exists() else "", root)

    def test_host_build_generates_then_compiles_native_test_without_adb(self):
        result, trace, homes, properties, log, root = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLess(trace.index("dart run build_runner build"), trace.index("flutter build apk"))
        self.assertIn("--debug", trace)
        self.assertIn("--target-platform android-x64", trace)
        self.assertIn("--target integration_test/platform_storage_test.dart", trace)
        self.assertIn("--dart-define=LARENOR_E2E=true", trace)
        self.assertNotIn("adb", trace)
        self.assertNotIn("flutter test", trace)
        self.assertEqual(homes.splitlines(), [str(root / "runner temp/larenor-e2e-gradle")] * 2)
        self.assertIn("org.gradle.jvmargs=-Xmx3G", properties)
        self.assertIn("org.gradle.workers.max=2", properties)
        self.assertIn("generated", log)
        self.assertIn("compiled", log)

    def test_generation_failure_preserves_evidence_and_does_not_compile(self):
        result, trace, _, _, log, _ = self.run_script(generation=17)
        self.assertEqual(result.returncode, 17, result.stderr)
        self.assertNotIn("flutter", trace)
        self.assertNotIn("adb", trace)
        self.assertIn("generated", log)

    def test_compile_failure_blocks_the_next_workflow_step(self):
        result, trace, _, _, log, _ = self.run_script(build=23)
        self.assertEqual(result.returncode, 23, result.stderr)
        self.assertIn("compiled", log)
        self.assertNotIn("adb", trace)

    def test_local_build_preserves_developer_gradle_home(self):
        result, _, homes, properties, _, root = self.run_script(ci=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNone(properties)
        self.assertEqual(homes.splitlines(), [str(root / "developer gradle")] * 2)

    def test_ci_builds_before_starting_the_emulator_and_retains_both_logs(self):
        workflow = (ROOT / ".github/workflows/android-e2e.yml").read_text()
        command = "bash tool/prepare_android_e2e_build.sh"
        self.assertIn(command, workflow)
        self.assertLess(workflow.index(command), workflow.index("uses: ReactiveCircus/android-emulator-runner@"))
        self.assertIn("build/e2e/android-precompile.log", workflow)
        self.assertIn("build/e2e/android-e2e.log", workflow)
        self.assertIn("timeout 18m bash tool/run_android_e2e.sh emulator-5554", workflow)


if __name__ == "__main__":
    unittest.main()
