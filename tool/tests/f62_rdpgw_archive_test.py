from __future__ import annotations

import hashlib
import importlib.util
import io
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

TOOL = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    "fixture", TOOL / "f62_rdpgw_owned_fixture.py"
)
assert spec and spec.loader
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)
ROOT = f"rdpgw-{fixture.REVISION}"
_ORIGINAL_EXTRACTALL = tarfile.TarFile.extractall


def archive(path: Path, entries: list[tuple[str, str, str]]) -> str:
    with tarfile.open(path, "w:gz", format=tarfile.PAX_FORMAT) as bundle:
        for name, kind, linkname in entries:
            info = tarfile.TarInfo(name)
            info.mtime = 0
            if kind == "dir":
                info.type = tarfile.DIRTYPE
                info.mode = 0o775
                bundle.addfile(info)
            elif kind == "file":
                body = b"owned-source\n"
                info.type = tarfile.REGTYPE
                info.mode = 0o664
                info.size = len(body)
                bundle.addfile(info, io.BytesIO(body))
            elif kind == "symlink":
                info.type = tarfile.SYMTYPE
                info.linkname = linkname
                bundle.addfile(info)
            elif kind == "hardlink":
                info.type = tarfile.LNKTYPE
                info.linkname = linkname
                bundle.addfile(info)
            elif kind == "fifo":
                info.type = tarfile.FIFOTYPE
                bundle.addfile(info)
            else:
                raise AssertionError(kind)
    return hashlib.sha256(path.read_bytes()).hexdigest()


class RdpGwArchiveTest(unittest.TestCase):
    @staticmethod
    def extractall_compat(
        bundle, path, members=None, *, numeric_owner=False, filter=None
    ):
        # Python 3.9 lacks the 3.12 data filter used by the Ubuntu 24 fixture.
        # This test wrapper runs only after safe_extract has validated every header.
        return _ORIGINAL_EXTRACTALL(bundle, path, members, numeric_owner=numeric_owner)

    def extract(self, entries: list[tuple[str, str, str]]) -> Path:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        base = Path(temporary.name)
        source_archive = base / "source.tar.gz"
        digest = archive(source_archive, entries)
        source_archive.chmod(0o600)
        destination = base / "out"
        with patch.object(fixture, "ARCHIVE_SHA", digest), patch.object(
            tarfile.TarFile, "extractall", self.extractall_compat
        ):
            return fixture.safe_extract(source_archive, destination)

    def test_exact_pinned_top_level_directory_without_trailing_slash_is_safe(self):
        source = self.extract(
            [
                (ROOT, "dir", ""),
                (f"{ROOT}/cmd", "dir", ""),
                (f"{ROOT}/cmd/rdpgw.go", "file", ""),
            ]
        )
        self.assertEqual(source.name, ROOT)
        self.assertEqual((source / "cmd/rdpgw.go").read_bytes(), b"owned-source\n")

    def test_root_name_is_accepted_only_for_a_directory(self):
        with self.assertRaisesRegex(fixture.FixtureError, "unsafeArchive"):
            self.extract([(ROOT, "file", "")])

    def test_wrong_root_and_traversal_remain_rejected(self):
        for name in ("different-root", f"{ROOT}/../escape"):
            with self.subTest(name=name):
                with self.assertRaisesRegex(fixture.FixtureError, "unsafeArchive"):
                    self.extract([(name, "dir", "")])

    def test_links_and_special_members_remain_rejected(self):
        cases = (
            (f"{ROOT}/sym", "symlink", "target"),
            (f"{ROOT}/hard", "hardlink", f"{ROOT}/target"),
            (f"{ROOT}/pipe", "fifo", ""),
        )
        for entry in cases:
            with self.subTest(kind=entry[1]):
                with self.assertRaisesRegex(fixture.FixtureError, "unsafeArchive"):
                    self.extract([(ROOT, "dir", ""), entry])


if __name__ == "__main__":
    unittest.main(verbosity=2)
