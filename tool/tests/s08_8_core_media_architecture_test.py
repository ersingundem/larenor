"""Keep verified-Core media surfaces free of direct provider clients."""

from pathlib import Path
from tempfile import TemporaryDirectory
import unittest


ROOT = Path(__file__).resolve().parents[2]
CORE_MEDIA_SURFACES = (
    "lib/features/media/hub/presentation/media_hub_screen.dart",
    "lib/features/server/media_catalog/presentation/server_media_catalog_screen.dart",
    "lib/features/server/media_rows/presentation/server_media_rows_section.dart",
    "lib/features/server/media_catalog/data/server_media_catalog_api.dart",
    "lib/features/server/media_catalog/data/server_media_catalog_controller.dart",
    "lib/features/server/media_rows/data/server_media_rows_api.dart",
    "lib/features/server/media_rows/data/server_media_rows_controller.dart",
)
FORBIDDEN_DIRECT_MARKERS = (
    "features/media/jellyfin/",
    "features/media/music/data/",
    "JellyfinClient(",
    "jellyfinClientProvider",
    "musicAssistantApiProvider",
    "WsMusicAssistantApi(",
)


def core_media_architecture_errors(root: Path) -> list[str]:
    errors: list[str] = []
    for relative in CORE_MEDIA_SURFACES:
        source = root / relative
        if not source.is_file():
            errors.append(f"missing:{relative}")
            continue
        text = source.read_text(encoding="utf-8")
        for marker in FORBIDDEN_DIRECT_MARKERS:
            if marker in text:
                errors.append(f"direct_provider:{relative}:{marker}")
    return errors


class CoreMediaArchitectureTest(unittest.TestCase):
    def test_verified_core_surfaces_never_construct_direct_media_clients(self):
        self.assertEqual(core_media_architecture_errors(ROOT), [])

    def test_direct_provider_import_and_constructor_bypasses_are_rejected(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            for relative in CORE_MEDIA_SURFACES:
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("// verified Core surface\n", encoding="utf-8")
            target = root / CORE_MEDIA_SURFACES[0]
            target.write_text(
                "import 'package:larenor/features/media/jellyfin/data/"
                "jellyfin_client.dart';\n"
                "final direct = JellyfinClient(config: config);\n",
                encoding="utf-8",
            )

            errors = core_media_architecture_errors(root)

            self.assertIn(
                f"direct_provider:{CORE_MEDIA_SURFACES[0]}:features/media/jellyfin/",
                errors,
            )
            self.assertIn(
                f"direct_provider:{CORE_MEDIA_SURFACES[0]}:JellyfinClient(",
                errors,
            )


if __name__ == "__main__":
    unittest.main()
