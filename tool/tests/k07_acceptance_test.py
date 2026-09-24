import copy
import json
import unittest
from pathlib import Path

from tool import k07_acceptance as acceptance


ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "docs/testing/k07-software-acceptance.json"


class K07AcceptanceTest(unittest.TestCase):
    def test_pending_manifest_binds_current_software_and_cannot_close_queue(self):
        value = acceptance.load_manifest(MANIFEST, ROOT, allow_pending=True)
        self.assertEqual(value["task"], "K07")
        self.assertEqual(value["sourceCommit"], acceptance.SOURCE_COMMIT)
        with self.assertRaisesRegex(acceptance.AcceptanceError, "acceptance_pending"):
            acceptance.load_manifest(MANIFEST, ROOT)

    def test_each_required_reference_is_mandatory(self):
        value = json.loads(MANIFEST.read_text(encoding="utf-8"))
        for group, required in acceptance.REQUIRED_REFERENCES.items():
            for path in required:
                with self.subTest(group=group, path=path):
                    changed = copy.deepcopy(value)
                    changed["references"][group].remove(path)
                    with self.assertRaisesRegex(acceptance.AcceptanceError, "missing_reference"):
                        acceptance.validate_manifest(changed, ROOT, allow_pending=True)

    def test_path_escape_and_premature_evidence_fail_closed(self):
        value = json.loads(MANIFEST.read_text(encoding="utf-8"))
        escaped = copy.deepcopy(value)
        escaped["references"]["review"][0] = "docs/testing/../PROGRESS.md"
        with self.assertRaisesRegex(acceptance.AcceptanceError, "invalid_reference"):
            acceptance.validate_manifest(escaped, ROOT, allow_pending=True)

        premature = copy.deepcopy(value)
        premature["review"] = {
            "commit": "0" * 40,
            "result": "passed",
            "ref": "docs/testing/k07-software-acceptance.tdd.md",
        }
        with self.assertRaisesRegex(acceptance.AcceptanceError, "invalid_pending"):
            acceptance.validate_manifest(premature, ROOT, allow_pending=True)

    def test_removing_any_critical_production_or_test_guard_fails_closed(self):
        for path, markers in acceptance.REQUIRED_MARKERS.items():
            content = (ROOT / path).read_text(encoding="utf-8")
            for marker in markers:
                with self.subTest(path=path, marker=marker):
                    self.assertIn(marker, content)
                    changed = content.replace(marker, "", 1)
                    with self.assertRaisesRegex(acceptance.AcceptanceError, "missing_guard"):
                        acceptance.validate_reference_content(path, changed)


if __name__ == "__main__":
    unittest.main()
