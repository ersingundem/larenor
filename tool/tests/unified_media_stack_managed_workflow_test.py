import json
from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/unified-media-stack-managed.yml"


class UnifiedMediaStackManagedWorkflowTest(unittest.TestCase):
    def workflow(self):
        return json.loads(WORKFLOW.read_text())

    def test_manual_self_hosted_native_matrix_is_closed_and_exact(self):
        value = self.workflow()
        self.assertEqual(value["on"], {"workflow_dispatch": {}})
        self.assertEqual(value["permissions"], {"contents": "read"})
        job = value["jobs"]["unified-media-stack-native"]
        self.assertEqual(job["runs-on"], "${{ matrix.runner }}")
        self.assertEqual(job["strategy"], {"fail-fast": False, "matrix": {"include": [
            {"runner": ["self-hosted", "linux", "x64", "larenor-native"],
             "platform": "linux/amd64"},
            {"runner": ["self-hosted", "linux", "arm64", "larenor-native"],
             "platform": "linux/arm64"},
        ]}})
        self.assertGreaterEqual(job["timeout-minutes"], 35)

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
        self.assertEqual(steps[cleanup]["if"], "always()")
        self.assertIn("--cleanup-owned", steps[cleanup]["run"])
        self.assertIn("--run-native", steps[native]["run"])
        self.assertIn("--verify-receipt", steps[verify]["run"])
        self.assertEqual(steps[upload]["with"]["if-no-files-found"], "error")
        self.assertEqual(steps[upload]["with"]["retention-days"], 14)
        text = json.dumps(value)
        self.assertNotIn("secrets.", text)
        self.assertNotIn("continue-on-error", text)

    def test_every_embedded_shell_script_parses(self):
        value = self.workflow()
        for step in value["jobs"]["unified-media-stack-native"]["steps"]:
            script = step.get("run")
            if script:
                with self.subTest(name=step["name"]):
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
        self.assertIn("RUNNER_ENVIRONMENT=self-hosted", text)
        self.assertNotIn("sudo -E", text)


if __name__ == "__main__":
    unittest.main()
