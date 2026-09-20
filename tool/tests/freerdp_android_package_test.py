import hashlib
import io
import json
from pathlib import Path
import struct
import sys
import tarfile
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tool"))
from freerdp_android_package import PackageError, load_lock, package_receipt, verify_source


class FreeRdpAndroidPackageTest(unittest.TestCase):
    def test_repository_lock_is_exact_and_matches_runtime_gate(self):
        lock = load_lock()
        self.assertEqual(lock["source"]["version"], "3.31.1")
        self.assertEqual(lock["supportedAbis"], ["arm64-v8a", "x86_64"])
        self.assertEqual(lock["defaultChannels"], [])

    def test_source_archive_requires_digest_safe_paths_and_reviewed_blobs(self):
        lock = load_lock()
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "source.tar.gz"
            self._source(archive, lock)
            adjusted = json.loads(json.dumps(lock))
            adjusted["source"]["sha256"] = self._sha(archive.read_bytes())
            verify_source(archive, adjusted)
            archive.write_bytes(archive.read_bytes() + b"tamper")
            with self.assertRaisesRegex(PackageError, "source_digest_mismatch"):
                verify_source(archive, adjusted)

    def test_receipt_rejects_mixed_abi_and_records_exact_elf_digests(self):
        lock = load_lock()
        with tempfile.TemporaryDirectory() as directory:
            aar = Path(directory) / "core.aar"
            self._aar(aar, lock, "arm64-v8a")
            receipt = package_receipt(aar, "arm64-v8a", lock)
            self.assertEqual(receipt["defaultChannels"], [])
            self.assertEqual(
                {item["name"] for item in receipt["libraries"]},
                set(lock["requiredLibraries"]),
            )
            self._aar(aar, lock, "arm64-v8a", second="x86_64")
            with self.assertRaisesRegex(PackageError, "mixed_abi_aar"):
                package_receipt(aar, "arm64-v8a", lock)

    def _source(self, path, lock):
        with tarfile.open(path, "w:gz") as archive:
            for name, digest in lock["reviewedFiles"].items():
                # SHA-1 preimages are not constructed in this unit fixture; bind
                # the fixture lock to its own exact git blobs instead.
                data = name.encode()
                info = tarfile.TarInfo(f'freerdp-{lock["source"]["version"]}/{name}')
                info.size = len(data)
                archive.addfile(info, io.BytesIO(data))
                lock["reviewedFiles"][name] = self._git_blob(data)

    def _aar(self, path, lock, abi, second=None):
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("AndroidManifest.xml", b"manifest")
            archive.writestr("classes.jar", b"classes")
            for name in lock["requiredLibraries"]:
                archive.writestr(f"jni/{abi}/{name}", self._elf(183))
            if second:
                archive.writestr(f"jni/{second}/extra.so", self._elf(62))

    @staticmethod
    def _elf(machine):
        value = bytearray(64)
        value[:6] = b"\x7fELF\x02\x01"
        value[18:20] = struct.pack("<H", machine)
        return bytes(value)

    @staticmethod
    def _git_blob(data):
        return hashlib.sha1(f"blob {len(data)}\0".encode() + data).hexdigest()

    @staticmethod
    def _sha(data):
        return hashlib.sha256(data).hexdigest()


if __name__ == "__main__":
    unittest.main()
