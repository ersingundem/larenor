import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from tool.freerdp_android_package import (
    PackageError,
    load_lock,
    verify_always_pin_patch,
    verify_certificate_patch,
    verify_clipboard_patch,
    verify_display_pointer_patch,
    verify_install,
    verify_microphone_patch,
    verify_remote_access_patch,
    verify_remote_audio_patch,
)


ROOT = Path(__file__).resolve().parents[2]
PRISTINE = ROOT / (
    "tool/tests/fixtures/freerdp-3.31.1/remote-access-v5-pristine"
)


class FreeRdpRemoteAccessV5PackageTest(unittest.TestCase):
    @staticmethod
    def _git_blob(payload: bytes) -> str:
        header = f"blob {len(payload)}\0".encode()
        return hashlib.sha1(header + payload).hexdigest()

    def _patched_tree(self, parent: Path) -> Path:
        source = parent / "source"
        shutil.copytree(PRISTINE, source)
        lock = load_lock()
        for item in lock["patches"]:
            patch = ROOT / item["path"]
            subprocess.run(
                ["git", "apply", "--check", str(patch)],
                cwd=source,
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
            )
            subprocess.run(
                ["git", "apply", str(patch)],
                cwd=source,
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
            )
        return source

    @staticmethod
    def _verify_all_patches(source: Path) -> None:
        native = source / (
            "client/Android/Studio/freeRDPCore/src/main/cpp/android_freerdp.c"
        )
        verify_certificate_patch(native)
        verify_clipboard_patch(native)
        verify_display_pointer_patch(source)
        verify_remote_audio_patch(source)
        verify_always_pin_patch(source)
        verify_microphone_patch(source)
        verify_remote_access_patch(source)

    def test_schema5_lock_binds_source_patch_and_runtime_identity(self):
        lock = load_lock()
        self.assertEqual(lock["jniSchema"], 5)
        self.assertEqual(
            lock["engineRevision"],
            "freerdp-3.31.1-63b948ca-remote-access-v5",
        )
        self.assertEqual(len(lock["reviewedFiles"]), 24)
        self.assertEqual(len(lock["patches"]), 7)
        self.assertEqual(
            lock["patches"][-1]["path"],
            "android/freerdp-remote-access-v5.patch",
        )
        self.assertEqual(
            lock["patches"][-1]["sha256"],
            hashlib.sha256(
                (ROOT / "android/freerdp-remote-access-v5.patch").read_bytes()
            ).hexdigest(),
        )
        self.assertEqual(lock["defaultChannels"], [])

    def test_all_seven_patches_apply_to_exact_reviewed_pristine_fixture(self):
        lock = load_lock()
        fixture_files = {
            path.relative_to(PRISTINE).as_posix(): path
            for path in PRISTINE.rglob("*")
            if path.is_file()
        }
        self.assertEqual(20, len(fixture_files))
        for relative, path in fixture_files.items():
            with self.subTest(relative=relative):
                self.assertEqual(
                    lock["reviewedFiles"][relative],
                    self._git_blob(path.read_bytes()),
                )
        with tempfile.TemporaryDirectory() as directory:
            source = self._patched_tree(Path(directory))
            self._verify_all_patches(source)

    def test_verifier_rejects_gateway_path_quota_shutdown_and_lifecycle_drift(self):
        cases = (
            (
                "client/Android/Studio/freeRDPCore/src/main/cpp/android_freerdp.c",
                "FreeRDP_GatewayRpcTransport, FALSE",
                "FreeRDP_GatewayRpcTransport, TRUE",
            ),
            (
                "channels/drive/client/drive_larenor.c",
                'static const char prefix[] = "/proc/self/fd/";',
                'static const char prefix[] = "/tmp/";',
            ),
            (
                "channels/drive/client/drive_larenor.h",
                "#define LRN_MAX_FILES 32U",
                "#define LRN_MAX_FILES 33U",
            ),
            (
                "channels/drive/client/drive_main.c",
                "HANDLE events[] = { drive->stopEvent, MessageQueue_Event(drive->IrpQueue) };",
                "HANDLE events[] = { MessageQueue_Event(drive->IrpQueue), drive->stopEvent };",
            ),
            (
                "channels/drive/client/drive_main.c",
                'WLog_ERR(TAG, "CreateThread failed!");\n\t\t\t\terror = ERROR_INTERNAL_ERROR;',
                'WLog_ERR(TAG, "CreateThread failed!");\n\t\t\t\terror = CHANNEL_RC_OK;',
            ),
            (
                "client/Android/Studio/freeRDPCore/src/main/java/"
                "com/freerdp/freerdpcore/application/GlobalApp.java",
                "if (sessionListeners.get(instance) != listener)",
                "if (listener == null)",
            ),
            (
                "client/Android/Studio/freeRDPCore/src/main/java/"
                "com/freerdp/freerdpcore/services/LibFreeRDP.java",
                "lifecycle.draining = true;",
                "lifecycle.draining = false;",
            ),
        )
        for relative, old, new in cases:
            with self.subTest(relative=relative), tempfile.TemporaryDirectory() as directory:
                source = self._patched_tree(Path(directory))
                path = source / relative
                text = path.read_text(encoding="utf-8")
                self.assertEqual(text.count(old), 1)
                path.write_text(text.replace(old, new), encoding="utf-8")
                with self.assertRaisesRegex(
                    PackageError, "invalid_remote_access_patch"
                ):
                    verify_remote_access_patch(source)

    def test_workflow_applies_remote_access_patch_last_and_keeps_channels_default_off(self):
        workflow = json.loads(
            (ROOT / ".github/workflows/freerdp-android-native.yml").read_text()
        )
        runs = [
            step.get("run", "")
            for step in workflow["jobs"]["package"]["steps"]
            if step.get("name")
            == "Apply reviewed SPKI and standard Unicode JNI patches"
        ]
        self.assertEqual(len(runs), 1)
        run = runs[0]
        microphone = run.index(
            'git apply "$GITHUB_WORKSPACE/android/freerdp-microphone-v4.patch"'
        )
        remote = run.index(
            'git apply "$GITHUB_WORKSPACE/android/freerdp-remote-access-v5.patch"'
        )
        verify = run.index('freerdp_android_package.py" verify-patch .')
        self.assertLess(microphone, remote)
        self.assertLess(remote, verify)
        build = next(
            step["run"]
            for step in workflow["jobs"]["package"]["steps"]
            if step.get("name")
            == "Build one exact native ABI with optional channels default-off"
        )
        self.assertNotIn("CHANNEL_", build)
        self.assertNotIn("WITH_DRIVE", build)


_ACTUAL_ROOT = os.environ.get("LARENOR_FREERDP_NATIVE5_ACTUAL_ROOT")
if _ACTUAL_ROOT is not None:
    class FreeRdpRemoteAccessV5ActualPackageTest(unittest.TestCase):
        def test_explicit_actual_packages_match_their_strict_receipts(self):
            root = Path(_ACTUAL_ROOT)
            self.assertTrue(root.is_absolute())
            lock = load_lock()
            classes = set()
            for abi in lock["supportedAbis"]:
                with self.subTest(abi=abi):
                    package = root / abi / "freeRDPCore-release.aar"
                    receipt = root / abi / "receipt.json"
                    verify_install(package, receipt, lock)
                    value = json.loads(receipt.read_text(encoding="utf-8"))
                    self.assertEqual(abi, value["abi"])
                    classes.add(value["classesSha256"])
            self.assertEqual(1, len(classes))


if __name__ == "__main__":
    unittest.main()
