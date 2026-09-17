"""Keep hosted Android SDK setup off the removed legacy ``tools`` package."""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = (
    ".github/workflows/android-build.yml",
    ".github/workflows/android-e2e.yml",
)


class AndroidSdkSetupPolicyTest(unittest.TestCase):
    def test_every_setup_android_step_requests_only_platform_tools(self):
        found = 0
        for path in WORKFLOWS:
            text = (ROOT / path).read_text()
            blocks = re.findall(
                r"(?ms)^      - uses: android-actions/setup-android@[0-9a-f]{40}[^\n]*\n"
                r"(?P<body>.*?)(?=^      - (?:uses:|name:|run:))",
                text,
            )
            self.assertTrue(blocks, path)
            found += len(blocks)
            for body in blocks:
                self.assertRegex(body, r"(?m)^        with:\n          packages: platform-tools$")
                self.assertNotRegex(body, r"(?m)^          packages:.*(?:^| )tools(?: |$)")
        self.assertEqual(found, 3)


if __name__ == "__main__":
    unittest.main()
