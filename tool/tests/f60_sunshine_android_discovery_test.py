from __future__ import annotations

import hashlib
import json
import tempfile
from pathlib import Path
import os
import subprocess
import textwrap
import unittest
from unittest import mock

from tool import f60_sunshine_android_discovery as discovery
from tool.f60_sunshine_android_discovery import (
    DiscoveryAcceptanceFailure,
    TEST_CLASS,
    TEST_NAME,
    package_identity,
    emulator_version,
    parse_emulator_version,
    verify_report,
)


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = (
    ROOT / ".github/workflows/f60-sunshine-android-discovery.yml"
).read_text(encoding="utf-8")
SERVER_WORKFLOW = (ROOT / ".github/workflows/server-test.yml").read_text(
    encoding="utf-8"
)
_GUARD_STEP = WORKFLOW.split(
    "      - name: Require exact reviewed GitHub-hosted source\n", 1
)[1].split("\n      - name:", 1)[0]
GUARD_SCRIPT = textwrap.dedent(_GUARD_STEP.split("        run: |\n", 1)[1])
_KVM_STEP = WORKFLOW.split(
    "      - name: Enable hosted KVM for owned discovery\n", 1
)[1].split("\n      - name:", 1)[0]
KVM_SCRIPT = textwrap.dedent(_KVM_STEP.split("        run: |\n", 1)[1])
KVM_HARNESS = r'''
function [ {
  case "$*" in
    '! -c /dev/kvm ]') builtin test "$KVM_MODE" = absent ;;
    '! -r /dev/kvm ]'|'! -w /dev/kvm ]') builtin test "$kvm_ready" != yes ;;
    *) exit 97 ;;
  esac
}
sudo() {
  builtin test "$*" = 'chmod 0666 /dev/kvm' || exit 98
  if builtin test "$KVM_MODE" != inaccessible; then kvm_ready=yes; fi
  return 0
}
ls() { echo 'synthetic device metadata'; }
kvm_ready=no
'''


