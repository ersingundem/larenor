import json
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest
from unittest import mock

from tool import f60_sunshine_startup_probe as probe


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = (ROOT / ".github/workflows/f60-sunshine-startup-probe.yml").read_text()
SERVER_WORKFLOW = (ROOT / ".github/workflows/server-test.yml").read_text()
_GUARD_STEP = WORKFLOW.split(
    "      - name: Require exact reviewed GitHub-hosted source\n", 1,
)[1].split("\n      - name:", 1)[0]
GUARD_SCRIPT = textwrap.dedent(_GUARD_STEP.split("        run: |\n", 1)[1])


class _OwnedHost:
    def __init__(self) -> None:
        self.closed = False

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.closed = True

    def public_readiness(self):
        return {
            "schemaVersion": 1,
            "provider": "Sunshine",
            "providerTag": probe.SUNSHINE_TAG,
            "packageSha256": probe.SUNSHINE_SHA256,
            "platform": "ubuntu24.04-amd64",
            "capture": "x11",
            "encoder": "software",
            "codec": "h264",
            "tlsCertificateSha256": "a" * 64,
            "mdns": {"service": "_nvstream._tcp", "port": 47989},
            "state": "host_ready",
            "streamAccepted": False,
        }


class _CleanupFailureHost(_OwnedHost):
    def __exit__(self, *_):
        self.closed = True
        raise probe.HostFailure("owned host process cleanup failed")


