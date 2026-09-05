"""Exercise scanner failure propagation without Docker or network access."""

import os
from pathlib import Path
import re
import subprocess
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = (ROOT / ".github/workflows/security.yml").read_text()
SCAN_JOB = WORKFLOW.split("\n  dependency-scan:\n", 1)[1]
SCAN_SCRIPT = textwrap.dedent(re.search(
    r"        run: \|\n(.*?)(?=      - name: Summarize dependency scan)",
    SCAN_JOB, re.DOTALL,
).group(1))


class SecurityScanPolicyTest(unittest.TestCase):
    def run_scan(self, exit_code=0, missing=None):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "server").mkdir()
            for lock in ("pubspec.lock", "server/uv.lock"):
                if lock != missing:
                    (root / lock).write_text("synthetic lockfile\n")
            binary = root / "bin"
            binary.mkdir()
            docker = binary / "docker"
            docker.write_text(
                '#!/bin/sh\n'
                'printf "%s\\n" "$@" > "$OSV_TEST_ARGS"\n'
                'printf "Synthetic scanner result: %s\\n" "$OSV_TEST_EXIT_CODE"\n'
                'exit "$OSV_TEST_EXIT_CODE"\n'
            )
            docker.chmod(0o700)
            capture = root / "docker-args"
            environment = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ["PATH"],
                               GITHUB_WORKSPACE=str(root), OSV_TEST_ARGS=str(capture),
                               OSV_TEST_EXIT_CODE=str(exit_code))
            result = subprocess.run(["bash", "-e", "-o", "pipefail", "-c", SCAN_SCRIPT],
                                    cwd=root, env=environment, capture_output=True, text=True,
                                    check=False)
            arguments = capture.read_text().splitlines() if capture.exists() else []
            return result, arguments

    def test_clean_scan_succeeds_with_both_lockfiles_and_readonly_mount(self):
        result, arguments = self.run_scan()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Synthetic scanner result: 0", result.stdout)
        self.assertIn("--lockfile=./pubspec.lock", arguments)
        self.assertIn("--lockfile=./server/uv.lock", arguments)
        self.assertIn("--read-only", arguments)
        self.assertTrue(any(arg.endswith(",dst=/src,readonly") for arg in arguments))
        self.assertIn("--cap-drop=ALL", arguments)
        self.assertIn("--security-opt=no-new-privileges", arguments)
        image = next(arg for arg in arguments if arg.startswith("ghcr.io/"))
        self.assertRegex(image, r"^ghcr\.io/google/osv-scanner:v2\.5\.0@sha256:[0-9a-f]{64}$")
        self.assertEqual(arguments[arguments.index(image) + 1:][:3],
                         ["scan", "source", "--format=table"])

    def test_vulnerabilities_scan_errors_and_container_errors_remain_failures(self):
        # OSV: findings=1, generic=127, no packages=128, API=129, config=130.
        # Docker itself uses 125 when the container could not be started.
        for code in (1, 125, 127, 128, 129, 130):
            with self.subTest(exit_code=code):
                result, arguments = self.run_scan(code)
                self.assertEqual(result.returncode, code)
                self.assertTrue(arguments)
                self.assertIn(f"Synthetic scanner result: {code}", result.stdout)

    def test_missing_required_lockfile_fails_before_container_launch(self):
        for lock in ("pubspec.lock", "server/uv.lock"):
            with self.subTest(missing=lock):
                result, arguments = self.run_scan(missing=lock)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(arguments, [])

    def test_scans_have_no_artifact_dependency_or_failure_suppression(self):
        code = "\n".join(line for line in WORKFLOW.splitlines()
                         if not line.lstrip().startswith("#"))
        self.assertNotIn("continue-on-error", code)
        self.assertNotIn("upload-artifact@", code)
        self.assertNotIn("osv-scanner-reusable.yml@", code)
        self.assertNotIn("security-events: write", code)
        self.assertNotIn("actions: write", code)
        self.assertNotIn("--allow-no-lockfiles", SCAN_SCRIPT)
        self.assertNotIn("|| true", SCAN_SCRIPT)
        self.assertIn('GITLEAKS_ENABLE_UPLOAD_ARTIFACT: "false"', code)
        self.assertIn('GITLEAKS_ENABLE_SUMMARY: "true"', code)
        self.assertIn('GITLEAKS_ENABLE_COMMENTS: "false"', code)
        self.assertIn('fetch-depth: 0', code)
        summary = SCAN_JOB.split("      - name: Summarize dependency scan", 1)[1]
        self.assertIn("if: ${{ always() }}", summary)
        self.assertIn("${{ steps.osv.outcome }}", summary)
        self.assertIn('>> "$GITHUB_STEP_SUMMARY"', summary)


if __name__ == "__main__":
    unittest.main()
