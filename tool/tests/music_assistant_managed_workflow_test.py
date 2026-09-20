"""Security policy for native managed Music Assistant acceptance."""

import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class MusicAssistantManagedWorkflowPolicyTest(unittest.TestCase):
    def workflow(self):
        path = ROOT / ".github/workflows/music-assistant-managed-characterization.yml"
        self.assertTrue(path.is_file())
        return json.loads(path.read_text())

    def test_two_real_architectures_and_closed_event_scope(self):
        value = self.workflow()
        self.assertEqual(
            value["on"],
            {"workflow_dispatch": {}, "pull_request": {"branches": ["main"]}},
        )
        job = value["jobs"]["music-assistant-characterize"]
        self.assertEqual(
            job["strategy"]["matrix"]["include"],
            [
                {"runner": "ubuntu-24.04", "platform": "linux/amd64"},
                {"runner": "ubuntu-24.04-arm", "platform": "linux/arm64"},
            ],
        )
        self.assertIs(job["strategy"]["fail-fast"], False)

    def test_durable_contract_precedes_isolated_native_receipt(self):
        value = self.workflow()
        self.assertEqual(value["permissions"], {"contents": "read"})
        text = json.dumps(value)
        self.assertNotIn("secrets.", text)
        self.assertNotIn("continue-on-error", text)
        steps = value["jobs"]["music-assistant-characterize"]["steps"]
        contract = next(
            index for index, step in enumerate(steps)
            if "test_music_assistant_bootstrap_jobs.py" in step.get("run", "")
        )
        native = next(index for index, step in enumerate(steps) if step.get("id") == "native")
        verify = next(
            index for index, step in enumerate(steps)
            if "--verify-receipt" in step.get("run", "")
        )
        upload = next(
            index for index, step in enumerate(steps)
            if step.get("uses", "").startswith("actions/upload-artifact@")
        )
        self.assertLess(contract, native)
        self.assertLess(native, verify)
        self.assertLess(verify, upload)
        self.assertIn("test_music_provider_setups.py", steps[contract]["run"])
        script = steps[native]["run"]
        self.assertIn("sudo --non-interactive env -i", script)
        self.assertIn("-m tool.music_assistant_managed_ci --run-ephemeral-ci", script)
        for forbidden in ("DOCKER_HOST", "HTTP_PROXY", "HTTPS_PROXY", "sudo -E"):
            self.assertNotIn(forbidden, script)

    def test_actions_and_python_toolchain_are_digest_or_version_pinned(self):
        value = self.workflow()
        steps = value["jobs"]["music-assistant-characterize"]["steps"]
        for step in steps:
            if "uses" in step:
                self.assertRegex(step["uses"], r"^actions/[a-z-]+@[0-9a-f]{40}$")
        text = json.dumps(value)
        self.assertIn("uv==0.12.10", text)
        self.assertIn("uv sync --locked --python 3.12.14", text)
        self.assertNotIn("setup-qemu", text)


if __name__ == "__main__":
    unittest.main()
