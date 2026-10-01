import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
from unittest import mock

from tool import android_acceptance_gradle as acceptance_gradle


ROOT = Path(__file__).resolve().parents[2]


class FreeRdpAndroidWorkflowTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = json.loads(
            (ROOT / ".github/workflows/freerdp-android-native.yml").read_text()
        )

    def test_closed_events_permissions_and_two_real_android_abis(self):
        self.assertEqual(self.workflow["on"]["workflow_dispatch"], {})
        self.assertEqual(self.workflow["on"]["pull_request"]["branches"], ["main"])
        self.assertEqual(self.workflow["permissions"], {"contents": "read"})
        job = self.workflow["jobs"]["package"]
        self.assertEqual(job["runs-on"], "ubuntu-24.04")
        self.assertEqual(job["strategy"]["matrix"]["abi"], ["arm64-v8a", "x86_64"])
        self.assertIs(job["strategy"]["fail-fast"], False)

    def test_actions_are_commit_pinned_and_no_secret_or_production_target_exists(self):
        text = json.dumps(self.workflow)
        self.assertNotIn("secrets.", text)
        # 10.0.2.2 is Android Emulator's reserved host-loopback alias. It is
        # the only private address allowed here and never names a real home.
        self.assertEqual(text.count("10.0.2.2"), 0)
        self.assertNotRegex(
            text.replace("10.0.2.2", ""),
            r"192\.168\.|10\.\d+\.|172\.(?:1[6-9]|2\d|3[01])\.",
        )
        for step in self.workflow["jobs"]["package"]["steps"]:
            if "uses" in step:
                self.assertRegex(
                    step["uses"],
                    r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[0-9a-f]{40}$",
                )
                if step["uses"].startswith("actions/checkout@"):
                    self.assertEqual(step["with"]["ref"], "${{ github.sha }}")
                    self.assertIs(step["with"]["persist-credentials"], False)

    def test_source_digest_toolchain_and_disabled_defaults_are_policy_gated(self):
        steps = self.workflow["jobs"]["package"]["steps"]
        flutter = next(
            step for step in steps
            if step.get("uses", "").startswith("subosito/flutter-action@")
        )
        self.assertEqual(flutter["with"]["flutter-version"], "3.47.2")
        verify = next(step["run"] for step in steps if "verify-source" in step.get("run", ""))
        build = next(step["run"] for step in steps if "assembleRelease" in step.get("run", ""))
        receipt = next(step["run"] for step in steps if " receipt " in step.get("run", ""))
        self.assertIn("freerdp-3.31.1.tar.gz", verify)
        self.assertIn("freerdp_android_package.py verify-source", verify)
        for exact in (
            "NDK_VERSION=29.0.13113456",
            "CMAKE_VERSION=4.1.2",
            "VERSION_NAME=3.31.1",
            "VERSION_CODE=3031001",
        ):
            self.assertIn(exact, build)
        for disabled in ("WITH_FFMPEG=OFF", "WITH_OPENH264=OFF", "WITH_OPUS=OFF"):
            self.assertIn(disabled, build)
        self.assertIn("freerdp_android_package.py receipt", receipt)
        product = next(step["run"] for step in steps if "verify-apk" in step.get("run", ""))
        self.assertIn("flutter build apk --debug", product)
        self.assertIn("android/app/freerdp/freeRDPCore.aar", product)
        self.assertIn("freerdp_android_package.py verify-apk", product)
        patch = next(step["run"] for step in steps if "freerdp-certificate-pem.patch" in step.get("run", ""))
        self.assertIn("git apply --check", patch)
        self.assertIn("freerdp_android_package.py\" verify-patch", patch)
        self.assertIn("<manifest", patch)
        self.assertLess(
            patch.index('git apply "$GITHUB_WORKSPACE/android/freerdp-certificate-pem.patch"'),
            patch.index('git apply "$GITHUB_WORKSPACE/android/freerdp-clipboard-utf8.patch"'),
        )
        self.assertLess(
            patch.index('git apply "$GITHUB_WORKSPACE/android/freerdp-clipboard-utf8.patch"'),
            patch.index('freerdp_android_package.py" verify-patch'),
        )

    def test_owned_channels_use_exact_source_built_cli_before_android_build(self):
        steps = self.workflow["jobs"]["package"]["steps"]
        fixture = next(step for step in steps if step.get("name") ==
                       "Build exact owned FreeRDP channel fixture")
        native = next(step for step in steps if "assembleRelease" in step.get("run", ""))
        self.assertEqual(fixture["if"], "matrix.abi == 'x86_64'")
        self.assertLess(steps.index(fixture), steps.index(native))
        for required in (
            "f62_owned_shadow_channels.py prepare",
            '"$RUNNER_TEMP/freerdp-3.31.1.tar.gz"',
            '"$ANDROID_HOME/cmake/4.1.2/bin/cmake"',
            "f62_owned_shadow_channels.py build",
            "RDP_ACCEPTANCE_SHADOW_BINARY=",
            "RDP_ACCEPTANCE_SHADOW_SOURCE=",
            "server/shadow/cli/freerdp-shadow-cli",
        ):
            self.assertIn(required, fixture["run"])
        text = json.dumps(self.workflow)
        self.assertNotIn("freerdp3-shadow-x11", text)
        self.assertNotIn("freerdp-shadow-cli3", text)
        paths = self.workflow["on"]["pull_request"]["paths"]
        for required in (
            "android/freerdp-clipboard-utf8.patch",
            "tool/f62_owned_shadow_channels.py",
            "tool/patches/f62-owned-shadow-channels.patch",
        ):
            self.assertIn(required, paths)

    def test_fixture_failure_cannot_upload_missing_android_report_or_raw_log(self):
        steps = self.workflow["jobs"]["package"]["steps"]
        fixture = next(step for step in steps if step.get("name") ==
                       "Build exact owned FreeRDP channel fixture")
        acceptance = next(step for step in steps if step.get("name") ==
                          "Exercise the packaged Android client against the NLA host")
        native_failure = next(step for step in steps if step.get("name") ==
                              "Upload bounded native failure diagnostics")
        fixture_failure = next(step for step in steps if step.get("name") ==
                               "Upload bounded owned fixture build failure")
        self.assertEqual(fixture["id"], "owned_fixture")
        self.assertEqual(acceptance["id"], "packaged_acceptance")
        self.assertIn('--failure-receipt "$RUNNER_TEMP/freerdp-public-owned-fixture/failure.json"',
                      fixture["run"])
        self.assertIn("steps.owned_fixture.outcome == 'failure'", fixture_failure["if"])
        self.assertIn("steps.packaged_acceptance.outcome == 'failure'", native_failure["if"])
        self.assertEqual(fixture_failure["with"]["path"],
                         "${{ runner.temp }}/freerdp-public-owned-fixture/failure.json")
        self.assertIn("${{ github.sha }}", fixture_failure["with"]["name"])
        self.assertNotIn("f62-owned-shadow-build.log", json.dumps(fixture_failure))
        self.assertEqual(fixture_failure["with"]["if-no-files-found"], "warn")

    def test_xorg_preflight_directory_precedes_idempotent_package_copy(self):
        steps = self.workflow["jobs"]["package"]["steps"]
        preflight = next(
            step for step in steps
            if step.get("name") == "Preflight an owned resizable Xorg display"
        )
        receipt = next(
            step for step in steps
            if step.get("name") == "Create exact package receipt"
        )
        self.assertLess(steps.index(preflight), steps.index(receipt))
        preflight_mkdir = next(
            line for line in preflight["run"].splitlines()
            if line == 'mkdir -p "$RUNNER_TEMP/freerdp-package/acceptance"'
        )
        receipt_tail = receipt["run"].splitlines()[-3:]
        self.assertEqual(
            receipt_tail[0], 'mkdir -p "$RUNNER_TEMP/freerdp-package"',
        )
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            aar = root / "source.aar"
            receipt_json = root / "source.json"
            aar.write_bytes(b"aar")
            receipt_json.write_bytes(b"receipt")
            script = "\n".join((
                preflight_mkdir,
                f'aar="{aar}"',
                f'out="{receipt_json}"',
                *receipt_tail,
            ))
            subprocess.run(
                ["bash", "-ceu", script],
                env={**os.environ, "RUNNER_TEMP": temporary, "ABI": "x86_64"},
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            package = root / "freerdp-package"
            self.assertEqual(
                (package / "freeRDPCore-x86_64.aar").read_bytes(), b"aar",
            )
            self.assertEqual((package / "receipt.json").read_bytes(), b"receipt")

    def test_exact_reviewed_source_guard_runs_before_checkout_and_build(self):
        steps = self.workflow["jobs"]["package"]["steps"]
        guard = steps[0]["run"]
        for required in (
            "workflow_dispatch)", "pull_request)", "refs/heads/main",
            "refs/pull/*/merge", "ersingundem/larenor", "github-hosted",
            "$GITHUB_WORKFLOW_SHA\" = \"$GITHUB_SHA",
        ):
            self.assertIn(required, guard)
        upload = next(step for step in steps if step.get("uses", "").startswith("actions/upload-artifact@"))
        self.assertEqual(upload["with"]["if-no-files-found"], "error")
        self.assertIn("${{ github.sha }}", upload["with"]["name"])
        self.assertEqual(upload["if"], "matrix.abi == 'x86_64'")
        self.assertEqual(
            upload["with"]["path"],
            "${{ runner.temp }}/freerdp-public-acceptance/receipt.json",
        )
        self.assertNotIn("client-report.xml", json.dumps(upload))

    def test_x86_package_runs_real_owned_nla_host_acceptance(self):
        steps = self.workflow["jobs"]["package"]["steps"]
        preflight = next(
            step for step in steps
            if step.get("name") == "Preflight an owned resizable Xorg display"
        )
        host = next(step for step in steps if step.get("name") ==
                    "Prepare the owned NLA FreeRDP host")
        kvm = next(step for step in steps if step.get("name") ==
                   "Enable hosted KVM for packaged acceptance")
        client = next(step for step in steps if step.get("name") ==
                      "Exercise the packaged Android client against the NLA host")
        cleanup = next(step for step in steps if step.get("name") ==
                       "Stop the owned RDP host")
        self.assertEqual(kvm["if"], "matrix.abi == 'x86_64'")
        self.assertLess(steps.index(kvm), steps.index(client))
        native_build = next(
            step for step in steps if "assembleRelease" in step.get("run", "")
        )
        self.assertEqual(preflight["if"], "matrix.abi == 'x86_64'")
        self.assertLess(steps.index(preflight), steps.index(native_build))
        for required in (
            "apt-cache policy", "xserver-xorg-core",
            "xserver-xorg-video-dummy", 'xserver-xorg-core=$xorg_core_version',
            'xserver-xorg-video-dummy=$xorg_dummy_version', "dpkg-query",
            "/usr/lib/xorg/Xorg :99", "-nolisten tcp", 'Driver "dummy"',
            'Modeline "1280x800"', 'Modeline "1024x768"',
            "mapfile -t active_outputs", '${#active_outputs[@]}',
            'xrandr --output "$output" --mode 1024x768 --fb 1024x768',
            '/1024x768\\+0\\+0/',
            'xrandr --fb 1280x800 --output "$output" --mode 1280x800',
            "RDP_ACCEPTANCE_XORG_OUTPUT",
            "RDP_ACCEPTANCE_XORG_CORE_PACKAGE_VERSION",
            "RDP_ACCEPTANCE_XORG_DUMMY_PACKAGE_VERSION",
        ):
            self.assertIn(required, preflight["run"])
        self.assertNotIn("Xvfb", preflight["run"])
        for required in (
            "set -euo pipefail", "[ ! -c /dev/kvm ]",
            "sudo chmod 0666 /dev/kvm", "[ ! -r /dev/kvm ]",
            "[ ! -w /dev/kvm ]",
        ):
            self.assertIn(required, kvm["run"])
        self.assertEqual(host["if"], "matrix.abi == 'x86_64'")
        for required in (
            'kill -0 "$(cat "$RUNNER_TEMP/xorg.pid")"',
            "RDP_ACCEPTANCE_XORG_OUTPUT",
            "openssl rand", "::add-mask::", "winpr-hash3", "umask 077",
            'chmod 0600 "$RUNNER_TEMP/larenor-rdp.sam"',
            "xdpyinfo", "xmodmap -pke", '$2 == "38"',
        ):
            self.assertIn(required, host["run"])
        self.assertNotIn("shadow-cli", host["run"])
        self.assertNotIn("/dev/tcp", host["run"])
        self.assertEqual(client["if"], "matrix.abi == 'x86_64'")
        self.assertRegex(client["uses"],
                         r"^ReactiveCircus/android-emulator-runner@[0-9a-f]{40}$")
        self.assertEqual(client["with"]["emulator-boot-timeout"], 300)
        self.assertIs(client["with"]["disable-linux-hw-accel"], False)
        script = client["with"]["script"]
        self.assertEqual(script, "python3 tool/f62_packaged_acceptance.py")
        runner = (ROOT / "tool/f62_packaged_acceptance.py").read_text()
        self.assertIn("cwd=ROOT / \"android\"", runner)
        self.assertIn("materialized_gradle_command", runner)
        self.assertNotIn('"./gradlew"', runner)
        self.assertIn(":app:connectedDebugAndroidTest", runner)
        self.assertIn("RdpPackagedHostAcceptanceTest", runner)
        self.assertIn("Xi2KeyWitness", runner)
        self.assertIn('"/usr/bin/xinput", "test-xi2", "--root"', runner)
        self.assertIn('"RDP_ACCEPTANCE_XORG_OUTPUT"', runner)
        self.assertIn('"--output",', runner)
        self.assertIn('"--mode",', runner)
        self.assertIn('"ownedShadowChannels"', runner)
        self.assertIn('"enabledClientToRemoteClipboard"', runner)
        self.assertIn('"enabledDisplayControl"', runner)
        self.assertIn('"disabledClipboardTransfers"', runner)
        self.assertIn("rdpHost=10.0.2.2", runner)
        self.assertIn("rdpPassword={password}", runner)
        self.assertIn('"ownedHostPackages": package_versions', runner)
        self.assertIn('"sourceRevision": revision', runner)
        self.assertIn('"packageReceiptSha256": package_digest', runner)
        self.assertIn("source_revision(ROOT)", runner)
        self.assertIn("package_receipt_digest()", runner)
        self.assertNotIn("client-report.xml", runner)
        self.assertNotIn("shell=True", runner)
        self.assertLess(
            runner.index("report = verify_reports()"),
            runner.index("publish_public_receipt(", runner.index("report = verify_reports()")),
        )
        self.assertEqual(cleanup["if"], "always() && matrix.abi == 'x86_64'")
        self.assertIn("shadow xmessage xorg", cleanup["run"])
        self.assertNotIn("xvfb", cleanup["run"].lower())
        self.assertIn("rm -f \"$RUNNER_TEMP/larenor-rdp.sam\"", cleanup["run"])

    def test_shared_launcher_materializes_pinned_flutter_wrapper_and_fails_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            android = root / "android"
            properties = android / "gradle/wrapper/gradle-wrapper.properties"
            properties.parent.mkdir(parents=True)
            properties.write_text("distributionUrl=https\\://example.invalid/gradle.zip\n")
            flutter = root / "flutter/bin/flutter"
            java = root / "java"
            wrapper = (
                root
                / "flutter/bin/cache/artifacts/gradle_wrapper/gradle/wrapper/gradle-wrapper.jar"
            )
            flutter.parent.mkdir(parents=True)
            flutter.write_text("fixture")
            flutter.chmod(0o700)
            java.write_text("fixture")
            java.chmod(0o700)
            wrapper.parent.mkdir(parents=True)
            wrapper.write_bytes(b"pinned-flutter-wrapper")

            def resolved(name):
                return str(flutter if name == "flutter" else java)

            with mock.patch.object(
                acceptance_gradle, "_executable", side_effect=resolved
            ):
                command = acceptance_gradle.materialized_gradle_command(
                    root / "launcher", project_android=android
                )
            materialized = root / "launcher/gradle/wrapper"
            self.assertEqual(
                (materialized / "gradle-wrapper.jar").read_bytes(),
                b"pinned-flutter-wrapper",
            )
            self.assertEqual(command[-1], "org.gradle.wrapper.GradleWrapperMain")
            for name in ("gradle-wrapper.jar", "gradle-wrapper.properties"):
                self.assertEqual(
                    (materialized / name).stat().st_mode & 0o777,
                    0o600,
                )
            for directory in (
                root / "launcher",
                root / "launcher/gradle",
                materialized,
            ):
                self.assertEqual(directory.stat().st_mode & 0o777, 0o700)
            self.assertEqual(command[0], str(java.resolve()))

            wrapper.unlink()
            with mock.patch.object(
                acceptance_gradle, "_executable", side_effect=resolved
            ):
                with self.assertRaises(acceptance_gradle.AndroidAcceptanceGradleError):
                    acceptance_gradle.materialized_gradle_command(
                        root / "missing", project_android=android
                    )
            symlink_target = root / "symlink-target"
            symlink_target.write_bytes(b"untrusted-wrapper")
            wrapper.symlink_to(symlink_target)
            with mock.patch.object(
                acceptance_gradle, "_executable", side_effect=resolved
            ):
                with self.assertRaises(acceptance_gradle.AndroidAcceptanceGradleError):
                    acceptance_gradle.materialized_gradle_command(
                        root / "symlink", project_android=android
                    )

    def test_shared_launcher_rejects_relative_and_symlinked_boundaries(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            real = root / "real"
            android = real / "android"
            properties = android / "gradle/wrapper/gradle-wrapper.properties"
            properties.parent.mkdir(parents=True)
            properties.write_text("distributionUrl=https\\://example.invalid/gradle.zip\n")
            flutter = root / "flutter/bin/flutter"
            wrapper = (
                root
                / "flutter/bin/cache/artifacts/gradle_wrapper/gradle/wrapper/gradle-wrapper.jar"
            )
            java = root / "java"
            flutter.parent.mkdir(parents=True)
            flutter.write_text("fixture")
            flutter.chmod(0o700)
            wrapper.parent.mkdir(parents=True)
            wrapper.write_bytes(b"wrapper")
            java.write_text("fixture")
            java.chmod(0o700)

            def resolved(name):
                return str(flutter if name == "flutter" else java)

            with mock.patch.object(
                acceptance_gradle, "_executable", side_effect=resolved
            ):
                with self.assertRaises(acceptance_gradle.AndroidAcceptanceGradleError):
                    acceptance_gradle.materialized_gradle_command(
                        Path("relative-launcher"), project_android=android
                    )
                with self.assertRaises(acceptance_gradle.AndroidAcceptanceGradleError):
                    acceptance_gradle.materialized_gradle_command(
                        root / "relative-project-launcher",
                        project_android=Path("android"),
                    )

                project_alias = root / "project-alias"
                project_alias.symlink_to(real, target_is_directory=True)
                with self.assertRaises(acceptance_gradle.AndroidAcceptanceGradleError):
                    acceptance_gradle.materialized_gradle_command(
                        root / "symlink-project-launcher",
                        project_android=project_alias / "android",
                    )

                launcher_parent = root / "launcher-parent"
                launcher_parent.mkdir()
                launcher_alias = root / "launcher-alias"
                launcher_alias.symlink_to(launcher_parent, target_is_directory=True)
                with self.assertRaises(acceptance_gradle.AndroidAcceptanceGradleError):
                    acceptance_gradle.materialized_gradle_command(
                        launcher_alias / "launcher", project_android=android
                    )

                occupied = root / "occupied"
                occupied.mkdir()
                with self.assertRaises(acceptance_gradle.AndroidAcceptanceGradleError):
                    acceptance_gradle.materialized_gradle_command(
                        occupied, project_android=android
                    )

    def test_shared_launcher_destination_files_are_created_exclusively(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source = root / "source"
            destination = root / "destination"
            source.write_bytes(b"trusted")
            destination.write_bytes(b"attacker")
            with self.assertRaises(FileExistsError):
                acceptance_gradle._exclusive_copy(source, destination)
            self.assertEqual(destination.read_bytes(), b"attacker")


if __name__ == "__main__":
    unittest.main()
