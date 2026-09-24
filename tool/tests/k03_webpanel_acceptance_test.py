import copy
import json
import unittest
from pathlib import Path

from tool import k03_webpanel_acceptance as acceptance


ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "docs/testing/k03-webpanel-acceptance.json"


class K03WebPanelAcceptanceTest(unittest.TestCase):
    def test_manifest_binds_every_required_production_test_review_and_ci_reference(self):
        value = acceptance.load_manifest(MANIFEST, ROOT)

        self.assertEqual(value["task"], "K03.remaining")
        self.assertEqual(value["sourceCommit"], acceptance.ACCEPTED_SOURCE_COMMIT)
        self.assertEqual(value["mergeCommit"], acceptance.ACCEPTED_MERGE_COMMIT)

    def test_each_required_reference_is_mandatory(self):
        value = json.loads(MANIFEST.read_text(encoding="utf-8"))
        for group, required in acceptance.REQUIRED_REFERENCES.items():
            for path in required:
                with self.subTest(group=group, path=path):
                    changed = copy.deepcopy(value)
                    changed["references"][group].remove(path)
                    with self.assertRaisesRegex(
                        acceptance.AcceptanceError,
                        "missing_reference",
                    ):
                        acceptance.validate_manifest(changed, ROOT)

    def test_path_escape_and_stale_ci_commit_fail_closed(self):
        value = json.loads(MANIFEST.read_text(encoding="utf-8"))
        escaped = copy.deepcopy(value)
        escaped["references"]["review"][0] = "docs/testing/../PROGRESS.md"
        with self.assertRaisesRegex(acceptance.AcceptanceError, "invalid_reference"):
            acceptance.validate_manifest(escaped, ROOT)

        stale = copy.deepcopy(value)
        stale["ci"]["android"]["commit"] = "0" * 40
        with self.assertRaisesRegex(acceptance.AcceptanceError, "stale_ci"):
            acceptance.validate_manifest(stale, ROOT)

    def test_removing_any_critical_production_or_test_guard_fails_closed(self):
        for path, markers in acceptance.REQUIRED_MARKERS.items():
            content = (ROOT / path).read_text(encoding="utf-8")
            for marker in markers:
                with self.subTest(path=path, marker=marker):
                    self.assertIn(marker, content)
                    changed = content.replace(marker, "", 1)
                    with self.assertRaisesRegex(
                        acceptance.AcceptanceError,
                        "missing_guard",
                    ):
                        acceptance.validate_reference_content(path, changed)


if __name__ == "__main__":
    unittest.main()
