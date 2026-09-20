import json
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]


class FreeRdpAndroidWorkflowTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = json.loads(
            (ROOT / ".github/workflows/freerdp-android-native.yml").read_text()
        )

    def test_closed_events_permissions_and_two_real_android_abis(self):
        self.assertEqual(self.workflow["on"]["workflow_dispatch"], {})
        self.assertEqual(self.workflow["on"]["pull_request"]["branches"], ["main"])
        self.assertEqual(self.workflow["permissions"], {"contents": "read"})
        job = self.workflow["jobs"]["package"]
        self.assertEqual(job["runs-on"], "ubuntu-24.04")
        self.assertEqual(job["strategy"]["matrix"]["abi"], ["arm64-v8a", "x86_64"])
        self.assertIs(job["strategy"]["fail-fast"], False)

    def test_actions_are_commit_pinned_and_no_secret_or_production_target_exists(self):
        text = json.dumps(self.workflow)
        self.assertNotIn("secrets.", text)
        self.assertNotRegex(text, r"192\.168\.|10\.\d+\.|172\.(?:1[6-9]|2\d|3[01])\.")
        for step in self.workflow["jobs"]["package"]["steps"]:
            if "uses" in step:
                self.assertRegex(step["uses"], r"^[a-z-]+/[a-z-]+@[0-9a-f]{40}$")
                if step["uses"].startswith("actions/checkout@"):
                    self.assertEqual(step["with"]["ref"], "${{ github.sha }}")
                    self.assertIs(step["with"]["persist-credentials"], False)

    def test_source_digest_toolchain_and_disabled_defaults_are_policy_gated(self):
        steps = self.workflow["jobs"]["package"]["steps"]
        verify = next(step["run"] for step in steps if "verify-source" in step.get("run", ""))
        build = next(step["run"] for step in steps if "assembleRelease" in step.get("run", ""))
        receipt = next(step["run"] for step in steps if " receipt " in step.get("run", ""))
        self.assertIn("freerdp-3.31.1.tar.gz", verify)
        self.assertIn("freerdp_android_package.py verify-source", verify)
        for exact in ("NDK_VERSION=29.0.13113456", "CMAKE_VERSION=4.1.2", "VERSION_NAME=3.31.1"):
            self.assertIn(exact, build)
        for disabled in ("WITH_FFMPEG=OFF", "WITH_OPENH264=OFF", "WITH_OPUS=OFF"):
            self.assertIn(disabled, build)
        self.assertIn("freerdp_android_package.py receipt", receipt)
        product = next(step["run"] for step in steps if "verify-apk" in step.get("run", ""))
        self.assertIn("flutter build apk --debug", product)
        self.assertIn("android/app/freerdp/freeRDPCore.aar", product)
        self.assertIn("freerdp_android_package.py verify-apk", product)
        patch = next(step["run"] for step in steps if "freerdp-certificate-pem.patch" in step.get("run", ""))
        self.assertIn("git apply --check", patch)
        self.assertIn("<manifest", patch)

    def test_exact_reviewed_source_guard_runs_before_checkout_and_build(self):
        steps = self.workflow["jobs"]["package"]["steps"]
        guard = steps[0]["run"]
        for required in (
            "workflow_dispatch)", "pull_request)", "refs/heads/main",
            "refs/pull/*/merge", "ersingundem/larenor", "github-hosted",
            "$GITHUB_WORKFLOW_SHA\" = \"$GITHUB_SHA",
        ):
            self.assertIn(required, guard)
        upload = next(step for step in steps if step.get("uses", "").startswith("actions/upload-artifact@"))
        self.assertEqual(upload["with"]["if-no-files-found"], "error")
        self.assertIn("${{ github.sha }}", upload["with"]["name"])


if __name__ == "__main__":
    unittest.main()
