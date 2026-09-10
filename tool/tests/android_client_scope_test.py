from pathlib import Path
import re
from tempfile import TemporaryDirectory
import unittest


ROOT = Path(__file__).resolve().parents[2]
NATIVE_PLATFORM_ROOTS = {"android", "ios", "linux", "macos", "web", "windows"}


def android_client_scope_errors(root: Path) -> list[str]:
    errors = []
    present = {name for name in NATIVE_PLATFORM_ROOTS if (root / name).exists()}
    if present != {"android"}:
        errors.append("native_platform_roots")

    metadata = (root / ".metadata").read_text(encoding="utf-8")
    platforms = re.findall(
        r"^\s*-\s+platform:\s*['\"]?([A-Za-z0-9_-]+)['\"]?\s*(?:#.*)?$",
        metadata,
        re.MULTILINE,
    )
    if platforms != ["root", "android"] or re.search(
        r"(?i)(?:^|[/'\"])ios(?:/|['\"]|$)", metadata
    ):
        errors.append("flutter_platform_metadata")

    pubspec = (root / "pubspec.yaml").read_text(encoding="utf-8")
    if re.search(
        r"(?m)^\s{2}['\"]?webview_flutter_wkwebview['\"]?\s*:", pubspec
    ):
        errors.append("direct_wkwebview_dependency")

    dart_paths = sorted((root / "lib").rglob("*.dart"))
    dart_sources = "\n".join(path.read_text(encoding="utf-8") for path in dart_paths)
    for marker in (
        "webview_flutter_wkwebview",
        "TargetPlatform.iOS",
        "Platform.isIOS",
    ):
        if marker in dart_sources:
            errors.append("native_ios_runtime_branch")
            break
    if any(path.name.endswith("_ios.dart") for path in dart_paths):
        errors.append("native_ios_source_file")
    return errors


class AndroidClientScopeTest(unittest.TestCase):
    def test_repository_is_android_only(self):
        self.assertEqual(android_client_scope_errors(ROOT), [])

    def test_quoted_and_alternate_platform_bypasses_are_rejected(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            for path in (root / "android", root / "macos", root / "lib"):
                path.mkdir(parents=True)
            (root / ".metadata").write_text(
                '    - platform: root\n    - platform: android\n'
                '    - platform: "ios"\n',
                encoding="utf-8",
            )
            (root / "pubspec.yaml").write_text(
                'dependencies:\n  "webview_flutter_wkwebview": ^3.0.0\n',
                encoding="utf-8",
            )
            (root / "lib" / "platform.dart").write_text(
                "final nativeIos = Platform.isIOS;\n",
                encoding="utf-8",
            )
            self.assertEqual(
                set(android_client_scope_errors(root)),
                {
                    "native_platform_roots",
                    "flutter_platform_metadata",
                    "direct_wkwebview_dependency",
                    "native_ios_runtime_branch",
                },
            )


if __name__ == "__main__":
    unittest.main()
