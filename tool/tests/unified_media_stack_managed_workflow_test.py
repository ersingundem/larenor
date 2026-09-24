import json
from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/unified-media-stack-managed.yml"


class UnifiedMediaStackManagedWorkflowTest(unittest.TestCase):
    def workflow(self):
        return json.loads(WORKFLOW.read_text())

    def policy_errors(self, value):
        errors = []
        if value.get("on") != {
                "workflow_dispatch": {}, "pull_request": {"branches": ["main"]}}:
            errors.append("automatic_pull_request_required")
        text = json.dumps(value)
        if "self-hosted" in text:
            errors.append("self_hosted_forbidden")
        job = value.get("jobs", {}).get("unified-media-stack-native", {})
        matrix = job.get("strategy", {}).get("matrix", {}).get("include", [])
        if matrix != [
                {"runner": "ubuntu-24.04", "platform": "linux/amd64"},
                {"runner": "ubuntu-24.04-arm", "platform": "linux/arm64"}]:
            errors.append("hosted_native_matrix_required")
        if "native-scope" not in value.get("jobs", {}) or job.get("needs") != "native-scope":
            errors.append("native_scope_required")
        return errors

    def test_automatic_github_hosted_native_matrix_is_closed_and_exact(self):
        value = self.workflow()
        self.assertEqual(self.policy_errors(value), [])
        self.assertEqual(value["permissions"], {"contents": "read"})
        scope = value["jobs"]["native-scope"]
        self.assertEqual(scope["name"], "unified-stack-native-scope")
        self.assertEqual(scope["runs-on"], "ubuntu-24.04")
        job = value["jobs"]["unified-media-stack-native"]
        self.assertEqual(job["name"], "unified-stack-native (${{ matrix.platform }})")
        self.assertEqual(
            job["runs-on"],
            "${{ needs.native-scope.outputs.run == 'true' && matrix.runner || 'ubuntu-24.04' }}",
        )
        self.assertFalse(job["strategy"]["fail-fast"])
        self.assertGreaterEqual(job["timeout-minutes"], 35)
        self.assertEqual(
            [item["platform"] for item in job["strategy"]["matrix"]["include"]],
            ["linux/amd64", "linux/arm64"],
        )
        native = next(step for step in job["steps"] if step.get("id") == "native")
        verify = next(step for step in job["steps"] if step.get("id") == "verify")
        self.assertIn("--run-native", native["run"])
        self.assertIn("--expected-platform", verify["run"])

    def test_policy_rejects_manual_only_and_self_hosted_regressions(self):
        value = self.workflow()
        manual = json.loads(json.dumps(value))
        manual["on"] = {"workflow_dispatch": {}}
        self.assertIn("automatic_pull_request_required", self.policy_errors(manual))
        self_hosted = json.loads(json.dumps(value))
        self_hosted["jobs"]["unified-media-stack-native"]["strategy"]["matrix"]["include"][0]["runner"] = [
            "self-hosted", "linux", "x64", "larenor-native"]
        self.assertIn("self_hosted_forbidden", self.policy_errors(self_hosted))

    def test_exact_chain_verification_artifact_and_always_cleanup_are_ordered(self):
        value = self.workflow()
        steps = value["jobs"]["unified-media-stack-native"]["steps"]
        native = next(i for i, step in enumerate(steps) if step.get("id") == "native")
        cleanup = next(i for i, step in enumerate(steps) if step.get("id") == "cleanup")
        verify = next(i for i, step in enumerate(steps) if step.get("id") == "verify")
        upload = next(i for i, step in enumerate(steps)
                      if step.get("uses", "").startswith("actions/upload-artifact@"))
        self.assertLess(native, cleanup)
        self.assertLess(cleanup, verify)
        self.assertLess(verify, upload)
        self.assertEqual(
            steps[cleanup]["if"],
            "always() && needs.native-scope.outputs.run == 'true'",
        )
        self.assertIn("--cleanup-owned", steps[cleanup]["run"])
        self.assertIn("--run-native", steps[native]["run"])
        self.assertIn("--verify-receipt", steps[verify]["run"])
        self.assertEqual(steps[upload]["with"]["if-no-files-found"], "error")
        self.assertEqual(steps[upload]["with"]["retention-days"], 14)
        text = json.dumps(value)
        self.assertNotIn("secrets.", text)
        self.assertNotIn("continue-on-error", text)

    def test_exact_base_revision_reaches_both_architectures_and_public_evidence(self):
        value = self.workflow()
        job = value["jobs"]["unified-media-stack-native"]
        self.assertEqual(
            job["strategy"]["matrix"]["include"],
            [
                {"runner": "ubuntu-24.04", "platform": "linux/amd64"},
                {"runner": "ubuntu-24.04-arm", "platform": "linux/arm64"},
            ],
        )
        steps = job["steps"]
        resolve = next(
            step for step in steps
            if step.get("name") == "Resolve exact supported upgrade source"
        )
        native = next(step for step in steps if step.get("id") == "native")
        verify = next(step for step in steps if step.get("id") == "verify")
        upload = next(
            step for step in steps
            if step.get("uses", "").startswith("actions/upload-artifact@")
        )
        for required in (
            'upgrade_source="$PR_BASE_SHA"',
            'reviewed_head="$PR_HEAD_SHA"',
            "git show -s --format='%P'",
            'set -- $(git show -s --format=',
            'test "$#" -eq 1',
            'reviewed_head="$GITHUB_SHA"',
            '*[!0-9a-f]*',
            '${#revision}" -eq 40',
            '$upgrade_source" != "$GITHUB_SHA',
            'git merge-base --is-ancestor',
            'UPGRADE_SOURCE_SHA=$upgrade_source',
            'REVIEWED_HEAD_SHA=$reviewed_head',
        ):
            self.assertIn(required, resolve["run"])
        self.assertIn('UPGRADE_SOURCE_SHA="$UPGRADE_SOURCE_SHA"', native["run"])
        self.assertIn('REVIEWED_HEAD_SHA="$REVIEWED_HEAD_SHA"', native["run"])
        self.assertIn(
            '--expected-upgrade-source "$UPGRADE_SOURCE_SHA"', verify["run"]
        )
        self.assertIn(
            '--expected-reviewed-head "$REVIEWED_HEAD_SHA"', verify["run"]
        )
        self.assertIn("${{ github.sha }}", upload["with"]["name"])
        self.assertIn("${{ runner.arch }}", upload["with"]["name"])

    def test_post_effect_fault_is_recovered_before_owned_cleanup(self):
        value = self.workflow()
        steps = value["jobs"]["unified-media-stack-native"]["steps"]
        native_index = next(
            index for index, step in enumerate(steps) if step.get("id") == "native"
        )
        cleanup_index = next(
            index for index, step in enumerate(steps) if step.get("id") == "cleanup"
        )
        native = steps[native_index]
        script = native["run"]

        self.assertIn("--fault-after-upgrade-journal", script)
        self.assertIn('test "$status" -eq 75', script)
        self.assertEqual(script.count("--run-native"), 2)
        self.assertLess(
            script.index("--fault-after-upgrade-journal"),
            script.rindex("--run-native"),
        )
        self.assertIn('UPGRADE_SOURCE_SHA="$UPGRADE_SOURCE_SHA"', script)
        self.assertIn('REVIEWED_HEAD_SHA="$REVIEWED_HEAD_SHA"', script)
        self.assertLess(native_index, cleanup_index)
        self.assertIn("--cleanup-owned", steps[cleanup_index]["run"])

    def test_every_embedded_shell_script_parses(self):
        value = self.workflow()
        for step in value["jobs"]["unified-media-stack-native"]["steps"]:
            script = step.get("run")
            if script:
                with self.subTest(name=step.get("name")):
                    result = subprocess.run(
                        ["/bin/bash", "-n"], input=script, text=True,
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)

    def test_actions_and_toolchain_are_immutable_or_exactly_pinned(self):
        value = self.workflow()
        steps = value["jobs"]["unified-media-stack-native"]["steps"]
        for step in steps:
            if "uses" in step:
                self.assertRegex(step["uses"], r"^actions/[a-z-]+@[0-9a-f]{40}$")
        text = json.dumps(value)
        self.assertIn("uv==0.12.10", text)
        self.assertIn("python install 3.12.14", text)
        self.assertIn("RUNNER_ENVIRONMENT=github-hosted", text)
        self.assertNotIn("self-hosted", text)
        self.assertNotIn("sudo -E", text)


if __name__ == "__main__":
    unittest.main()
