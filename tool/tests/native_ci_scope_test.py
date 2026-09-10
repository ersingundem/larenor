"""Regression tests for fail-open native characterization scoping."""

import json
from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tool"))

from native_ci_scope import decide_scope, is_relevant


WORKFLOWS = {
    "jellyfin-managed-characterization.yml": "characterize",
    "qbittorrent-managed-characterization.yml": "qbittorrent-characterize",
    "arr-managed-characterization.yml": "arr-characterize",
}


class NativeCiScopeTest(unittest.TestCase):
    def test_relevant_inputs_cover_server_and_each_native_tool(self):
        for path in (
            "server/larenor_server/app.py",
            ".github/workflows/arr-managed-characterization.yml",
            "tool/native_ci_scope.py",
            "tool/jellyfin_managed_ci.py",
            "tool/jellyfin_storage_smoke.py",
            "tool/qbittorrent_managed_ci.py",
            "tool/arr_managed_ci.py",
            "tool/volume_bootstrap_helper.py",
            "tool/media_resource_smoke.py",
        ):
            with self.subTest(path=path):
                self.assertTrue(is_relevant(path))

    def test_android_and_documentation_only_changes_reuse_native_evidence(self):
        decision = decide_scope(
            event_name="pull_request",
            base_sha="a" * 40,
            head_sha="b" * 40,
            changed_files=lambda _base, _head: ("android/app/build.gradle.kts", "README.md"),
        )
        self.assertEqual(decision, (False, "native-inputs-unchanged"))

    def test_manual_invalid_revision_and_diff_error_fail_open(self):
        self.assertEqual(
            decide_scope(event_name="workflow_dispatch", base_sha="", head_sha="", changed_files=lambda *_: ()),
            (True, "non-pull-request"),
        )
        self.assertEqual(
            decide_scope(event_name="pull_request", base_sha="bad", head_sha="b" * 40, changed_files=lambda *_: ()),
            (True, "invalid-pull-request-revision"),
        )

        def fail(*_args):
            raise subprocess.CalledProcessError(128, "git diff")

        self.assertEqual(
            decide_scope(event_name="pull_request", base_sha="a" * 40, head_sha="b" * 40, changed_files=fail),
            (True, "diff-unavailable"),
        )

    def test_required_matrix_jobs_keep_names_and_gate_every_expensive_step(self):
        for filename, job_name in WORKFLOWS.items():
            with self.subTest(workflow=filename):
                value = json.loads((ROOT / ".github/workflows" / filename).read_text())
                job = value["jobs"][job_name]
                steps = job["steps"]
                checkout = next(step for step in steps if step.get("uses", "").startswith("actions/checkout@"))
                self.assertEqual(checkout["with"]["fetch-depth"], 0)
                scope_index = next(index for index, step in enumerate(steps) if step.get("id") == "scope")
                self.assertIn("tool/native_ci_scope.py", steps[scope_index]["run"])
                self.assertEqual(job["env"]["PR_BASE_SHA"], "${{ github.event.pull_request.base.sha }}")
                self.assertEqual(job["env"]["PR_HEAD_SHA"], "${{ github.event.pull_request.head.sha }}")
                for step in steps[scope_index + 1 :]:
                    self.assertEqual(step.get("if"), "steps.scope.outputs.run == 'true'")


if __name__ == "__main__":
    unittest.main()
