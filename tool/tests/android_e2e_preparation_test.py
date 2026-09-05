"""Exercise clean-checkout preparation and failure gates without an Android device."""

import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import Mock, patch


SCRIPT = Path(__file__).resolve().parents[1] / "run_android_e2e.sh"


class AndroidE2EPreparationTest(unittest.TestCase):
    def run_script(self, *, generation_fails=False, journey_fails=False, focus_fails=False, diagnostics_fail=False, relay_fails=False, tee_fails=False, ci=False, serial="emulator-5554", qemu=True, stay_on="15", power_fails=False, setting_fails=False):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            binaries = root / "bin"
            binaries.mkdir()
            commands = {
                "adb": '#!/bin/bash\necho "adb $*" >> "$COMMAND_TRACE"\n'
                       'if [[ "$*" == *"getprop ro.kernel.qemu" ]]; then echo "$TEST_QEMU"; fi\n'
                       'if [[ "$*" == *"svc power stayon true" && "$FAIL_POWER" == 1 ]]; then echo "synthetic-private-adb-error" >&2; exit 9; fi\n'
                       'if [[ "$*" == *"settings get global stay_on_while_plugged_in" ]]; then\n'
                       '  [[ "$FAIL_SETTING" == 1 ]] && exit 10\n'
                       '  index=$(cat "${COMMAND_TRACE}.reads" 2>/dev/null || echo 0)\n'
                       '  IFS="|" read -ra values <<< "$TEST_STAY_ON"\n'
                       '  selected=$index; (( selected >= ${#values[@]} )) && selected=$((${#values[@]} - 1))\n'
                       '  echo "${values[$selected]}"; echo $((index + 1)) > "${COMMAND_TRACE}.reads"\n'
                       'fi\n',
                "dart": '#!/bin/bash\necho "dart $*" >> "$COMMAND_TRACE"\n'
                        'echo "synthetic source generation"\n'
                        'if [[ "$FAIL_GENERATION" == 1 ]]; then exit 17; fi\n'
                        'touch generated-synthetic-model\n',
                "flutter": '#!/bin/bash\necho "flutter $*" >> "$COMMAND_TRACE"\n'
                           'test -f generated-synthetic-model || exit 31\n'
                           'if [[ "$GITHUB_ACTIONS" == true && "${GRADLE_USER_HOME:-}" != "$RUNNER_TEMP/larenor-e2e-gradle" ]]; then exit 41; fi\n'
                           'if [[ "$FAIL_FOCUS" == 1 ]]; then echo "LARENOR_E2E_NATIVE_FOCUS_FAILURE kioskFocused=false keyguardLocked=true"; exit 23; fi\n'
                           'if [[ "$FAIL_JOURNEY" == 1 ]]; then exit 23; fi\n'
                           'echo "synthetic journey success"\n',
                "free": '#!/bin/bash\n[[ "$FAIL_DIAGNOSTICS" == 1 ]] && exit 7\necho "synthetic host memory"\n',
                "ps": '#!/bin/bash\n[[ "$FAIL_DIAGNOSTICS" == 1 ]] && exit 7\necho "qemu-system-x86 2097152"\n',
                "sudo": '#!/bin/bash\n[[ "$FAIL_DIAGNOSTICS" == 1 ]] && exit 7\necho "kernel: Out of memory: Killed process 123 (qemu-system-x)"\n',
                "timeout": '#!/bin/bash\nshift\nexec "$@"\n',
                "python3": '#!/bin/bash\nif [[ "$FAIL_RELAY" == 1 && "$1" == *android_e2e_diagnostics.py ]]; then cat; exit 7; fi\nexec "$TEST_PYTHON" "$@"\n',
                "tee": '#!/bin/bash\n/usr/bin/tee "$@"\nif [[ "$FAIL_TEE" == 1 && "$1" == -a ]]; then exit 9; fi\n',
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
                                         "TEST_QEMU": "1" if qemu else "0",
                                         "TEST_STAY_ON": "|".join(stay_on) if isinstance(stay_on, list) else stay_on,
                                         "FAIL_POWER": "1" if power_fails else "0",
                                         "FAIL_SETTING": "1" if setting_fails else "0",
                                         "FAIL_JOURNEY": "1" if journey_fails else "0",
                                         "FAIL_FOCUS": "1" if focus_fails else "0",
                                         "FAIL_DIAGNOSTICS": "1" if diagnostics_fail else "0",
                                         "FAIL_RELAY": "1" if relay_fails else "0",
                                         "FAIL_TEE": "1" if tee_fails else "0",
                                         "TEST_PYTHON": sys.executable,
                                         "FAIL_GENERATION": "1" if generation_fails else "0"},
                                    capture_output=True, text=True, check=False, timeout=30)
            output = trace.read_text() if trace.exists() else ""
            log = root / "build/e2e/android-e2e.log"
            properties = root / "runner-temp/larenor-e2e-gradle/gradle.properties"
            result.gradle_properties = properties.read_text() if properties.exists() else None
            snapshot = root / "build/e2e/native-focus.json"
            result.focus_snapshot = snapshot.read_text() if snapshot.exists() else None
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

    def test_emulator_named_physical_device_cannot_change_power_or_build(self):
        result, commands, _ = self.run_script(qemu=False)
        self.assertEqual(result.returncode, 2)
        self.assertNotIn("svc power", commands)
        self.assertNotIn("dart ", commands)

    def test_stay_awake_is_verified_before_the_long_build(self):
        for setting in ("7", "15"):
            result, commands, _ = self.run_script(stay_on=setting)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertLess(commands.index("getprop ro.kernel.qemu"), commands.index("svc power stayon true"))
            self.assertLess(commands.index("svc power stayon true"), commands.index("dart run build_runner"))
            self.assertLess(commands.index("settings get global stay_on_while_plugged_in"), commands.index("flutter test"))

    def test_failed_stay_awake_precondition_never_builds_or_installs(self):
        for setting in ("0", "null", "permission denied"):
            result, commands, _ = self.run_script(stay_on=setting)
            self.assertEqual(result.returncode, 2)
            self.assertNotIn("dart ", commands)
            self.assertNotIn("flutter ", commands)

    def test_transient_setting_converges_before_build_with_bounded_reapplication(self):
        for values in (["0", "7"], ["null", "0", "15"]):
            with self.subTest(values=values):
                result, commands, _ = self.run_script(stay_on=values)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(commands.count("svc power stayon true"), len(values))
                self.assertLess(commands.rindex("settings get global stay_on_while_plugged_in"), commands.index("dart run build_runner"))
                self.assertNotIn("settings put global stay_on_while_plugged_in", commands)

    def test_permanent_malformed_setting_has_static_diagnostic_and_no_build(self):
        result, commands, _ = self.run_script(stay_on="synthetic-private-setting")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(commands.count("svc power stayon true"), 5)
        self.assertIn("last_observation=invalid", result.stderr)
        self.assertNotIn("synthetic-private-setting", result.stdout + result.stderr)
        self.assertNotIn("dart ", commands)
        self.assertNotIn("flutter ", commands)

    def test_adb_power_or_read_failure_never_builds_or_installs(self):
        for setting_failure in (False, True):
            result, commands, _ = self.run_script(power_fails=not setting_failure, setting_fails=setting_failure)
            self.assertEqual(result.returncode, 2)
            self.assertIn("result=adb_failed", result.stderr)
            self.assertNotIn("synthetic-private-adb-error", result.stdout + result.stderr)
            self.assertNotIn("dart ", commands)
            self.assertNotIn("flutter ", commands)

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

    def test_flutter_failure_takes_priority_over_relay_and_tee_failures(self):
        for relay, tee in ((True, False), (False, True), (True, True)):
            result, _, _ = self.run_script(journey_fails=True, relay_fails=relay, tee_fails=tee)
            self.assertEqual(result.returncode, 23, result.stderr)

    def test_successful_flutter_cannot_hide_relay_or_tee_failures(self):
        for relay, tee, status in ((True, False, 7), (False, True, 9), (True, True, 7)):
            result, _, _ = self.run_script(relay_fails=relay, tee_fails=tee)
            self.assertEqual(result.returncode, status, result.stderr)

    def test_focus_marker_captures_ci_state_and_preserves_failing_exit_status(self):
        result, commands, log = self.run_script(ci=True, focus_fails=True)
        self.assertEqual(result.returncode, 23, result.stderr)
        self.assertIn("kioskFocused=false keyguardLocked=true", log)
        self.assertIn("native focus snapshot captured", log)
        self.assertIn("adb -s emulator-5554 exec-out screencap -p", commands)
        self.assertIn("adb -s emulator-5554 shell dumpsys window displays", commands)
        self.assertIsNotNone(result.focus_snapshot)
        self.assertNotIn("logcat", commands)

    def test_same_marker_on_local_emulator_never_captures_a_screen(self):
        result, commands, log = self.run_script(focus_fails=True)
        self.assertEqual(result.returncode, 23, result.stderr)
        self.assertIn("kioskFocused=false keyguardLocked=true", log)
        self.assertNotIn("screencap", commands)
        self.assertNotIn("dumpsys", commands)
        self.assertIsNone(result.focus_snapshot)


class StayAwakeBudgetTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        path = SCRIPT.with_name("android_e2e_preparation.py")
        spec = importlib.util.spec_from_file_location("e2e_preparation", path)
        cls.helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.helper)

    def test_deadline_is_shared_by_all_commands_and_never_accepts_a_late_success(self):
        elapsed = [0.0]
        deadlines = []
        def command(_serial, args, deadline):
            deadlines.append(deadline)
            elapsed[0] += 1 if "getprop" in args else 5
            return b"1\n" if "getprop" in args else b"7\n"
        result = self.helper.ensure_awake("emulator-5554", command=command, clock=lambda: elapsed[0], sleep=lambda seconds: None)
        self.assertEqual(result.result, "deadline")
        self.assertEqual(result.attempts, 1)
        self.assertEqual(deadlines, [2.0, 3.0, 8.0])

    def test_retry_delay_cannot_extend_the_global_deadline(self):
        elapsed = [0.0]
        calls = []
        def command(_serial, args, deadline):
            calls.append(args)
            return b"1" if "getprop" in args else b"0"
        def sleep(_seconds):
            elapsed[0] += 10
        result = self.helper.ensure_awake("emulator-5554", command=command, clock=lambda: elapsed[0], sleep=sleep)
        self.assertEqual(result.result, "deadline")
        self.assertEqual(result.attempts, 1)
        self.assertEqual(len(calls), 3)

    def test_real_adb_reader_kills_and_reaps_on_overflow_or_deadline(self):
        for body in ('import os,time; os.write(1,b"x"*1048576); time.sleep(30)', 'import time; time.sleep(30)'):
            with self.subTest(body=body), tempfile.TemporaryDirectory() as folder:
                executable = Path(folder) / "adb"
                executable.write_text(f"#!{sys.executable}\n{body}\n")
                executable.chmod(0o755)
                processes = []
                original = subprocess.Popen
                def launch(*args, **kwargs):
                    process = original(*args, **kwargs)
                    processes.append(process)
                    return process
                with patch.dict(os.environ, {"PATH": folder + os.pathsep + os.environ["PATH"]}), patch.object(self.helper.subprocess, "Popen", side_effect=launch):
                    started = time.monotonic()
                    self.assertIsNone(self.helper._adb("emulator-5554", ["shell", "settings"], started + 0.3))
                    self.assertLess(time.monotonic() - started, 1.5)
                self.assertIsNotNone(processes[0].poll())
                self.assertTrue(processes[0].stdout.closed)

    def test_invalid_serial_and_non_qemu_are_rejected_before_setting_commands(self):
        command = Mock(return_value=b"0")
        self.assertEqual(self.helper.ensure_awake("physical-device", command=command).result, "invalid_emulator")
        command.assert_not_called()
        self.assertEqual(self.helper.ensure_awake("emulator-5554", command=command).result, "invalid_emulator")
        self.assertEqual(command.call_count, 1)


if __name__ == "__main__":
    unittest.main()
