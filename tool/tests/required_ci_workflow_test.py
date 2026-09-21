"""Required CI check names and permissions must survive cancellation repair."""

import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / ".github/workflows"
CHECKOUT = "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"


class RequiredCiWorkflowTest(unittest.TestCase):
    def test_native_aggregates_keep_required_names_and_read_only_pr_access(self):
        for component in ("jellyfin", "qbittorrent", "arr", "seerr", "music-assistant"):
            with self.subTest(component=component):
                value = json.loads((WORKFLOWS / (
                    component + "-managed-characterization.yml")).read_text())
                job = value["jobs"]["native-acceptance"]
                self.assertEqual(job["name"], component + "-native-acceptance")
                self.assertEqual(job["if"], "always()")
                self.assertEqual(job["permissions"], {
                    "contents": "read", "pull-requests": "read"})
                self.assertEqual(job["steps"][0]["uses"], CHECKOUT)
                step = job["steps"][1]
                self.assertEqual(step["run"],
                                 "python3 tool/required_ci_aggregate.py native")
                self.assertEqual(step["env"]["GITHUB_TOKEN"], "${{ github.token }}")
                self.assertEqual(set(step["env"]), {
                    "RUN_NATIVE", "SCOPE_RESULT", "MATRIX_RESULT", "GITHUB_TOKEN"})

    def test_reusable_aggregates_remain_required_and_caller_grants_only_read(self):
        caller = (WORKFLOWS / "android-build.yml").read_text()
        for name, kind in (("server-test", "server"), ("analyze-test", "flutter")):
            with self.subTest(name=name):
                workflow = (WORKFLOWS / (name + ".yml")).read_text()
                required = workflow[workflow.index("  " + name + ":\n"):]
                self.assertIn("    if: always()", required)
                self.assertIn("      pull-requests: read", required)
                self.assertIn("persist-credentials: false", required)
                self.assertIn("GITHUB_TOKEN: ${{ github.token }}", required)
                self.assertIn("run: python3 tool/required_ci_aggregate.py " + kind,
                              required)
                caller_job = caller.partition("  " + name + ":\n")[2].split(
                    "\n\n  ", 1)[0]
                self.assertIn("      contents: read", caller_job)
                self.assertIn("      pull-requests: read", caller_job)


if __name__ == "__main__":
    unittest.main()
