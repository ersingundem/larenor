from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]


class AndroidClientScopeTest(unittest.TestCase):
    def test_native_client_tree_contains_only_android(self):
        self.assertTrue((ROOT / "android").is_dir())
        self.assertFalse((ROOT / "ios").exists())

        metadata = (ROOT / ".metadata").read_text(encoding="utf-8")
        platforms = re.findall(r"^    - platform: (\w+)$", metadata, re.MULTILINE)
        self.assertEqual(platforms, ["root", "android"])
        self.assertNotIn("ios/", metadata)

    def test_shared_client_has_no_native_ios_runtime_branch(self):
        pubspec = (ROOT / "pubspec.yaml").read_text(encoding="utf-8")
        self.assertNotRegex(pubspec, r"(?m)^\s*webview_flutter_wkwebview:")

        dart_sources = "\n".join(
            path.read_text(encoding="utf-8")
            for path in sorted((ROOT / "lib").rglob("*.dart"))
        )
        self.assertNotIn("webview_flutter_wkwebview", dart_sources)
        self.assertNotIn("TargetPlatform.iOS", dart_sources)


if __name__ == "__main__":
    unittest.main()
