import json
from pathlib import Path
import re
import tempfile
import unittest

from tool import f61_tigervnc_acceptance as runner


ROOT = Path(__file__).resolve().parents[2]


class VncNativeWorkflowTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow_path = ROOT / ".github/workflows/vnc-native-acceptance.yml"
        cls.workflow = json.loads(cls.workflow_path.read_text())
        cls.runner = (ROOT / "tool/f61_tigervnc_acceptance.py").read_text()

    def test_closed_reviewed_execution_and_commit_pinned_actions(self):
        self.assertEqual(self.workflow["on"]["workflow_dispatch"], {})
        self.assertEqual(self.workflow["on"]["pull_request"]["branches"], ["main"])
        self.assertEqual(self.workflow["permissions"], {"contents": "read"})
        job = self.workflow["jobs"]["tigervnc"]
        self.assertEqual(job["runs-on"], "ubuntu-24.04")
        self.assertEqual(job["timeout-minutes"], 30)
        guard = job["steps"][0]["run"]
        for required in (
            "workflow_dispatch)",
            "pull_request)",
            "refs/heads/main",
            "refs/pull/*/merge",
            "ersingundem/larenor",
            "github-hosted",
            '$GITHUB_WORKFLOW_SHA\" = \"$GITHUB_SHA',
        ):
            self.assertIn(required, guard)
        for step in job["steps"]:
            if "uses" not in step:
                continue
            self.assertRegex(
                step["uses"],
                r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[0-9a-f]{40}$",
            )
            if step["uses"].startswith("actions/checkout@"):
                self.assertEqual(step["with"]["ref"], "${{ github.sha }}")
                self.assertIs(step["with"]["persist-credentials"], False)

    def test_workflow_installs_recorded_official_server_and_runs_one_owned_gate(self):
        steps = self.workflow["jobs"]["tigervnc"]["steps"]
        install = next(step["run"] for step in steps if "tigervnc-standalone-server" in step.get("run", ""))
        run = next(step["run"] for step in steps if "f61_tigervnc_acceptance.py" in step.get("run", ""))
        for required in (
            "apt-cache policy tigervnc-standalone-server",
            "tigervnc-standalone-server=$tigervnc_version",
            "tigervnc-tools=$tools_version",
            "dpkg-query",
            "TIGERVNC_PACKAGE_VERSION",
            "xterm",
            "xdotool",
        ):
            self.assertIn(required, install)
        self.assertEqual(run, "set -euo pipefail\npython3 tool/f61_tigervnc_acceptance.py\n")
        upload = next(
            step for step in steps
            if step.get("uses", "").startswith("actions/upload-artifact@")
        )
        self.assertEqual(upload["if"], "always()")
        self.assertEqual(upload["with"]["if-no-files-found"], "error")
        self.assertIn("${{ github.sha }}", upload["with"]["name"])

    def test_runner_uses_ephemeral_non_loopback_x509vnc_and_cleans_up(self):
        for required in (
            '"-SecurityTypes",\n                        "X509Vnc"',
            '"-PasswordFile"',
            '"-X509Cert"',
            '"-X509Key"',
            '"-AcceptSetDesktopSize"',
            '"-SendCutText"',
            '"-AcceptCutText"',
            '"-UseBlacklist=0"',
            '"LARENOR_F61_TIGERVNC_ACCEPTANCE": "1"',
            "VncTigerVncAcceptanceTest",
            "TemporaryDirectory",
            "secrets.token_urlsafe",
            "terminate(xterm_process)",
            "terminate(xvnc_process)",
        ):
            self.assertIn(required, self.runner)
        self.assertIn("value.is_loopback", self.runner)
        self.assertNotIn("127.0.0.1", self.runner)
        self.assertNotRegex(
            self.runner,
            r"192\.168\.|10\.\d+\.|172\.(?:1[6-9]|2\d|3[01])\.",
        )
        self.assertNotIn("shell=True", self.runner)

    def test_only_f61_paths_trigger_the_workflow(self):
        paths = self.workflow["on"]["pull_request"]["paths"]
        self.assertTrue(paths)
        self.assertTrue(all(
            "vnc" in path.lower() or "f61" in path.lower()
            for path in paths
        ))

    def test_runner_requires_one_executed_non_skipped_test_before_receipt(self):
        with tempfile.TemporaryDirectory() as temporary:
            report = Path(temporary) / "report.xml"
            report.write_text(
                '<testsuite name="com.ersingundem.larenor.vnc.VncTigerVncAcceptanceTest" '
                'tests="1" skipped="0" failures="0" errors="0" />'
            )
            runner.verify_report(report)
            for changed in (
                'tests="0"', 'skipped="1"', 'failures="1"', 'errors="1"',
            ):
                report.write_text(
                    '<testsuite name="com.ersingundem.larenor.vnc.VncTigerVncAcceptanceTest" '
                    f'tests="1" skipped="0" failures="0" errors="0" {changed}/>'
                )
                with self.assertRaises(runner.AcceptanceFailure):
                    runner.verify_report(report)

        self.assertIn('":app:cleanTestDebugUnitTest"', self.runner)
        self.assertLess(self.runner.index("verify_report()"), self.runner.index("receipt.json"))


if __name__ == "__main__":
    unittest.main()
