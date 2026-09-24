"""Keep verified-Core media entry points off direct service clients."""

from pathlib import Path
from tempfile import TemporaryDirectory
import unittest


ROOT = Path(__file__).resolve().parents[2]
CORE_ONLY_SURFACES = (
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
    "MusicCenterScreen(",
    "RemotePlaybackButton(",
)


def _text(root: Path, relative: str) -> str:
    path = root / relative
    if not path.is_file():
        raise FileNotFoundError(relative)
    return path.read_text(encoding="utf-8")


def core_media_architecture_errors(root: Path) -> list[str]:
    errors: list[str] = []
    for relative in CORE_ONLY_SURFACES:
        try:
            text = _text(root, relative)
        except FileNotFoundError:
            errors.append(f"missing:{relative}")
            continue
        for marker in FORBIDDEN_DIRECT_MARKERS:
            if marker in text:
                errors.append(f"direct_provider:{relative}:{marker}")

    selector_path = "lib/features/media/hub/presentation/media_hub_screen.dart"
    direct_path = "lib/features/media/hub/presentation/direct_media_hub_screen.dart"
    try:
        selector = _text(root, selector_path)
        direct = _text(root, direct_path)
    except FileNotFoundError as error:
        errors.append(f"missing:{error.args[0]}")
    else:
        closed = "home == null || home.source != HomeSource.directLocal"
        publish = "return DirectMediaHubScreen(embedded: embedded);"
        if closed not in selector or publish not in selector:
            errors.append("media_hub_selector_not_fail_closed")
        elif selector.index(closed) > selector.index(publish):
            errors.append("media_hub_selector_guard_after_publish")
        if "jellyfinClientProvider" not in direct:
            errors.append("direct_media_hub_missing_explicit_provider")
        references = []
        for source in sorted((root / "lib").rglob("*.dart")):
            if source.as_posix().endswith(direct_path):
                continue
            if "DirectMediaHubScreen(" in source.read_text(encoding="utf-8"):
                references.append(source.relative_to(root).as_posix())
        if references != [selector_path]:
            errors.append(f"direct_media_hub_importers:{','.join(references)}")

    guarded = (
        (
            "lib/features/dashboard/presentation/tiles/jellyfin_tile.dart",
            "return const _CoreJellyfinTile();",
            "ref.watch(jellyfinConnectionProvider)",
        ),
        (
            "lib/features/navigation/presentation/system_screen.dart",
            "return const MediaHubScreen();",
            "AppService.jellyfin => const JellyfinHomeScreen()",
        ),
        (
            "lib/features/settings/presentation/manage_integrations_screen.dart",
            "return const MediaHubScreen();",
            "builder: (_) => const JellyfinHomeScreen()",
        ),
        (
            "lib/features/settings/presentation/panes/integrations_pane.dart",
            "if (directHome) ...[",
            "ref.watch(jellyfinConnectionProvider)",
        ),
        (
            "lib/features/navigation/providers/media_destination_provider.dart",
            "if (!direct.isCurrent) return null;",
            "ref.watch(jellyfinClientProvider)",
        ),
    )
    for relative, guard, direct in guarded:
        try:
            text = _text(root, relative)
        except FileNotFoundError:
            errors.append(f"missing:{relative}")
            continue
        if guard not in text or direct not in text or text.index(guard) > text.index(direct):
            errors.append(f"unguarded_active_surface:{relative}")

    try:
        router = _text(root, "lib/core/router.dart")
    except FileNotFoundError:
        errors.append("missing:lib/core/router.dart")
    else:
        provider = router[router.find("final routerProvider") :]
        core_guard = "if (home != null && !home.usesLocalHome)"
        core_music = "builder: (_, _) => const ServerMusicManagerScreen()"
        direct_music = "builder: (_, _) => const MusicCenterScreen()"
        if not all(value in provider for value in (core_guard, core_music, direct_music)):
            errors.append("music_route_authority_missing")
        elif not provider.index(core_guard) < provider.index(core_music) < provider.index(direct_music):
            errors.append("music_route_authority_order")
        search_route = "path: '/search'"
        search_selector = "onOpenRemoteMedia: () => context.push('/media')"
        if search_route not in provider or search_selector not in provider:
            errors.append("search_route_bypasses_media_authority_selector")
    return errors


class CoreMediaArchitectureTest(unittest.TestCase):
    def test_all_active_core_surfaces_keep_direct_clients_behind_authority(self):
        self.assertEqual(core_media_architecture_errors(ROOT), [])

    def test_direct_provider_constructor_in_a_core_surface_is_rejected(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            for relative in CORE_ONLY_SURFACES:
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("// verified Core surface\n", encoding="utf-8")
            target = root / CORE_ONLY_SURFACES[1]
            target.write_text(
                "import 'package:larenor/features/media/jellyfin/data/"
                "jellyfin_client.dart';\n"
                "final direct = JellyfinClient(config: config);\n",
                encoding="utf-8",
            )

            errors = core_media_architecture_errors(root)

            self.assertIn(
                f"direct_provider:{CORE_ONLY_SURFACES[1]}:features/media/jellyfin/",
                errors,
            )
            self.assertIn(
                f"direct_provider:{CORE_ONLY_SURFACES[1]}:JellyfinClient(",
                errors,
            )

    def test_relative_import_cannot_hide_a_direct_provider_dependency(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            for relative in CORE_ONLY_SURFACES:
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("// verified Core surface\n", encoding="utf-8")
            target = root / CORE_ONLY_SURFACES[1]
            target.write_text(
                "import '../../../media/jellyfin/providers/"
                "jellyfin_providers.dart';\n"
                "final direct = jellyfinConnectionProvider;\n",
                encoding="utf-8",
            )

            errors = core_media_architecture_errors(root)

            self.assertIn(
                f"direct_import:{CORE_ONLY_SURFACES[1]}:"
                "lib/features/media/jellyfin/providers/jellyfin_providers.dart",
                errors,
            )


if __name__ == "__main__":
    unittest.main()
