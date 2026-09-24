"""Security and execution policy for S09.2 native restore acceptance."""

import json
from pathlib import Path
import sys
import unittest


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/component-restore-native.yml"
sys.path.insert(0, str(ROOT / "tool"))

from native_ci_scope import is_relevant, patterns_for_workflow  # noqa: E402


class ComponentRestoreNativeWorkflowTest(unittest.TestCase):
    def workflow(self):
        self.assertTrue(WORKFLOW.is_file(), "native restore workflow absent")
        return json.loads(WORKFLOW.read_text())

    def test_exact_two_architecture_matrix_and_required_skip_aggregate(self):
        value = self.workflow()
        self.assertEqual(value["on"], {
            "workflow_dispatch": {},
            "pull_request": {"branches": ["main"]},
        })
        native = value["jobs"]["component-restore-native"]
        self.assertEqual(native["needs"], "native-scope")
        self.assertEqual(native["if"], "needs.native-scope.outputs.run == 'true'")
        self.assertEqual(native["strategy"]["matrix"]["include"], [
            {"runner": "ubuntu-24.04", "platform": "linux/amd64"},
            {"runner": "ubuntu-24.04-arm", "platform": "linux/arm64"},
        ])
        acceptance = value["jobs"]["native-acceptance"]
        self.assertEqual(acceptance["if"], "always()")
        self.assertEqual(
            acceptance["needs"], ["native-scope", "component-restore-native"]
        )
        gate = acceptance["steps"][1]
        self.assertEqual(gate["env"]["RUN_NATIVE"],
                         "${{ needs.native-scope.outputs.run }}")
        self.assertEqual(gate["run"], "python3 tool/required_ci_aggregate.py native")

    def test_native_job_runs_real_restore_authority_and_power_loss_contracts(self):
        value = self.workflow()
        native = value["jobs"]["component-restore-native"]
        script = "\n".join(step.get("run", "") for step in native["steps"])
        for evidence in (
            "test_core_backup_component_linux_restore.py",
            "test_core_backup_component_docker_adapter.py",
            "test_core_backup_component_installation_authority.py",
            "test_core_backup_component_restore.py",
            "test_core_backup_component_restore_recovery.py",
            "test_core_backup_component_restore_runtime.py",
            "test_core_backup_component_restore_product.py",
            "test_core_backup_restore_cli_components.py",
            "linux/amd64:x86_64|linux/arm64:aarch64",
        ):
            self.assertIn(evidence, script)
        self.assertNotIn("-k ", script)
        self.assertNotIn("continue-on-error", json.dumps(value))

    def test_exact_source_permissions_and_pinned_actions_are_closed(self):
        value = self.workflow()
        self.assertEqual(value["permissions"], {"contents": "read"})
        self.assertIs(value["concurrency"]["cancel-in-progress"], True)
        self.assertNotIn("secrets.", json.dumps(value))
        for job in value["jobs"].values():
            for step in job["steps"]:
                if "uses" not in step:
                    continue
                self.assertRegex(step["uses"], r"^actions/[a-z-]+@[0-9a-f]{40}$")
                if step["uses"].startswith("actions/checkout@"):
                    self.assertEqual(step["with"]["ref"], "${{ github.sha }}")
                    self.assertIs(step["with"]["persist-credentials"], False)

    def test_scope_uses_reviewed_base_classifier_and_fails_open(self):
        value = self.workflow()
        scope = value["jobs"]["native-scope"]
        self.assertEqual(scope["outputs"]["run"],
                         "${{ steps.scope.outputs.run }}")
        checkout = next(step for step in scope["steps"] if "uses" in step)
        self.assertEqual(checkout["with"]["fetch-depth"], 0)
        decide = next(step for step in scope["steps"] if step.get("id") == "scope")
        self.assertIn('git show "$PR_BASE_SHA:tool/native_ci_scope.py"', decide["run"])
        self.assertIn('python3 "$RUNNER_TEMP/native_ci_scope.py"', decide["run"])

    def test_scope_runs_for_restore_inputs_and_skips_testless_changes(self):
        patterns = patterns_for_workflow(
            "ersingundem/larenor/.github/workflows/"
            "component-restore-native.yml@refs/pull/475/merge"
        )
        self.assertIsNotNone(patterns)
        for path in (
            "server/larenor_server/core_backups/component_linux_restore.py",
            "server/tests/test_core_backup_component_restore_recovery.py",
            ".github/workflows/component-restore-native.yml",
        ):
            with self.subTest(path=path):
                self.assertTrue(is_relevant(path, patterns))
        for path in (
            "docs/PROGRESS.md",
            "docs/testing/s09-2-linux-component-restore.tdd.md",
            "client/lib/features/settings/settings_screen.dart",
        ):
            with self.subTest(path=path):
                self.assertFalse(is_relevant(path, patterns))


if __name__ == "__main__":
    unittest.main()
