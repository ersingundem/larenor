import json
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import zipfile

from tool import product_android_native as product


def _write_aar(path: Path, abi: str, *, classes: bytes = b"classes") -> None:
    with zipfile.ZipFile(path, "w") as bundle:
        bundle.writestr("AndroidManifest.xml", b"manifest")
        bundle.writestr("classes.jar", classes)
        bundle.writestr("res/values/values.xml", b"resources")
        bundle.writestr(f"jni/{abi}/libfreerdp-android.so", abi.encode())
        bundle.writestr(f"jni/{abi}/libssl.so", b"ssl-" + abi.encode())


class ProductAndroidNativeTest(unittest.TestCase):
    def test_direct_cli_starts_without_pythonpath_or_workspace_cwd(self) -> None:
        root = Path(__file__).resolve().parents[2]
        environment = dict(os.environ)
        environment.pop("PYTHONPATH", None)
        with tempfile.TemporaryDirectory() as temporary:
            completed = subprocess.run(
                [sys.executable, str(root / "tool/product_android_native.py"), "--help"],
                cwd=temporary,
                env=environment,
                capture_output=True,
                text=True,
                timeout=10,
            )

        self.assertEqual(0, completed.returncode, completed.stderr)
        self.assertIn("verify-apk", completed.stdout)

    def _inputs(self, root: Path) -> dict[str, Path]:
        values = {
            "moonlight_aar": root / "moonlight.aar",
            "moonlight_receipt": root / "moonlight.json",
            "freerdp_arm64_aar": root / "freerdp-arm64.aar",
            "freerdp_arm64_receipt": root / "freerdp-arm64.json",
            "freerdp_x86_aar": root / "freerdp-x86.aar",
            "freerdp_x86_receipt": root / "freerdp-x86.json",
        }
        values["moonlight_aar"].write_bytes(b"moonlight")
        values["moonlight_receipt"].write_text("{}")
        _write_aar(values["freerdp_arm64_aar"], "arm64-v8a")
        _write_aar(values["freerdp_x86_aar"], "x86_64")
        for abi, path in (
            ("arm64-v8a", values["freerdp_arm64_receipt"]),
            ("x86_64", values["freerdp_x86_receipt"]),
        ):
            native = abi.encode()
            path.write_text(json.dumps({
                "abi": abi,
                "engineRevision": "freerdp-test",
                "sourceCommit": "a" * 40,
                "sourceSha256": "b" * 64,
                "classesSha256": hashlib.sha256(b"classes").hexdigest(),
                "patches": [],
                "libraries": [{
                    "name": "libfreerdp-android.so",
                    "size": len(native),
                    "sha256": hashlib.sha256(native).hexdigest(),
                }],
            }))
        return values

    @mock.patch.object(product.moonlight_package, "load_lock", return_value={})
    @mock.patch.object(product.moonlight_package, "verify_install")
    @mock.patch.object(product.freerdp_package, "load_lock", return_value={})
    @mock.patch.object(product.freerdp_package, "_verify_receipt_contract")
    @mock.patch.object(product.freerdp_package, "verify_install")
    def test_install_verifies_both_engines_and_merges_exact_freerdp_abis(
        self,
        verify_freerdp: mock.Mock,
        _receipt_contract: mock.Mock,
        _free_lock: mock.Mock,
        verify_moonlight: mock.Mock,
        _moon_lock: mock.Mock,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            inputs = self._inputs(root)
            destination = root / "app"

            product.install(destination=destination, **inputs)

            self.assertEqual(2, verify_freerdp.call_count)
            self.assertEqual(2, verify_moonlight.call_count)
            with zipfile.ZipFile(destination / "freerdp/freeRDPCore.aar") as aar:
                self.assertIn("jni/arm64-v8a/libfreerdp-android.so", aar.namelist())
                self.assertIn("jni/x86_64/libfreerdp-android.so", aar.namelist())
                self.assertIn("jni/arm64-v8a/libssl.so", aar.namelist())
            receipt = json.loads(
                (destination / "product-native-receipt.json").read_text()
            )
            self.assertEqual(["freerdp", "moonlight"], sorted(receipt["engines"]))
            self.assertEqual(
                ["arm64-v8a", "x86_64"], receipt["engines"]["freerdp"]["abis"]
            )
            with zipfile.ZipFile(
                destination / "freerdp/freeRDPCore.aar", "a"
            ) as aar:
                aar.writestr("tampered.txt", b"tampered")
            with self.assertRaisesRegex(
                product.ProductNativeError, "product_receipt_mismatch"
            ):
                product.verify_installed(destination)

    @mock.patch.object(product.moonlight_package, "load_lock", return_value={})
    @mock.patch.object(product.moonlight_package, "verify_install")
    @mock.patch.object(product.freerdp_package, "load_lock", return_value={})
    @mock.patch.object(product.freerdp_package, "_verify_receipt_contract")
    @mock.patch.object(product.freerdp_package, "verify_install")
    def test_install_is_atomic_when_freerdp_non_native_contents_differ(
        self,
        _verify_freerdp: mock.Mock,
        _receipt_contract: mock.Mock,
        _free_lock: mock.Mock,
        _verify_moonlight: mock.Mock,
        _moon_lock: mock.Mock,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            inputs = self._inputs(root)
            _write_aar(inputs["freerdp_x86_aar"], "x86_64", classes=b"changed")
            destination = root / "app"

            with self.assertRaisesRegex(product.ProductNativeError, "freerdp_variant"):
                product.install(destination=destination, **inputs)

            self.assertFalse(destination.exists())

    @mock.patch.object(product.moonlight_package, "verify_apk")
    @mock.patch.object(product.moonlight_package, "load_lock", return_value={})
    @mock.patch.object(product.freerdp_package, "verify_apk")
    @mock.patch.object(product.freerdp_package, "load_lock", return_value={})
    @mock.patch.object(product, "verify_installed")
    def test_verify_apk_requires_moonlight_and_each_freerdp_abi_receipt(
        self,
        verify_installed: mock.Mock,
        _free_lock: mock.Mock,
        verify_freerdp: mock.Mock,
        _moon_lock: mock.Mock,
        verify_moonlight: mock.Mock,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / "app"
            (app / "moonlight").mkdir(parents=True)
            (app / "freerdp").mkdir()
            for relative in (
                "moonlight/receipt.json",
                "freerdp/arm64-v8a-receipt.json",
                "freerdp/x86_64-receipt.json",
            ):
                (app / relative).write_text("{}")
            apk = root / "product.apk"
            native = b"native"
            product_receipt = {
                "engines": {
                    "freerdp": {
                        "libraries": {
                            abi: [{
                                "name": "libfreerdp-android.so",
                                "size": len(native),
                                "sha256": hashlib.sha256(native).hexdigest(),
                            }]
                            for abi in ("arm64-v8a", "x86_64")
                        }
                    }
                }
            }
            (app / "product-native-receipt.json").write_text(
                json.dumps(product_receipt)
            )
            with zipfile.ZipFile(apk, "w") as bundle:
                for abi in ("arm64-v8a", "x86_64"):
                    bundle.writestr(f"lib/{abi}/libfreerdp-android.so", native)

            product.verify_product_apk(apk=apk, destination=app)

            verify_installed.assert_called_once_with(app)
            self.assertEqual(2, verify_freerdp.call_count)
            verify_moonlight.assert_called_once()

    def test_workflow_builds_installs_and_verifies_both_engines_for_product_apks(
        self,
    ) -> None:
        workflow = (
            Path(__file__).resolve().parents[2]
            / ".github/workflows/android-build.yml"
        ).read_text()

        self.assertIn("build-product-native-engines:", workflow)
        self.assertIn("product_android_native.py install", workflow)
        self.assertGreaterEqual(
            workflow.count("LARENOR_PRODUCT_NATIVE_ENGINES: required"), 2
        )
        self.assertIn(
            "product_android_native.py verify-apk build/app/outputs/flutter-apk/app-debug.apk",
            workflow,
        )
        self.assertIn(
            "product_android_native.py verify-apk build/app/outputs/flutter-apk/app-release.apk",
            workflow,
        )
        self.assertIn(
            "needs: [build-debug-apk, analyze-test, end-to-end, server-test]",
            workflow,
        )
        self.assertIn(
            "build-debug-apk:\n    needs: build-product-native-engines",
            workflow,
        )
        freerdp_build = workflow.split(
            "      - name: Build and receipt both source-locked FreeRDP ABIs\n", 1
        )[1].split("      - name: Compose and reverify", 1)[0]
        self.assertIn("for abi in arm64-v8a x86_64; do", freerdp_build)
        self.assertIn('source="$RUNNER_TEMP/freerdp-source-$abi"', freerdp_build)
        self.assertIn('--directory "$source"', freerdp_build)
        self.assertIn('studio="$source/client/Android/Studio"', freerdp_build)
        self.assertNotIn('$RUNNER_TEMP/freerdp-source/client/Android/Studio', freerdp_build)
        for patch_name in (
            "freerdp-certificate-pem.patch",
            "freerdp-clipboard-utf8.patch",
            "freerdp-display-pointer-v2.patch",
            "freerdp-remote-audio-v3.patch",
        ):
            self.assertIn(f'git apply --check "$GITHUB_WORKSPACE/android/{patch_name}"', freerdp_build)
            self.assertIn(f'git apply "$GITHUB_WORKSPACE/android/{patch_name}"', freerdp_build)
        self.assertLess(
            freerdp_build.index('git apply "$GITHUB_WORKSPACE/android/freerdp-certificate-pem.patch"'),
            freerdp_build.index('git apply "$GITHUB_WORKSPACE/android/freerdp-clipboard-utf8.patch"'),
        )
        self.assertLess(
            freerdp_build.index('git apply "$GITHUB_WORKSPACE/android/freerdp-clipboard-utf8.patch"'),
            freerdp_build.index('git apply "$GITHUB_WORKSPACE/android/freerdp-display-pointer-v2.patch"'),
        )
        self.assertIn('freerdp_android_package.py" verify-patch .', freerdp_build)
        source_bundle = freerdp_build.split('cp "$archive"', 1)[1]
        self.assertIn('"$GITHUB_WORKSPACE/android/freerdp-display-pointer-v2.patch"', source_bundle)
        gradle = (
            Path(__file__).resolve().parents[2] / "android/app/build.gradle.kts"
        ).read_text()
        self.assertIn('LARENOR_PRODUCT_NATIVE_ENGINES', gradle)
        self.assertIn('productNativeSetting == "required" && !hasProductNative', gradle)
        self.assertIn('tool/product_android_native.py", "verify-installed"', gradle)


if __name__ == "__main__":
    unittest.main()
