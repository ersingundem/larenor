"""Keep Android dependency caches deterministic and pull-request read-only."""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
DEPENDENCY_PATHS = (
    "android/**/*.gradle*",
    "android/gradle/wrapper/gradle-wrapper.properties",
    "pubspec.lock",
)


def java_block(path):
    text = (ROOT / path).read_text()
    match = re.search(
        r"(?ms)^      - uses: actions/setup-java@[^\n]+\n"
        r"(?P<body>.*?)(?=^      - (?:uses:|name:|run:))",
        text,
    )
    if match is None:
        raise AssertionError(f"setup-java block missing from {path}")
    return match.group("body")


class AndroidGradleCachePolicyTest(unittest.TestCase):
    def test_e2e_uses_its_bounded_gradle_home_and_prs_are_read_only(self):
        block = java_block(".github/workflows/android-e2e.yml")
        self.assertIn("cache: gradle", block)
        self.assertIn("cache-read-only: ${{ github.event_name == 'pull_request' }}", block)
        for path in DEPENDENCY_PATHS:
            self.assertIn(path, block)
        self.assertIn("${{ runner.temp }}/larenor-e2e-gradle/caches", block)
        self.assertIn("${{ runner.temp }}/larenor-e2e-gradle/wrapper", block)

    def test_debug_build_reuses_default_gradle_cache_without_custom_outputs(self):
        block = java_block(".github/workflows/android-build.yml")
        self.assertIn("cache: gradle", block)
        self.assertIn("cache-read-only: ${{ github.event_name == 'pull_request' }}", block)
        for path in DEPENDENCY_PATHS:
            self.assertIn(path, block)
        self.assertNotIn("build/", block)
        self.assertNotIn("runner.temp", block)


if __name__ == "__main__":
    unittest.main()
