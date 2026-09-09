"""Security policy for the manual two-architecture resource workflow."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class MediaResourceWorkflowTest(unittest.TestCase):
    def workflow(self):
        return json.loads((ROOT / ".github/workflows/media-resource-characterization.yml").read_text())

    def test_manual_native_matrix_and_minimum_permissions(self):
        value = self.workflow()
        self.assertEqual(value["on"], {"workflow_dispatch": {}})
        self.assertEqual(value["permissions"], {"contents": "read"})
        job = value["jobs"]["characterize"]
        self.assertFalse(job["strategy"]["fail-fast"])
        self.assertEqual(job["strategy"]["matrix"]["include"], [
            {"runner": "ubuntu-24.04", "platform": "linux/amd64"},
            {"runner": "ubuntu-24.04-arm", "platform": "linux/arm64"},
        ])

    def test_root_step_is_sanitized_and_receipt_precedes_artifact(self):
        value = self.workflow()
        steps = value["jobs"]["characterize"]["steps"]
        native = next(step for step in steps if step.get("id") == "native")
        script = native["run"]
        self.assertIn("sudo --non-interactive env -i", script)
        self.assertIn("-m tool.media_resource_ci --run-ephemeral-ci", script)
        self.assertNotIn("DOCKER_HOST", script)
        self.assertNotIn("sudo -E", script)
        verify = next(i for i, step in enumerate(steps) if "--verify-receipt" in step.get("run", ""))
        upload = next(i for i, step in enumerate(steps) if step.get("uses", "").startswith("actions/upload-artifact@"))
        self.assertLess(verify, upload)
        self.assertEqual(steps[upload]["with"]["if-no-files-found"], "error")

    def test_workflow_has_no_container_volume_or_cleanup_commands(self):
        text = json.dumps(self.workflow())
        for forbidden in ("docker run", "docker create", "docker start", "docker exec",
                          "docker volume", "docker network rm", "docker system prune"):
            self.assertNotIn(forbidden, text)
        self.assertNotIn("secrets.", text)

    def test_actions_are_pinned_and_checkout_has_no_credentials(self):
        steps = self.workflow()["jobs"]["characterize"]["steps"]
        for step in steps:
            if "uses" in step:
                self.assertRegex(step["uses"], r"^actions/[a-z-]+@[0-9a-f]{40}$")
        checkout = next(step for step in steps if step.get("uses", "").startswith("actions/checkout@"))
        self.assertIs(checkout["with"]["persist-credentials"], False)
        self.assertEqual(checkout["with"]["ref"], "${{ github.sha }}")
        self.assertNotIn("continue-on-error", json.dumps(self.workflow()))

    def test_dependency_and_native_runtime_versions_are_closed(self):
        text = json.dumps(self.workflow())
        self.assertIn("uv==0.12.10", text)
        self.assertIn("uv sync --locked --python 3.12.14", text)
        runtime = next(step for step in self.workflow()["jobs"]["characterize"]["steps"]
                       if step.get("name") == "Require owned cgroup runtime")["run"]
        self.assertIn("/usr/bin/systemd-run --version", runtime)
        self.assertIn("-ge 254", runtime)
        self.assertIn("cgroup2fs", runtime)

    def test_actual_root_shell_drops_ambient_secrets_and_preserves_status(self):
        step = next(item for item in self.workflow()["jobs"]["characterize"]["steps"]
                    if item.get("id") == "native")
        for exit_code in (0, 19):
            with self.subTest(exit_code=exit_code), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / "bin").mkdir()
                sudo = root / "bin/sudo"
                sudo.write_text("#!" + sys.executable + "\nimport os,sys\n"
                                "assert sys.argv[1]=='--non-interactive'\n"
                                "os.execv('/usr/bin/env',sys.argv[2:])\n")
                sudo.chmod(0o700)
                venv = root / "venv with spaces"
                (venv / "bin").mkdir(parents=True)
                python = venv / "bin/python"
                python.write_text("#!" + sys.executable + "\nimport json,os,sys\n"
                                  "print(json.dumps({'env':dict(os.environ),'args':sys.argv[1:]}))\n"
                                  f"sys.exit({exit_code})\n")
                python.chmod(0o700)
                values = {"PATH": str(root / "bin") + ":/usr/bin:/bin",
                          "RUNNER_TEMP": str(root), "GITHUB_WORKSPACE": str(root / "workspace with spaces"),
                          "UV_PROJECT_ENVIRONMENT": str(venv), "CI": "true",
                          "GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted",
                          "RUNNER_ARCH": "X64", "GITHUB_SHA": "a" * 40,
                          "GITHUB_WORKFLOW_SHA": "a" * 40, "GITHUB_EVENT_NAME": "workflow_dispatch",
                          "GITHUB_REF": "refs/heads/main", "GITHUB_REPOSITORY": "ersingundem/larenor",
                          "EXPECTED_PLATFORM": "linux/amd64", "GITHUB_TOKEN": "synthetic-private",
                          "DOCKER_HOST": "unix:///foreign.sock", "HTTP_PROXY": "http://synthetic-private",
                          "HOME": "/synthetic-home"}
                completed = subprocess.run(["/bin/bash", "-e", "-c", step["run"]],
                                           env=values, capture_output=True, timeout=5)
                self.assertEqual(completed.returncode, exit_code, completed.stderr)
                captured = json.loads((root / "media-resource-receipt.json").read_text())
                expected = {"PATH", "PYTHONPATH", "CI", "GITHUB_ACTIONS", "RUNNER_ENVIRONMENT",
                            "RUNNER_ARCH", "GITHUB_SHA", "GITHUB_WORKFLOW_SHA", "GITHUB_EVENT_NAME",
                            "GITHUB_REF", "GITHUB_REPOSITORY", "EXPECTED_PLATFORM"}
                runtime_locale = {"LC_CTYPE", "__CF_USER_TEXT_ENCODING"} if sys.platform == "darwin" else {"LC_CTYPE"}
                self.assertEqual(set(captured["env"]) - runtime_locale, expected)
                self.assertNotIn("synthetic-private", json.dumps(captured["env"]))
                self.assertEqual(captured["args"],
                                 ["-B", "-m", "tool.media_resource_ci", "--run-ephemeral-ci"])

    def test_actual_manual_preflight_rejects_changed_dispatch_context(self):
        script = self.workflow()["jobs"]["characterize"]["steps"][0]["run"]
        valid = {"PATH": "/usr/bin:/bin", "GITHUB_EVENT_NAME": "workflow_dispatch",
                 "GITHUB_REF": "refs/heads/main", "GITHUB_REPOSITORY": "ersingundem/larenor",
                 "GITHUB_SHA": "a" * 40, "GITHUB_WORKFLOW_SHA": "a" * 40,
                 "RUNNER_ENVIRONMENT": "github-hosted"}
        self.assertEqual(subprocess.run(["/bin/bash", "-e", "-c", script], env=valid,
                                        timeout=5).returncode, 0)
        for key in set(valid) - {"PATH"}:
            with self.subTest(key=key):
                changed = subprocess.run(["/bin/bash", "-e", "-c", script],
                                         env=valid | {key: "wrong"}, timeout=5)
                self.assertNotEqual(changed.returncode, 0)


if __name__ == "__main__":
    unittest.main()
