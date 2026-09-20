import hashlib
import io
import json
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tool"))
from freerdp_android_package import (
    PackageError,
    load_lock,
    package_receipt,
    verify_apk,
    verify_certificate_patch,
    verify_install,
    verify_source,
)


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

    def test_install_and_apk_must_contain_the_receipted_exact_native_payload(self):
        lock = load_lock()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            aar, receipt, apk = root / "core.aar", root / "receipt.json", root / "app.apk"
            self._aar(aar, lock, "arm64-v8a")
            value = package_receipt(aar, "arm64-v8a", lock)
            receipt.write_text(json.dumps(value))
            verify_install(aar, receipt, lock)
            with zipfile.ZipFile(aar) as source, zipfile.ZipFile(apk, "w") as target:
                for item in value["libraries"]:
                    target.writestr(
                        f'lib/arm64-v8a/{item["name"]}',
                        source.read(f'jni/arm64-v8a/{item["name"]}'),
                    )
            verify_apk(apk, receipt, lock)
            tampered = root / "tampered.apk"
            with zipfile.ZipFile(apk) as source, zipfile.ZipFile(tampered, "w") as target:
                for name in source.namelist():
                    payload = source.read(name)
                    if name.endswith("/libfreerdp3.so"):
                        payload = b"tamper"
                    target.writestr(name, payload)
            with self.assertRaisesRegex(PackageError, "apk_library_mismatch"):
                verify_apk(tampered, receipt, lock)

    def test_receipt_tamper_never_enables_the_gradle_dependency(self):
        lock = load_lock()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            aar, receipt = root / "core.aar", root / "receipt.json"
            self._aar(aar, lock, "x86_64")
            value = package_receipt(aar, "x86_64", lock)
            value["engineRevision"] = "unreviewed"
            receipt.write_text(json.dumps(value))
            with self.assertRaisesRegex(PackageError, "receipt_mismatch"):
                verify_install(aar, receipt, lock)

    def test_certificate_patch_applies_inside_exact_upstream_pre_connect(self):
        lock = load_lock()
        fixture = ROOT / (
            "tool/tests/fixtures/freerdp-3.31.1/android_freerdp.c"
        )
        self.assertEqual(
            self._git_blob(fixture.read_bytes()),
            lock["reviewedFiles"][
                "client/Android/Studio/freeRDPCore/src/main/cpp/android_freerdp.c"
            ],
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / (
                "client/Android/Studio/freeRDPCore/src/main/cpp/"
                "android_freerdp.c"
            )
            source.parent.mkdir(parents=True)
            shutil.copyfile(fixture, source)
            with self.assertRaisesRegex(
                PackageError, "invalid_certificate_patch"
            ):
                verify_certificate_patch(source)
            subprocess.run(
                [
                    "git",
                    "apply",
                    str(ROOT / "android/freerdp-certificate-pem.patch"),
                ],
                cwd=root,
                check=True,
            )
            verify_certificate_patch(source)
            text = source.read_text()
            start = text.index("static BOOL android_pre_connect")
            marker = text.index("FreeRDP_CertificateCallbackPreferPEM")
            subscription = text.index(
                "int rc = PubSub_SubscribeChannelConnected", start
            )
            following = text.index("static BOOL android_post_connect", start)
            self.assertLess(start, marker)
            self.assertLess(marker, subscription)
            self.assertLess(subscription, following)

            source.write_text(
                fixture.read_text()
                + "\n\tif (!freerdp_settings_set_bool(settings, "
                "FreeRDP_CertificateCallbackPreferPEM, TRUE))\n"
                "\t\treturn FALSE;\n"
            )
            with self.assertRaisesRegex(
                PackageError, "invalid_certificate_patch"
            ):
                verify_certificate_patch(source)

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
        classes = io.BytesIO()
        with zipfile.ZipFile(classes, "w") as jar:
            for name in lock["requiredClasses"]:
                jar.writestr(name, b"fixture")
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("AndroidManifest.xml", b"manifest")
            archive.writestr("classes.jar", classes.getvalue())
            for name in lock["requiredLibraries"]:
                payload = self._elf(183 if abi == "arm64-v8a" else 62)
                if name == "libfreerdp-android.so":
                    payload += b"JNI_OnLoad"
                archive.writestr(f"jni/{abi}/{name}", payload)
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
