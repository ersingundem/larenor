from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
CONFIG = ROOT / ".github/dependabot.yml"


class DependabotConfigTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = CONFIG.read_text()

    def test_one_weekly_multi_ecosystem_group_owns_the_schedule(self):
        self.assertEqual(self.text.count("multi-ecosystem-groups:"), 1)
        self.assertEqual(self.text.count('multi-ecosystem-group: "weekly-maintenance"'), 3)
        self.assertEqual(self.text.count('interval: "weekly"'), 1)
        for exact in ('day: "monday"', 'time: "03:00"',
                      'timezone: "Europe/Istanbul"'):
            self.assertIn(exact, self.text)

    def test_pub_gradle_and_actions_are_each_included_exactly_once(self):
        ecosystems = re.findall(r'package-ecosystem: "([a-z-]+)"', self.text)
        self.assertEqual(ecosystems, ["pub", "gradle", "github-actions"])
        self.assertEqual(self.text.count('      - "*"'), 3)

    def test_group_has_a_stable_dependency_label(self):
        group = self.text.split("updates:", 1)[0]
        self.assertIn('      - "dependencies"', group)


if __name__ == "__main__":
    unittest.main()
