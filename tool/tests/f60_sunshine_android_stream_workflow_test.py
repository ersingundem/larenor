from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = (ROOT / ".github/workflows/f60-sunshine-android-stream.yml").read_text(
    encoding="utf-8"
)
SERVER_WORKFLOW = (ROOT / ".github/workflows/server-test.yml").read_text(
    encoding="utf-8"
)
_GUARD_STEP = WORKFLOW.split(
    "      - name: Require exact reviewed GitHub-hosted source\n", 1
)[1].split("\n      - name:", 1)[0]
GUARD_SCRIPT = textwrap.dedent(_GUARD_STEP.split("        run: |\n", 1)[1])
_KVM_STEP = WORKFLOW.split(
    "      - name: Enable hosted KVM for owned stream\n", 1
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


class F60SunshineAndroidStreamWorkflowTest(unittest.TestCase):
    def _guard(self, **changes: str) -> subprocess.CompletedProcess[str]:
        reference = "refs/heads/codex/project-completion-100"
        environment = {
            "CALLER_CONTRACT": "",
            "GITHUB_EVENT_NAME": "workflow_dispatch",
            "GITHUB_REF": reference,
            "GITHUB_REPOSITORY": "ersingundem/larenor",
            "GITHUB_SHA": "a" * 40,
            "GITHUB_WORKFLOW_REF": (
                "ersingundem/larenor/.github/workflows/"
                "f60-sunshine-android-stream.yml@" + reference
            ),
            "GITHUB_WORKFLOW_SHA": "a" * 40,
            "PR_HEAD_REPOSITORY": "",
            "RUNNER_ENVIRONMENT": "github-hosted",
            "RUNNER_TEMP": "/tmp/f60-stream-workflow-test",
        }
        environment.update(changes)
        return subprocess.run(
            ["/bin/bash", "-e", "-o", "pipefail", "-c", GUARD_SCRIPT],
            env=environment,
            text=True,
            capture_output=True,
            check=False,
        )

    def _kvm(self, mode: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", "-e", "-o", "pipefail", "-c", KVM_HARNESS + KVM_SCRIPT],
            env=dict(os.environ, KVM_MODE=mode),
            text=True,
            capture_output=True,
            check=False,
        )

    def test_source_guard_accepts_only_direct_or_exact_registered_caller(self) -> None:
        self.assertEqual(0, self._guard().returncode)
        reference = "refs/heads/codex/project-completion-100"
        called = self._guard(
            CALLER_CONTRACT="f60-owned-stream-v1",
            GITHUB_WORKFLOW_REF=(
                "ersingundem/larenor/.github/workflows/server-test.yml@" + reference
            ),
        )
        self.assertEqual(0, called.returncode, called.stderr)
        for changes in (
            {"CALLER_CONTRACT": "wrong"},
            {"GITHUB_REF": "refs/heads/unreviewed"},
            {"GITHUB_WORKFLOW_SHA": "b" * 40},
            {"RUNNER_ENVIRONMENT": "self-hosted"},
            {"PR_HEAD_REPOSITORY": "foreign/repository"},
        ):
            with self.subTest(changes=changes):
                self.assertNotEqual(0, self._guard(**changes).returncode)

    def test_workflow_is_real_stream_gate_with_pinned_surfaces(self) -> None:
        self.assertIn("runs-on: ubuntu-24.04", WORKFLOW)
        self.assertIn("moonlight-android.git", WORKFLOW)
        self.assertIn("b48494cb96bff23d8886c4775cc4f39a1075495d", WORKFLOW)
        self.assertIn(
            "script: python3 -B -m tool.f60_sunshine_android_stream",
            WORKFLOW,
        )
        self.assertNotIn(
            "script: python3 -B tool/f60_sunshine_android_stream.py",
            WORKFLOW,
        )
        self.assertIn("stream and local retirement lifecycle", WORKFLOW)
        self.assertIn("f60-sunshine-android-stream-receipt.json", WORKFLOW)
        self.assertIn("x11-apps", WORKFLOW)
        self.assertIn("xinput", WORKFLOW)
        self.assertIn("packages=(acl ", WORKFLOW)
        self.assertIn("pulseaudio-utils", WORKFLOW)
        self.assertNotIn("continue-on-error", WORKFLOW)
        self.assertNotIn("-noaudio", WORKFLOW)
        self.assertIn("-gpu swiftshader", WORKFLOW)
        self.assertNotIn("swiftshader_indirect", WORKFLOW)
        self.assertIn("disable-linux-hw-accel: false", WORKFLOW)
        self.assertNotIn("-accel off", WORKFLOW)
        self.assertNotIn("uses: ./.github/workflows/f60-sunshine-owned-host.yml", WORKFLOW)

    def test_hosted_uhid_preflight_is_before_engine_build_and_runtime_acl_window(self) -> None:
        preflight = "      - name: Require exact hosted UHID capability\n"
        engine = "      - name: Build and install exact receipted Moonlight engine\n"
        run = "      - name: Run real owned Sunshine stream and local retirement lifecycle\n"
        self.assertLess(WORKFLOW.index(preflight), WORKFLOW.index(engine))
        self.assertLess(WORKFLOW.index(engine), WORKFLOW.index(run))
        section = WORKFLOW.split(preflight, 1)[1].split("\n      - name:", 1)[0]
        self.assertIn("python3 -B -m tool.f60_owned_gamepad preflight", section)
        self.assertNotIn("chmod 666 /dev/uhid", WORKFLOW)
        self.assertNotIn("chgrp", WORKFLOW)

    def test_kvm_preflight_blocks_missing_or_inaccessible_device(self) -> None:
        self.assertEqual(0, self._kvm("ready").returncode)
        missing = self._kvm("absent")
        self.assertNotEqual(0, missing.returncode)
        self.assertIn("no KVM character device", missing.stdout)
        inaccessible = self._kvm("inaccessible")
        self.assertNotEqual(0, inaccessible.returncode)
        self.assertIn("cannot access KVM", inaccessible.stdout)

    def test_registered_dispatcher_is_exact_and_not_a_required_server_gate(self) -> None:
        self.assertIn("          - f60-stream", SERVER_WORKFLOW)
        self.assertIn(
            "if: github.event_name == 'workflow_dispatch' && inputs.scope == 'f60-stream'",
            SERVER_WORKFLOW,
        )
        self.assertIn(
            "uses: ./.github/workflows/f60-sunshine-android-stream.yml",
            SERVER_WORKFLOW,
        )
        self.assertIn("caller_contract: f60-owned-stream-v1", SERVER_WORKFLOW)
        aggregate = SERVER_WORKFLOW.split("  server-test:\n", 1)[1]
        self.assertIn("inputs.scope == 'all'", aggregate)
        self.assertNotIn("f60-sunshine-android-stream", aggregate)

    def test_workflow_never_uploads_raw_reports_provider_logs_or_private_material(self) -> None:
        upload = WORKFLOW.split("      - name: Upload bounded stream receipt\n", 1)[1]
        self.assertIn(
            "path: ${{ runner.temp }}/f60-sunshine-android-stream-receipt.json",
            upload,
        )
        for forbidden in (
            "androidTest-results",
            "sunshine.log",
            "sunshine-cert",
            "sunshine-key",
            "web-credentials",
        ):
            self.assertNotIn(forbidden, upload)

    def test_strict_support_cleanup_precedes_receipt_and_fallback_is_failure_only(self) -> None:
        strict_name = "      - name: Stop owned host support service before receipt\n"
        upload_name = "      - name: Upload bounded stream receipt\n"
        fallback_name = (
            "      - name: Best-effort stop owned host support service after failure\n"
        )
        self.assertLess(WORKFLOW.index(strict_name), WORKFLOW.index(upload_name))
        self.assertLess(WORKFLOW.index(upload_name), WORKFLOW.index(fallback_name))
        strict = WORKFLOW.split(strict_name, 1)[1].split("\n      - name:", 1)[0]
        self.assertIn("sudo systemctl stop avahi-daemon", strict)
        self.assertIn('test "$status" -eq 3', strict)
        self.assertIn('test "$state" = inactive', strict)
        self.assertNotIn("|| true", strict)
        fallback = WORKFLOW.split(fallback_name, 1)[1]
        self.assertIn("if: failure() || cancelled()", fallback)
        self.assertIn("sudo systemctl stop avahi-daemon || true", fallback)


if __name__ == "__main__":
    unittest.main()
