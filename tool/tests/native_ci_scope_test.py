"""Regression tests for fail-open native characterization scoping."""

import json
from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tool"))

from native_ci_scope import decide_scope, is_relevant, patterns_for_workflow


WORKFLOWS = {
    "jellyfin-managed-characterization.yml": "characterize",
    "qbittorrent-managed-characterization.yml": "qbittorrent-characterize",
    "arr-managed-characterization.yml": "arr-characterize",
    "seerr-managed-characterization.yml": "seerr-characterize",
    "music-assistant-managed-characterization.yml": "music-assistant-characterize",
}


class NativeCiScopeTest(unittest.TestCase):
    def test_each_workflow_repeats_only_its_observable_native_inputs(self):
        repository = "ersingundem/larenor/.github/workflows/"
        refs = {
            name: patterns_for_workflow(repository + name + "@refs/pull/185/merge")
            for name in WORKFLOWS
        }
        self.assertTrue(all(patterns is not None for patterns in refs.values()))
        inventory = "server/larenor_server/inventory/service.py"
        self.assertTrue(all(not is_relevant(inventory, patterns) for patterns in refs.values()))
        app = "server/larenor_server/app.py"
        self.assertTrue(is_relevant(app, refs["music-assistant-managed-characterization.yml"]))
        self.assertTrue(all(
            not is_relevant(app, patterns)
            for name, patterns in refs.items()
            if name != "music-assistant-managed-characterization.yml"
        ))
        qbittorrent = "tool/qbittorrent_managed_ci.py"
        self.assertFalse(is_relevant(qbittorrent, refs["jellyfin-managed-characterization.yml"]))
        self.assertTrue(all(
            is_relevant(qbittorrent, patterns)
            for name, patterns in refs.items()
            if name != "jellyfin-managed-characterization.yml"
        ))

    def test_unknown_or_malformed_workflow_reference_has_no_skip_authority(self):
        for value in (
            "", "unknown.yml", "owner/repo/.github/workflows/unknown.yml@refs/heads/main",
            "other/larenor/.github/workflows/arr-managed-characterization.yml@refs/heads/main",
            "owner/repo/.github/workflows/../arr-managed-characterization.yml@refs/heads/main",
        ):
            with self.subTest(value=value):
                self.assertIsNone(patterns_for_workflow(value))

    def test_relevant_inputs_cover_server_and_each_native_tool(self):
        for path in (
            "server/larenor_server/app.py",
            ".github/workflows/arr-managed-characterization.yml",
            "tool/native_ci_scope.py",
            "tool/jellyfin_managed_ci.py",
            "tool/jellyfin_storage_smoke.py",
            "tool/qbittorrent_managed_ci.py",
            "tool/arr_managed_ci.py",
            "tool/seerr_managed_ci.py",
            "tool/music_assistant_managed_ci.py",
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

    def test_required_matrix_jobs_are_gated_before_reserving_matrix_runners(self):
        for filename, job_name in WORKFLOWS.items():
            with self.subTest(workflow=filename):
                value = json.loads((ROOT / ".github/workflows" / filename).read_text())
                scope = value["jobs"]["native-scope"]
                job = value["jobs"][job_name]
                checkout = next(
                    step
                    for step in scope["steps"]
                    if step.get("uses", "").startswith("actions/checkout@")
                )
                self.assertEqual(checkout["with"]["fetch-depth"], 0)
                decide = next(step for step in scope["steps"] if step.get("id") == "scope")
                self.assertIn("tool/native_ci_scope.py", decide["run"])
                self.assertIn(
                    'git show "$PR_BASE_SHA:tool/native_ci_scope.py"',
                    decide["run"],
                )
                self.assertIn(
                    'python3 "$RUNNER_TEMP/native_ci_scope.py"',
                    decide["run"],
                )
                self.assertEqual(
                    scope["env"]["PR_BASE_SHA"],
                    "${{ github.event.pull_request.base.sha }}",
                )
                self.assertEqual(
                    scope["env"]["PR_HEAD_SHA"],
                    "${{ github.event.pull_request.head.sha }}",
                )
                self.assertEqual(scope["outputs"]["run"], "${{ steps.scope.outputs.run }}")
                self.assertEqual(job["needs"], "native-scope")
                self.assertNotIn("if", job)
                self.assertEqual(
                    job["runs-on"],
                    "${{ needs.native-scope.outputs.run == 'true' && matrix.runner || 'ubuntu-24.04' }}",
                )
                self.assertFalse(any(step.get("id") == "scope" for step in job["steps"]))
                self.assertNotIn("if", job["steps"][0])
                for step in job["steps"][1:]:
                    self.assertEqual(
                        step.get("if"),
                        "needs.native-scope.outputs.run == 'true'",
                    )


if __name__ == "__main__":
    unittest.main()
