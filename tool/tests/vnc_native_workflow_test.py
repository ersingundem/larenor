import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
from unittest import mock

from tool import f61_tigervnc_acceptance as runner
from tool import native_acceptance_receipt as receipt


ROOT = Path(__file__).resolve().parents[2]


class VncNativeWorkflowTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow_path = ROOT / ".github/workflows/vnc-native-acceptance.yml"
        cls.workflow = json.loads(cls.workflow_path.read_text())
        cls.workflow_text = cls.workflow_path.read_text()
        cls.runner = (ROOT / "tool/f61_tigervnc_acceptance.py").read_text()

    def test_closed_reviewed_execution_and_commit_pinned_actions(self):
        self.assertEqual(self.workflow["on"]["workflow_dispatch"], {})
        self.assertEqual(self.workflow["on"]["pull_request"]["branches"], ["main"])
        self.assertEqual(self.workflow["permissions"], {"contents": "read"})
        job = self.workflow["jobs"]["tigervnc"]
        self.assertEqual(job["runs-on"], "ubuntu-24.04")
        self.assertEqual(job["timeout-minutes"], 30)
        self.assertNotIn("runner.", json.dumps(job.get("env", {})))
        isolated_home = job["steps"][0]
        self.assertEqual(isolated_home["name"], "Set isolated Gradle home")
        self.assertEqual(
            isolated_home["run"],
            'set -euo pipefail\n'
            'echo "GRADLE_USER_HOME=$RUNNER_TEMP/f61-gradle" >> "$GITHUB_ENV"\n',
        )
        guard = next(
            step["run"] for step in job["steps"]
            if step.get("name") == "Require reviewed GitHub-hosted execution"
        )
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
            "xfonts-base",
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

    def test_workflow_generates_locked_flutter_sources_before_native_gate(self):
        required = (
            "flutter pub get --enforce-lockfile",
            "flutter gen-l10n",
            "dart run build_runner build --delete-conflicting-outputs",
            "python3 tool/f61_tigervnc_acceptance.py",
        )
        for value in required:
            self.assertEqual(self.workflow_text.count(value), 1, value)
        self.assertEqual(
            sorted(self.workflow_text.index(value) for value in required),
            [self.workflow_text.index(value) for value in required],
        )

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
            '"-class",\n                        "LarenorF61Fixture"',
            '"--class",\n                    "^LarenorF61Fixture$"',
            '"--noprofile"',
            '"--norc"',
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
        self.assertNotIn('"--name"', self.runner)

    def test_runner_paints_a_deterministic_multicolor_first_frame(self):
        painted_root = self.runner[self.runner.index("[\n                    xsetroot,") :]
        painted_root = painted_root[: painted_root.index("],") + 2]
        for value in (
            '"-display"',
            '"-mod"',
            '"8"',
            '"-fg"',
            '"#315a9c"',
            '"-bg"',
            '"#f5c842"',
        ):
            self.assertIn(value, painted_root)
        self.assertNotIn(
            '[xsetroot, "-display", display, "-solid", "#315a9c"]',
            self.runner,
        )

    def test_only_f61_paths_trigger_the_workflow(self):
        paths = self.workflow["on"]["pull_request"]["paths"]
        self.assertTrue(paths)
        self.assertTrue(all(
            "vnc" in path.lower()
            or "f61" in path.lower()
            or path in {
                "tool/android_acceptance_gradle.py",
                "tool/native_acceptance_receipt.py",
            }
            for path in paths
        ))

    def test_runner_requires_one_executed_non_skipped_test_before_receipt(self):
        with tempfile.TemporaryDirectory() as temporary:
            report = Path(temporary) / "report.xml"
            valid = (
                '<testsuite name="com.ersingundem.larenor.vnc.VncTigerVncAcceptanceTest" '
                'tests="1" skipped="0" failures="0" errors="0">'
                '<testcase '
                'classname="com.ersingundem.larenor.vnc.VncTigerVncAcceptanceTest" '
                'name="normalBridgeInteroperatesWithOwnedTigerVncAndRetiresWithoutReplay"/>'
                '</testsuite>'
            )
            report.write_text(valid)
            runner.verify_report(report)
            invalid = (
                valid.replace('tests="1"', 'tests="0"'),
                valid.replace('skipped="0"', 'skipped="1"'),
                valid.replace('failures="0"', 'failures="1"'),
                valid.replace('errors="0"', 'errors="1"'),
                valid.replace(
                    f'classname="{runner.TEST_CLASS}"', 'classname="Other"'
                ),
                valid.replace(runner.TEST_NAME, "anotherMethod"),
                valid.replace(
                    "<testcase ", "<testcase><skipped/></testcase><testcase ", 1
                ),
                valid.replace(
                    "<testcase ", "<testcase><failure/></testcase><testcase ", 1
                ),
                valid.replace(
                    "<testcase ", "<testcase><error/></testcase><testcase ", 1
                ),
                valid.replace(
                    valid[valid.index("<testcase") : valid.index("</testsuite>")],
                    "",
                ),
                valid.replace(
                    "</testsuite>",
                    valid[valid.index("<testcase") : valid.index("</testsuite>")]
                    + "</testsuite>",
                ),
            )
            for changed in invalid:
                report.write_text(changed)
                with self.assertRaises(runner.AcceptanceFailure):
                    runner.verify_report(report)

        self.assertIn('":app:cleanTestDebugUnitTest"', self.runner)
        self.assertLess(self.runner.index("verify_report()"), self.runner.index("receipt.json"))

    def test_runner_uses_the_shared_private_gradle_launcher(self):
        self.assertIn("materialized_gradle_command", self.runner)
        self.assertIn("AndroidAcceptanceGradleError", self.runner)
        self.assertNotIn('ROOT / "android" / "gradlew"', self.runner)
        self.assertNotIn("def gradle_wrapper_command", self.runner)

    def test_receipt_source_revision_is_real_head_and_host_bound(self):
        expected = subprocess.run(
            ["git", "-C", str(ROOT), "rev-parse", "--verify", "HEAD"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        self.assertRegex(expected, r"^[0-9a-f]{40}$")
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("GITHUB_SHA", None)
            self.assertEqual(receipt.source_revision(ROOT), expected)
        with mock.patch.dict(os.environ, {"GITHUB_SHA": expected}, clear=False):
            self.assertEqual(receipt.source_revision(ROOT), expected)
        public = runner.acceptance_receipt(
            provider_version="Xvnc 1.13.1",
            package_version="1.13.1+dfsg-2build2",
            revision=expected,
        )
        self.assertEqual(public["sourceRevision"], expected)
        self.assertEqual(public["testClass"], runner.TEST_CLASS)
        self.assertEqual(public["testName"], runner.TEST_NAME)
        self.assertEqual(
            {key: public[key] for key in ("tests", "skipped", "failures", "errors")},
            {"tests": 1, "skipped": 0, "failures": 0, "errors": 0},
        )
        self.assertNotIn("password", json.dumps(public).lower())
        with mock.patch.dict(os.environ, {"GITHUB_SHA": "0" * 40}, clear=False):
            with self.assertRaises(receipt.NativeAcceptanceReceiptError) as caught:
                receipt.source_revision(ROOT)
        self.assertNotIn(expected, str(caught.exception))


if __name__ == "__main__":
    unittest.main()