class F60SunshineStartupProbeTest(unittest.TestCase):
    def _run_guard(self, **changes):
        reference = "refs/heads/codex/project-completion-100"
        values = {
            "CALLER_CONTRACT": "",
            "GITHUB_ENV": "",
            "GITHUB_EVENT_NAME": "workflow_dispatch",
            "GITHUB_REF": reference,
            "GITHUB_REPOSITORY": "ersingundem/larenor",
            "GITHUB_SHA": "a" * 40,
            "GITHUB_WORKFLOW_REF": (
                "ersingundem/larenor/.github/workflows/"
                f"f60-sunshine-startup-probe.yml@{reference}"
            ),
            "GITHUB_WORKFLOW_SHA": "a" * 40,
            "PR_HEAD_REPOSITORY": "",
            "RUNNER_ENVIRONMENT": "github-hosted",
            "RUNNER_TEMP": "",
        }
        values.update(changes)
        with tempfile.TemporaryDirectory() as temporary:
            values["RUNNER_TEMP"] = values["RUNNER_TEMP"] or temporary
            values["GITHUB_ENV"] = values["GITHUB_ENV"] or str(
                Path(temporary) / "github-env"
            )
            return subprocess.run(
                ["/bin/bash", "-e", "-o", "pipefail", "-c", GUARD_SCRIPT],
                env=values,
                text=True,
                capture_output=True,
                check=False,
            )

    def test_ready_probe_uses_actual_stream_profile_and_never_accepts_feature(self):
        owned = _OwnedHost()
        environment = {"RUNNER_TEMP": "/private/runner"}
        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(
            probe.OwnedSunshineHost, "start", return_value=owned,
        ) as start, mock.patch.object(
            probe, "source_revision", return_value="b" * 40,
        ):
            destination = Path(temporary) / probe.RECEIPT_NAME
            probe.run_probe(destination, environment=environment)
            receipt = json.loads(destination.read_text())
        start.assert_called_once_with(environment=environment, stream_profile=True)
        self.assertTrue(owned.closed)
        self.assertEqual("ready", receipt["result"])
        self.assertEqual("host_ready", receipt["startup"]["state"])
        self.assertIsNone(receipt["counts"])
        self.assertIs(receipt["streamAccepted"], False)
        self.assertIs(receipt["featureAccepted"], False)
        self.assertNotIn("namedTest", receipt)

    def test_cleanup_failure_cannot_publish_ready_receipt(self):
        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(
            probe.OwnedSunshineHost, "start", return_value=_CleanupFailureHost(),
        ), mock.patch.object(probe, "source_revision", return_value="b" * 40):
            destination = Path(temporary) / probe.RECEIPT_NAME
            with self.assertRaisesRegex(probe.HostFailure, "cleanup failed"):
                probe.run_probe(destination, environment={})
            self.assertFalse(destination.exists())

    def test_failed_probe_keeps_closed_startup_facts_without_android_counts(self):
        observation = {
            "stage": "apiReadiness",
            "process": "sunshine",
            "poll": "exited",
            "exit": "nonzero",
            "knownCode": "encoderUnavailable",
            "privateLogs": "preserved",
        }
        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(
            probe.OwnedSunshineHost,
            "start",
            side_effect=probe.HostStartupFailure(observation),
        ), mock.patch.object(probe, "source_revision", return_value="c" * 40):
            destination = Path(temporary) / probe.RECEIPT_NAME
            with self.assertRaisesRegex(
                probe.StartupProbeFailure,
                "owned Sunshine stream-profile startup failed",
            ):
                probe.run_probe(destination, environment={})
            receipt = json.loads(destination.read_text())
        self.assertEqual("failed", receipt["result"])
        self.assertEqual(observation, receipt["startup"])
        self.assertIsNone(receipt["counts"])
        self.assertIs(receipt["featureAccepted"], False)
        self.assertNotIn("namedTest", receipt)
        self.assertNotIn("android", json.dumps(receipt).lower())

    def test_failure_observation_rejects_injection_and_impossible_combinations(self):
        valid = {
            "stage": "apiReadiness",
            "process": "sunshine",
            "poll": "exited",
            "exit": "signal",
            "knownCode": "unclassified",
            "privateLogs": "unavailable",
        }
        probe._validate_startup_failure(valid)
        for value in (
            {**valid, "knownCode": "raw provider text"},
            {**valid, "endpoint": "127.0.0.1"},
            {**valid, "poll": "running", "exit": "signal"},
            {**valid, "process": "none"},
            {**valid, "privateLogs": "/private/log"},
        ):
            with self.subTest(value=value), self.assertRaises(probe.StartupProbeFailure):
                probe._validate_startup_failure(value)

    def test_receipt_is_exclusive_and_does_not_replace_foreign_symlink(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            foreign = root / "foreign"
            foreign.write_text("unchanged", encoding="utf-8")
            destination = root / probe.RECEIPT_NAME
            destination.symlink_to(foreign)
            with self.assertRaises(FileExistsError):
                probe._write_receipt(destination, {"schemaVersion": 1})
            self.assertEqual("unchanged", foreign.read_text())

    def test_readiness_deadline_keeps_running_process_nonacceptance_receipt(self):
        observation = {
            "stage": "apiReadiness", "process": "sunshine", "poll": "running",
            "exit": "unavailable", "knownCode": "unclassified",
            "privateLogs": "preserved",
        }
        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(
            probe.OwnedSunshineHost, "start",
            side_effect=probe.HostStartupFailure(observation),
        ), mock.patch.object(probe, "source_revision", return_value="c" * 40):
            destination = Path(temporary) / probe.RECEIPT_NAME
            with self.assertRaises(probe.StartupProbeFailure):
                probe.run_probe(destination, environment={})
            receipt = json.loads(destination.read_text())
        self.assertEqual(observation, receipt["startup"])
        self.assertIs(receipt["featureAccepted"], False)
        self.assertIsNone(receipt["counts"])

    def test_registered_scope_reuses_stream_host_prerequisites_without_android(self):
        self.assertIn("          - f60-startup-probe", SERVER_WORKFLOW)
        self.assertIn(
            "if: github.event_name == 'workflow_dispatch' && inputs.scope == 'f60-startup-probe'",
            SERVER_WORKFLOW,
        )
        self.assertIn(
            "uses: ./.github/workflows/f60-sunshine-startup-probe.yml",
            SERVER_WORKFLOW,
        )
        self.assertIn("caller_contract: f60-owned-startup-probe-v1", SERVER_WORKFLOW)
        self.assertIn(
            "packages=(acl avahi-daemon avahi-utils openssl pulseaudio "
            "pulseaudio-utils x11-apps x11-utils x11-xserver-utils xinput xvfb)",
            WORKFLOW,
        )
        self.assertIn("tool.f60_sunshine_startup_probe", WORKFLOW)
        for forbidden in (
            "setup-java", "setup-android", "flutter-action", "android-emulator-runner",
            "moonlight_android_package", "/dev/kvm", "f60_owned_gamepad",
        ):
            self.assertNotIn(forbidden, WORKFLOW)
        aggregate = SERVER_WORKFLOW.split("  server-test:\n", 1)[1]
        self.assertNotIn("f60-sunshine-startup-probe", aggregate)

    def test_source_guard_accepts_only_manual_or_registered_dispatcher(self):
        self.assertEqual(0, self._run_guard().returncode)
        reference = "refs/heads/codex/project-completion-100"
        dispatched = self._run_guard(
            CALLER_CONTRACT="f60-owned-startup-probe-v1",
            GITHUB_WORKFLOW_REF=(
                "ersingundem/larenor/.github/workflows/server-test.yml@" + reference
            ),
        )
        self.assertEqual(0, dispatched.returncode, dispatched.stderr)
        for changes in (
            {
                "CALLER_CONTRACT": "wrong",
                "GITHUB_WORKFLOW_REF": (
                    "ersingundem/larenor/.github/workflows/server-test.yml@" + reference
                ),
            },
            {"GITHUB_REF": "refs/heads/unreviewed"},
            {"GITHUB_WORKFLOW_SHA": "d" * 40},
        ):
            with self.subTest(changes=changes):
                self.assertNotEqual(0, self._run_guard(**changes).returncode)


if __name__ == "__main__":
    unittest.main()