class SunshineAndroidDiscoveryReportTest(unittest.TestCase):
    def test_discovery_prebuild_failure_never_starts_provider(self) -> None:
        prebuild = discovery.prebuild_android_test
        run = mock.Mock(return_value=mock.Mock(returncode=1))
        with tempfile.TemporaryDirectory() as temporary, \
                mock.patch.dict(os.environ, {"RUNNER_TEMP": temporary}), \
                mock.patch.object(discovery, "REPORTS", Path(temporary) / "reports"), \
                mock.patch.object(discovery, "emulator_version", return_value="37.1.11.0"), \
                mock.patch.object(discovery, "package_identity", return_value={}), \
                mock.patch.object(discovery, "materialized_gradle_command", return_value=["gradlew"]), \
                mock.patch.object(discovery, "prebuild_android_test", side_effect=lambda gradle: prebuild(gradle, runner=run)), \
                mock.patch.object(discovery.OwnedSunshineHost, "start") as start:
            with self.assertRaisesRegex(DiscoveryAcceptanceFailure, "prebuild failed"):
                discovery.main()
            start.assert_not_called()
            args, options = run.call_args
            self.assertEqual(["gradlew", "--no-daemon", ":app:assembleDebug", ":app:assembleDebugAndroidTest"], args[0])
            self.assertNotIn("-x", args[0])
            self.assertEqual(1200, options["timeout"])

    def test_discovery_prebuild_finishes_before_provider_deadline(self) -> None:
        order = []
        with tempfile.TemporaryDirectory() as temporary, \
                mock.patch.dict(os.environ, {"RUNNER_TEMP": temporary}), \
                mock.patch.object(discovery, "REPORTS", Path(temporary) / "reports"), \
                mock.patch.object(discovery, "emulator_version", return_value="37.1.11.0"), \
                mock.patch.object(discovery, "package_identity", return_value={}), \
                mock.patch.object(discovery, "materialized_gradle_command", return_value=["gradlew"]), \
                mock.patch.object(discovery, "prebuild_android_test", side_effect=lambda _gradle: order.append("prebuild")), \
                mock.patch.object(discovery.OwnedSunshineHost, "start", side_effect=lambda: (
                    order.append("provider"), (_ for _ in ()).throw(DiscoveryAcceptanceFailure("stop"))
                )[1]):
            with self.assertRaises(DiscoveryAcceptanceFailure):
                discovery.main()
        self.assertEqual(["prebuild", "provider"], order)

    def _run_workflow_guard(self, **changes: str) -> subprocess.CompletedProcess[str]:
        reference = "refs/heads/codex/project-completion-100"
        values = {
            "CALLER_CONTRACT": "f60-owned-discovery-v1",
            "GITHUB_EVENT_NAME": "workflow_dispatch",
            "GITHUB_REF": reference,
            "GITHUB_REPOSITORY": "ersingundem/larenor",
            "GITHUB_SHA": "a" * 40,
            "GITHUB_WORKFLOW_REF": (
                "ersingundem/larenor/.github/workflows/server-test.yml@" + reference
            ),
            "GITHUB_WORKFLOW_SHA": "a" * 40,
            "PR_HEAD_REPOSITORY": "",
            "RUNNER_ENVIRONMENT": "github-hosted",
            "RUNNER_TEMP": "/tmp/f60-discovery-test",
        }
        values.update(changes)
        return subprocess.run(
            ["/bin/bash", "-e", "-o", "pipefail", "-c", GUARD_SCRIPT],
            env=values,
            text=True,
            capture_output=True,
            check=False,
        )

    def _report(self, root: Path, *, body: str = "") -> None:
        (root / "TEST-owned.xml").write_text(
            '<testsuite tests="1" failures="0" errors="0" skipped="0">'
            f'<testcase classname="{TEST_CLASS}" name="{TEST_NAME}">{body}</testcase>'
            "</testsuite>",
            encoding="utf-8",
        )

    def _run_kvm(self, mode: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", "-e", "-o", "pipefail", "-c", KVM_HARNESS + KVM_SCRIPT],
            env=dict(os.environ, KVM_MODE=mode),
            text=True,
            capture_output=True,
            check=False,
        )

    def test_accepts_one_exact_completed_test(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self._report(root)
            self.assertEqual(1, verify_report(root)["tests"])

    def test_actual_ddmlib_aggregate_preserves_exact_single_test_proof(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self._report(root)
            report = root / "TEST-owned.xml"
            child = report.read_text()
            wrapper = '<testsuites tests="1" failures="0" errors="0" skipped="0">'
            report.write_text(wrapper + child + '</testsuites>')
            self.assertEqual(1, verify_report(root)["tests"])
            for outer, body in (
                (wrapper.replace('tests="1"', 'tests="2"'), child),
                (wrapper, child.replace('skipped="0"', 'skipped="1"')),
                (wrapper, child + child),
                (wrapper, child + '<testcase classname="other" name="other"/>'),
                (wrapper, child.replace('</testcase>', '<error/></testcase>')),
            ):
                with self.subTest(outer=outer, body=body):
                    report.write_text(outer + body + '</testsuites>')
                    with self.assertRaises(DiscoveryAcceptanceFailure):
                        verify_report(root)

    def test_rejects_skip_failure_and_duplicate(self) -> None:
        for body in ('<skipped message="opt-in absent"/>', '<failure message="missing"/>'):
            with self.subTest(body=body), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                self._report(root, body=body)
                with self.assertRaises(DiscoveryAcceptanceFailure):
                    verify_report(root)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self._report(root)
            (root / "nested").mkdir()
            self._report(root / "nested")
            with self.assertRaises(DiscoveryAcceptanceFailure):
                verify_report(root)

    def test_rejects_mismatched_aggregate_unrelated_and_symlink_reports(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "TEST-owned.xml").write_text(
                '<testsuite tests="2" failures="0" errors="0" skipped="0">'
                f'<testcase classname="{TEST_CLASS}" name="{TEST_NAME}"/>'
                "</testsuite>",
                encoding="utf-8",
            )
            with self.assertRaises(DiscoveryAcceptanceFailure):
                verify_report(root)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "TEST-nested.xml").write_text(
                '<testsuite tests="1" failures="0" errors="0" skipped="0">'
                f'<testcase classname="{TEST_CLASS}" name="{TEST_NAME}"/>'
                '<testsuite tests="0" failures="0" errors="0" skipped="0"/>'
                "</testsuite>",
                encoding="utf-8",
            )
            with self.assertRaises(DiscoveryAcceptanceFailure):
                verify_report(root)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "TEST-other.xml").write_text(
                '<testsuite tests="1" failures="0" errors="0" skipped="0">'
                '<testcase classname="other" name="other"/></testsuite>',
                encoding="utf-8",
            )
            with self.assertRaises(DiscoveryAcceptanceFailure):
                verify_report(root)

    def test_package_identity_binds_actual_aar_and_pinned_source(self) -> None:
        lock = discovery.load_lock()
        self.assertEqual(
            "moonlight-android-12.2-larenor-embed-v5",
            lock["engineRevision"],
        )
        self.assertEqual(
            "b48494cb96bff23d8886c4775cc4f39a1075495d",
            lock["upstream"]["commit"],
        )
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            aar = root / "engine.aar"
            receipt = root / "receipt.json"
            aar.write_bytes(b"exact packaged engine")
            expected_digest = hashlib.sha256(aar.read_bytes()).hexdigest()
            value = {
                "aarSha256": expected_digest,
                "classesSha256": "b" * 64,
                "engineRevision": "moonlight-android-12.2-larenor-embed-v5",
                "sourceCommit": "b48494cb96bff23d8886c4775cc4f39a1075495d",
                "sourceTree": "c" * 40,
            }
            receipt.write_text(json.dumps(value), encoding="utf-8")
            self.assertEqual(expected_digest, package_identity(aar, receipt)["aarSha256"])
            # The same AAR hash cannot make a receipt from the previous
            # native engine satisfy the current runtime gate.
            value["engineRevision"] = "moonlight-android-12.2-larenor-embed-v4"
            receipt.write_text(json.dumps(value), encoding="utf-8")
            with self.assertRaises(DiscoveryAcceptanceFailure):
                package_identity(aar, receipt)
            value["engineRevision"] = "moonlight-android-12.2-larenor-embed-v5"
            value["aarSha256"] = "d" * 64
            receipt.write_text(json.dumps(value), encoding="utf-8")
            with self.assertRaises(DiscoveryAcceptanceFailure):
                package_identity(aar, receipt)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = root / "owned.xml"
            self._report(root)
            (root / "TEST-owned.xml").rename(target)
            os.symlink(target.name, root / "TEST-link.xml")
            with self.assertRaises(DiscoveryAcceptanceFailure):
                verify_report(root)

    def test_emulator_version_requires_36_5_and_accepts_future_major(self) -> None:
        self.assertEqual(
            "36.5.10.0",
            parse_emulator_version("Android emulator version 36.5.10.0 (build_id 1)"),
        )
        self.assertEqual(
            "37.0.0",
            parse_emulator_version("Android emulator version 37.0.0"),
        )
        for output in (
            "Android emulator version 36.4.99.0",
            "Android emulator version unavailable",
        ):
            with self.subTest(output=output), self.assertRaises(
                DiscoveryAcceptanceFailure
            ):
                parse_emulator_version(output)

    def test_version_uses_actual_sdk_executable_when_emulator_is_absent_from_path(self) -> None:
        with tempfile.TemporaryDirectory(prefix="sdk with spaces ") as temporary:
            sdk = Path(temporary)
            executable = sdk / "emulator" / "emulator"
            executable.parent.mkdir()
            executable.write_text(
                '#!/bin/sh\n'
                'test "$1" = -version || exit 91\n'
                'test "$ANDROID_HOME" = "$ANDROID_SDK_ROOT" || exit 92\n'
                'test -z "$F60_PRIVATE_SENTINEL" || exit 93\n'
                'echo "Android emulator version 37.1.11.0"\n',
                encoding="utf-8",
            )
            executable.chmod(0o700)
            for sdk_key in ("ANDROID_HOME", "ANDROID_SDK_ROOT"):
                with self.subTest(sdk_key=sdk_key), mock.patch.dict(
                    os.environ,
                    {sdk_key: str(sdk), "PATH": "/usr/bin:/bin", "F60_PRIVATE_SENTINEL": "private"},
                    clear=True,
                ):
                    self.assertEqual("37.1.11.0", emulator_version())

    def test_version_rejects_conflicting_sdk_roots_and_missing_configured_binary(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for environment in (
                {"ANDROID_HOME": str(root), "ANDROID_SDK_ROOT": str(root / "other")},
                {"ANDROID_HOME": str(root)},
                {"ANDROID_HOME": "relative-sdk"},
            ):
                with self.subTest(environment=environment), mock.patch.dict(
                    os.environ, {**environment, "PATH": "/usr/bin:/bin"}, clear=True,
                ), mock.patch("tool.f60_sunshine_android_discovery.shutil.which") as which:
                    with self.assertRaises(DiscoveryAcceptanceFailure):
                        emulator_version()
                    which.assert_not_called()

    def test_version_resolves_path_only_without_a_configured_sdk(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            executable = Path(temporary) / "emulator"
            executable.write_text(
                '#!/bin/sh\necho "Android emulator version 36.5.10.0"\n',
                encoding="utf-8",
            )
            executable.chmod(0o700)
            with mock.patch.dict(os.environ, {"PATH": temporary}, clear=True):
                self.assertEqual("36.5.10.0", emulator_version())
            executable.unlink()
            with mock.patch.dict(os.environ, {"PATH": temporary}, clear=True):
                with self.assertRaises(DiscoveryAcceptanceFailure):
                    emulator_version()

    def test_workflow_uses_supported_software_renderer_for_modern_emulator(self) -> None:
        self.assertIn("-gpu swiftshader", WORKFLOW)
        self.assertNotIn("swiftshader_indirect", WORKFLOW)
        self.assertIn("disable-linux-hw-accel: false", WORKFLOW)

    def test_workflow_runs_discovery_as_repo_root_python_module(self) -> None:
        self.assertIn(
            "script: python3 -B -m tool.f60_sunshine_android_discovery",
            WORKFLOW,
        )
        self.assertNotIn(
            "script: python3 -B tool/f60_sunshine_android_discovery.py",
            WORKFLOW,
        )

    def test_workflow_requires_accessible_host_kvm_without_software_fallback(self) -> None:
        self.assertEqual(0, self._run_kvm("ready").returncode)
        missing = self._run_kvm("absent")
        self.assertNotEqual(0, missing.returncode)
        self.assertIn("no KVM character device", missing.stdout)
        inaccessible = self._run_kvm("inaccessible")
        self.assertNotEqual(0, inaccessible.returncode)
        self.assertIn("cannot access KVM", inaccessible.stdout)
        self.assertNotIn("-accel off", WORKFLOW)

    def test_workflow_leaves_package_work_directory_absent_for_builder(self) -> None:
        self.assertIn(
            'mkdir "$RUNNER_TEMP/moonlight-package" android/app/moonlight',
            WORKFLOW,
        )
        self.assertNotIn('mkdir "$RUNNER_TEMP/moonlight-build"', WORKFLOW)
        self.assertIn(
            '"$RUNNER_TEMP/moonlight-source" "$RUNNER_TEMP/moonlight-build"',
            WORKFLOW,
        )

    def test_registered_dispatcher_and_source_guard_are_exact(self) -> None:
        self.assertIn("          - f60-discovery", SERVER_WORKFLOW)
        self.assertIn(
            "uses: ./.github/workflows/f60-sunshine-android-discovery.yml",
            SERVER_WORKFLOW,
        )
        self.assertIn("caller_contract: f60-owned-discovery-v1", SERVER_WORKFLOW)
        accepted = self._run_workflow_guard()
        self.assertEqual(0, accepted.returncode, accepted.stderr)
        for changes in (
            {"CALLER_CONTRACT": "wrong"},
            {"GITHUB_WORKFLOW_REF": "ersingundem/larenor/.github/workflows/other.yml@refs/heads/codex/project-completion-100"},
            {"GITHUB_REF": "refs/heads/unreviewed"},
            {"GITHUB_WORKFLOW_SHA": "b" * 40},
            {"RUNNER_ENVIRONMENT": "self-hosted"},
        ):
            with self.subTest(changes=changes):
                self.assertNotEqual(0, self._run_workflow_guard(**changes).returncode)


if __name__ == "__main__":
    unittest.main()
