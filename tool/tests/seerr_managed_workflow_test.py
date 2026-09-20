"""Security policy for native managed Seerr acceptance."""

import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class SeerrManagedWorkflowPolicyTest(unittest.TestCase):
    def workflow(self):
        path = ROOT / ".github/workflows/seerr-managed-characterization.yml"
        self.assertTrue(path.is_file())
        return json.loads(path.read_text())

    def test_two_real_architectures_and_closed_event_scope(self):
        value = self.workflow()
        self.assertEqual(
            value["on"],
            {"workflow_dispatch": {}, "pull_request": {"branches": ["main"]}},
        )
        job = value["jobs"]["seerr-characterize"]
        self.assertEqual(
            job["strategy"]["matrix"]["include"],
            [
                {"runner": "ubuntu-24.04", "platform": "linux/amd64"},
                {"runner": "ubuntu-24.04-arm", "platform": "linux/arm64"},
            ],
        )
        self.assertIs(job["strategy"]["fail-fast"], False)

    def test_isolated_root_launcher_and_verified_receipt(self):
        value = self.workflow()
        self.assertEqual(value["permissions"], {"contents": "read"})
        text = json.dumps(value)
        self.assertNotIn("secrets.", text)
        self.assertNotIn("setup-qemu", text)
        steps = value["jobs"]["seerr-characterize"]["steps"]
        script = next(step for step in steps if step.get("id") == "native")["run"]
        self.assertIn("sudo --non-interactive env -i", script)
        self.assertIn("-m tool.seerr_managed_ci --run-ephemeral-ci", script)
        for forbidden in ("DOCKER_HOST", "HTTP_PROXY", "HTTPS_PROXY", "sudo -E"):
            self.assertNotIn(forbidden, script)
        verify = next(
            index
            for index, step in enumerate(steps)
            if "--verify-receipt" in step.get("run", "")
        )
        upload = next(
            index
            for index, step in enumerate(steps)
            if step.get("uses", "").startswith("actions/upload-artifact@")
        )
        self.assertLess(verify, upload)

    def test_runs_the_complete_convergence_flow_on_both_native_architectures(self):
        value = self.workflow()
        job = value["jobs"]["seerr-characterize"]
        self.assertGreaterEqual(job["timeout-minutes"], 35)
        native = next(step for step in job["steps"] if step.get("id") == "native")
        self.assertGreaterEqual(native["timeout-minutes"], 32)
        self.assertEqual(
            native["name"],
            "Converge Seerr admin, Arr wiring, initialization and restart",
        )

    def test_seerr_runtime_is_part_of_the_exact_source_bundle(self):
        source = (ROOT / "tool/jellyfin_storage_smoke.py").read_text()
        for path in (
            ".github/workflows/seerr-managed-characterization.yml",
            "tool/seerr_managed_ci.py",
            "server/larenor_server/plugins/seerr_bootstrap_executor.py",
            "server/larenor_server/plugins/seerr_bootstrap_models.py",
            "server/larenor_server/plugins/seerr_bootstrap_jobs.py",
            "server/larenor_server/plugins/seerr_arr_wiring.py",
            "server/larenor_server/plugins/seerr_endpoint.py",
            "server/larenor_server/plugins/seerr_initial_admin.py",
            "server/larenor_server/plugins/seerr_initialization.py",
            "server/larenor_server/plugins/arr_owned_config.py",
            "server/larenor_server/plugins/arr_config_binding.py",
            "server/larenor_server/plugins/arr_config_effect.py",
            "server/larenor_server/plugins/arr_config_models.py",
            "server/larenor_server/plugins/arr_config_runtime.py",
            "server/larenor_server/plugins/arr_endpoint.py",
            "server/larenor_server/plugins/arr_managed_root_folders.py",
            "server/larenor_server/plugins/arr_managed_download_client.py",
            "server/larenor_server/plugins/arr_bootstrap_executor.py",
            "server/larenor_server/plugins/arr_authenticated_readback.py",
        ):
            self.assertIn(repr(path), source)


if __name__ == "__main__":
    unittest.main()
