"""Exercise emulator evidence boundaries with synthetic subprocesses only."""

import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "android_e2e_diagnostics.py"
SPEC = importlib.util.spec_from_file_location("e2e_diagnostics", SCRIPT)
diagnostics = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(diagnostics)


class NativeFocusDiagnosticsTest(unittest.TestCase):
    def test_local_session_and_physical_serial_never_access_adb(self):
        with patch.object(diagnostics, "_adb") as adb, tempfile.TemporaryDirectory() as folder:
            with patch.dict(os.environ, {"GITHUB_ACTIONS": "false"}):
                self.assertFalse(diagnostics.capture("emulator-5554", Path(folder)))
            with patch.dict(os.environ, {"GITHUB_ACTIONS": "true"}):
                for serial in ("physical-tablet", "", "emulator-5554;touch x", "localhost:5555"):
                    self.assertFalse(diagnostics.capture(serial, Path(folder)))
            adb.assert_not_called()

    def test_qemu_proof_is_required_before_state_or_screenshot(self):
        with patch.dict(os.environ, {"GITHUB_ACTIONS": "true"}), tempfile.TemporaryDirectory() as folder:
            for result in (None, b"0\n", b"synthetic-secret", b"1\nextra"):
                with patch.object(diagnostics, "_adb", return_value=result) as adb:
                    self.assertFalse(diagnostics.capture("emulator-5554", Path(folder)))
                    self.assertEqual(adb.call_count, 1)
            self.assertEqual(list(Path(folder).iterdir()), [])

    def test_power_summary_retains_only_fixed_states(self):
        raw = b"mWakefulness=Asleep\nmIsPowered=true mStayOn=false\nDisplay Power: state=OFF\nWake Locks: synthetic-secret"
        self.assertEqual(diagnostics.summarize_power(raw), {
            "available": True, "mIsPowered": True, "mStayOn": False,
            "wakefulness": "Asleep", "displayState": "OFF",
        })
        self.assertEqual(diagnostics.summarize_power(None), {"available": False})
        self.assertEqual(diagnostics.summarize_power(b"mWakefulness=synthetic-secret"), {"available": True})

    def test_window_summary_never_retains_titles_or_unknown_package_names(self):
        raw = b"""mCurrentFocus=Window{123 u0 com.example.secret/Account secret@example.test}
  mFocusedApp=ActivityRecord{9 com.ersingundem.larenor/.MainActivity}
unrelated app data: synthetic-secret
"""
        summary = diagnostics.summarize_windows(raw)
        self.assertEqual(summary, {"available": True, "mCurrentFocus": ["other"], "mFocusedApp": ["larenor"]})
        self.assertNotIn("secret", json.dumps(summary))
        self.assertEqual(diagnostics.summarize_windows(None), {"available": False})

    def test_focus_classifications_distinguish_system_interference(self):
        cases = {
            "null": "none", "Window{Application Error: synthetic-secret}": "application_error_dialog",
            "Window{Application Not Responding: synthetic-secret}": "application_error_dialog",
            "Window{com.android.systemui/Keyguard}": "system_ui", "Window{NotificationShade}": "system_ui",
            "Window{com.android.permissioncontroller/Permission}": "permission_dialog",
            "Window{android/com.android.internal.app.ResolverActivity}": "resolver_dialog",
            "Window{com.android.launcher3/Launcher}": "launcher",
        }
        for value, expected in cases.items():
            with self.subTest(value=value):
                self.assertEqual(diagnostics._focus_owner(value), expected)
        many = (b"mCurrentFocus=null\n" * 20)
        self.assertEqual(len(diagnostics.summarize_windows(many)["mCurrentFocus"]), 4)

    def test_keyguard_policy_retains_only_boolean_fields(self):
        summary = diagnostics.summarize_policy(b"mAwake=true mScreenOnEarly=false\nshowing=true\ninputRestricted=true\ntext=synthetic-secret")
        self.assertEqual(summary, {"available": True, "mAwake": True,
            "mScreenOnEarly": False, "showing": True, "inputRestricted": True})
        self.assertEqual(diagnostics.summarize_policy(None), {"available": False})

    def test_capture_uses_exact_read_only_commands_and_only_filtered_artifacts(self):
        replies = {
            ("shell", "getprop", "ro.kernel.qemu"): b"1\r\n",
            ("shell", "dumpsys", "power"): b"mWakefulness=Awake\nsecret-power-data",
            # API 35 emits focus ownership in the display dump, not `windows`.
            ("shell", "dumpsys", "window", "displays"): b"mCurrentFocus=Window{Application Not Responding: synthetic-secret}",
            ("shell", "dumpsys", "window", "policy"): b"showing=true\nsecret-policy-data",
            ("exec-out", "screencap", "-p"): diagnostics.PNG_SIGNATURE + b"synthetic-image",
        }
        def adb(serial, args, maximum=diagnostics.MAX_STATE_BYTES):
            self.assertEqual(serial, "emulator-5554")
            self.assertIn(tuple(args), replies)
            return replies[tuple(args)]
        with patch.dict(os.environ, {"GITHUB_ACTIONS": "true"}), patch.object(diagnostics, "_adb", side_effect=adb) as mock:
            with tempfile.TemporaryDirectory() as folder:
                output = Path(folder)
                self.assertTrue(diagnostics.capture("emulator-5554", output))
                self.assertEqual(mock.call_count, 5)
                state = (output / "native-focus.json").read_text()
                self.assertNotIn("secret", state)
                self.assertTrue(json.loads(state)["screenshotAvailable"])
                self.assertEqual(json.loads(state)["windows"]["mCurrentFocus"], ["application_error_dialog"])
                self.assertEqual(set(p.name for p in output.iterdir()), {"native-focus.json", "native-focus.png"})

    def test_partial_device_failure_still_preserves_available_filtered_evidence(self):
        with patch.dict(os.environ, {"GITHUB_ACTIONS": "true"}), patch.object(diagnostics, "_adb", side_effect=[b"1\n", None, None, None, None]):
            with tempfile.TemporaryDirectory() as folder:
                self.assertTrue(diagnostics.capture("emulator-5554", Path(folder)))
                value = json.loads((Path(folder) / "native-focus.json").read_text())
                self.assertFalse(value["screenshotAvailable"])
                self.assertFalse(value["power"]["available"])
                self.assertFalse((Path(folder) / "native-focus.png").exists())

    def run_synthetic_child(self, script, *, maximum=32, timeout=0.6):
        original_popen, original_read = subprocess.Popen, os.read
        children, reads, waits = [], [], []
        def spawn(args, **kwargs):
            self.assertEqual(args, ["adb", "-s", "emulator-5554", "get-state"])
            # Fail old unrestricted capture before starting a flooding child.
            self.assertEqual(kwargs["stderr"], subprocess.DEVNULL)
            self.assertEqual(kwargs["stdin"], subprocess.DEVNULL)
            child = original_popen([sys.executable, "-c", script], **kwargs)
            original_wait = child.wait
            def wait(*args, **kwargs):
                waits.append(kwargs.get("timeout"))
                return original_wait(*args, **kwargs)
            child.wait = wait
            children.append(child)
            return child
        def read(fd, size):
            if children and not children[0].stdout.closed and fd == children[0].stdout.fileno():
                reads.append(size)
            return original_read(fd, size)
        start = time.monotonic()
        with patch.object(subprocess, "Popen", side_effect=spawn), patch.object(os, "read", side_effect=read), \
             patch.object(diagnostics, "ADB_TIMEOUT_SECONDS", timeout, create=True):
            value = diagnostics._adb("emulator-5554", ["get-state"], maximum=maximum)
        elapsed = time.monotonic() - start
        for child in children:
            self.assertIsNotNone(child.returncode, "every child must be reaped")
            self.assertTrue(child.stdout.closed)
        return value, reads, waits, elapsed

    def test_stdout_flood_is_stopped_while_reading_then_killed_and_reaped(self):
        value, reads, _, elapsed = self.run_synthetic_child(
            'import os\nwhile True: os.write(1, b"x" * 65536)')
        self.assertIsNone(value)
        self.assertTrue(reads)
        self.assertLessEqual(max(reads), 33)
        self.assertLess(elapsed, 2)

    def test_heavy_stderr_is_discarded_and_exact_stdout_limit_is_accepted(self):
        value, reads, _, _ = self.run_synthetic_child(
            'import os; os.write(2, b"synthetic-secret" * 200000); os.write(1, b"x" * 32)')
        self.assertEqual(value, b"x" * 32)
        self.assertLessEqual(max(reads), 33)

    def test_slow_drip_stdout_cannot_renew_the_shared_deadline(self):
        value, _, _, elapsed = self.run_synthetic_child(
            'import os,time\nwhile True:\n os.write(1,b"x"); time.sleep(0.02)', maximum=1024)
        self.assertIsNone(value)
        self.assertLess(elapsed, 2)

    def test_wait_after_stdout_eof_uses_only_the_remaining_deadline(self):
        value, _, waits, elapsed = self.run_synthetic_child(
            'import os,time; os.write(1,b"ok"); time.sleep(0.15); os.close(1); time.sleep(5)')
        self.assertIsNone(value)
        remaining = [value for value in waits if value is not None]
        self.assertTrue(remaining)
        self.assertLess(remaining[0], 0.5)
        self.assertLess(elapsed, 2)

    def test_nonzero_or_missing_subprocess_never_reflects_output(self):
        value, _, _, _ = self.run_synthetic_child(
            'import os; os.write(1,b"synthetic-secret"); os._exit(7)')
        self.assertIsNone(value)
        with patch.object(subprocess, "Popen", side_effect=OSError("synthetic-secret")):
            self.assertIsNone(diagnostics._adb("emulator-5554", ["get-state"]))

    def test_streaming_marker_captures_once_without_changing_test_output(self):
        original = b"test one\n" + diagnostics.MARKER + b"focused=false\nsecond\n" + diagnostics.MARKER + b"again\n"
        output = io.BytesIO()
        with patch.object(diagnostics, "capture", return_value=True) as capture:
            diagnostics.relay("emulator-5554", io.BytesIO(original), output, Path("unused"))
            capture.assert_called_once()
        self.assertEqual(output.getvalue().replace(b"CI native focus snapshot captured.\n", b""), original)

    def test_capture_errors_do_not_drop_following_output_or_replace_test_failure(self):
        original = diagnostics.MARKER + b"focused=false\nassertion failed\n"
        output = io.BytesIO()
        with patch.object(diagnostics, "capture", side_effect=OSError("synthetic-secret")):
            diagnostics.relay("emulator-5554", io.BytesIO(original), output, Path("unused"))
        self.assertIn(b"assertion failed", output.getvalue())
        self.assertIn(b"snapshot unavailable", output.getvalue())
        self.assertNotIn(b"synthetic-secret", output.getvalue())

    def test_normal_stream_does_not_attempt_diagnostics(self):
        with patch.object(diagnostics, "capture") as capture:
            output = io.BytesIO()
            diagnostics.relay("emulator-5554", io.BytesIO(b"normal test output\n"), output, Path("unused"))
            capture.assert_not_called()
            self.assertEqual(output.getvalue(), b"normal test output\n")


if __name__ == "__main__":
    unittest.main()
