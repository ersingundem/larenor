import hashlib
import io
import json
import os
from pathlib import Path
import struct
import tarfile
import tempfile
import unittest
from unittest import mock

from tool import f62_owned_shadow_channels as subject


class F62OwnedShadowChannelsTest(unittest.TestCase):
    def _archive(self, path: Path, files: dict[str, bytes], *, symlink=False):
        with tarfile.open(path, "w:gz") as bundle:
            for relative, data in files.items():
                info = tarfile.TarInfo(f"freerdp-3.31.1/{relative}")
                if symlink:
                    info.type = tarfile.SYMTYPE
                    info.linkname = "/etc/passwd"
                    info.size = 0
                    bundle.addfile(info)
                    continue
                info.size = len(data)
                bundle.addfile(info, io.BytesIO(data))

    def test_verify_and_prepare_exact_archive_applies_patch_once(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / "source.tar.gz"
            source = b"before\n"
            self._archive(archive, {"source.txt": source})
            patch = root / "fixture.patch"
            patch.write_text(
                "--- a/source.txt\n"
                "+++ b/source.txt\n"
                "@@ -1 +1 @@\n"
                "-before\n"
                "+after\n",
                encoding="utf-8",
            )
            output = root / "prepared"
            source_files = {"source.txt": hashlib.sha256(source).hexdigest()}
            with (
                mock.patch.object(subject, "SOURCE_SHA256", subject.sha256(archive)),
                mock.patch.object(subject, "SOURCE_FILES", source_files),
                mock.patch.object(subject, "PATCH_SHA256", subject.sha256(patch)),
                mock.patch.object(subject, "verify_patched_source"),
            ):
                subject.prepare_source(archive, output, patch)
            self.assertEqual((output / "source.txt").read_text(), "after\n")
            with self.assertRaisesRegex(subject.FixtureError, "output_must_not_exist"):
                subject.prepare_source(archive, output, patch)

    def test_patch_binds_context_cleanup_before_shadow_resources(self):
        relative = "server/shadow/shadow_client.c"
        self.assertEqual(
            subject.SOURCE_FILES[relative],
            "d4accb9fa930e2fcbfc356ad4f6208589df8702a2f79dc4b41e8cb6b2fd56b30",
        )
        self.assertEqual(
            subject.PATCHED_FILES[relative],
            "5003278a1bfda0f6ee8111e3fc154d7b5dfa2de5ffe4d9f9d8a7d7becdf2469a",
        )
        patch = subject.PATCH_PATH.read_text(encoding="utf-8")
        section = patch.split("--- a/server/shadow/shadow_client.c", 1)[1].split(
            "--- a/server/shadow/shadow_larenor_channels.c", 1
        )[0]
        self.assertIn('#include "shadow_larenor_channels.h"', section)
        self.assertLess(
            section.index("shadow_larenor_channels_free(client);"),
            section.index("shadow_encoder_free(client->encoder);"),
        )

    def test_archive_rejects_links_and_parent_traversal(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            linked = root / "linked.tar.gz"
            self._archive(linked, {"source.txt": b""}, symlink=True)
            with (
                mock.patch.object(subject, "SOURCE_SHA256", subject.sha256(linked)),
                mock.patch.object(subject, "SOURCE_FILES", {}),
                self.assertRaisesRegex(subject.FixtureError, "unsafe_source_archive"),
            ):
                subject.verify_source(linked)

            traversing = root / "traversing.tar.gz"
            with tarfile.open(traversing, "w:gz") as bundle:
                info = tarfile.TarInfo("freerdp-3.31.1/../../escape")
                info.size = 1
                bundle.addfile(info, io.BytesIO(b"x"))
            with (
                mock.patch.object(subject, "SOURCE_SHA256", subject.sha256(traversing)),
                mock.patch.object(subject, "SOURCE_FILES", {}),
                self.assertRaisesRegex(subject.FixtureError, "unsafe_source_archive"),
            ):
                subject.verify_source(traversing)

    def test_archive_rejects_final_symlink_and_duplicate_member_names(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / "source.tar.gz"
            self._archive(archive, {"source.txt": b"source"})
            linked = root / "linked.tar.gz"
            linked.symlink_to(archive)
            with (
                mock.patch.object(subject, "SOURCE_SHA256", subject.sha256(archive)),
                mock.patch.object(subject, "SOURCE_FILES", {}),
                self.assertRaisesRegex(subject.FixtureError, "invalid_source_archive"),
            ):
                subject.verify_source(linked)

            duplicate = root / "duplicate.tar.gz"
            with tarfile.open(duplicate, "w:gz") as bundle:
                for data in (b"first", b"second"):
                    info = tarfile.TarInfo("freerdp-3.31.1/source.txt")
                    info.size = len(data)
                    bundle.addfile(info, io.BytesIO(data))
            with (
                mock.patch.object(subject, "SOURCE_SHA256", subject.sha256(duplicate)),
                mock.patch.object(subject, "SOURCE_FILES", {}),
                self.assertRaisesRegex(subject.FixtureError, "unsafe_source_archive"),
            ):
                subject.verify_source(duplicate)

    def test_exact_source_file_digest_is_required(self):
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "source.tar.gz"
            self._archive(archive, {"source.txt": b"changed\n"})
            with (
                mock.patch.object(subject, "SOURCE_SHA256", subject.sha256(archive)),
                mock.patch.object(
                    subject,
                    "SOURCE_FILES",
                    {"source.txt": hashlib.sha256(b"expected\n").hexdigest()},
                ),
                self.assertRaisesRegex(subject.FixtureError, "source_file_mismatch"),
            ):
                subject.verify_source(archive)

    def test_prepared_source_rejects_symlinked_patch_and_patched_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            source.mkdir()
            target = source / "fixture.c"
            target.write_bytes(b"fixture")
            patch = root / "fixture.patch"
            patch.write_bytes(b"patch")
            linked_patch = root / "linked.patch"
            linked_patch.symlink_to(patch)
            with (
                mock.patch.object(subject, "PATCH_SHA256", hashlib.sha256(b"patch").hexdigest()),
                mock.patch.object(
                    subject,
                    "PATCHED_FILES",
                    {"fixture.c": hashlib.sha256(b"fixture").hexdigest()},
                ),
                self.assertRaisesRegex(subject.FixtureError, "invalid_file"),
            ):
                subject.verify_patched_source(source, linked_patch)

            target.unlink()
            external = root / "external.c"
            external.write_bytes(b"fixture")
            target.symlink_to(external)
            with (
                mock.patch.object(subject, "PATCH_SHA256", hashlib.sha256(b"patch").hexdigest()),
                mock.patch.object(
                    subject,
                    "PATCHED_FILES",
                    {"fixture.c": hashlib.sha256(b"fixture").hexdigest()},
                ),
                self.assertRaisesRegex(subject.FixtureError, "patched_source_mismatch"),
            ):
                subject.verify_patched_source(source, patch)

    def test_build_uses_fixed_shadow_target_and_private_log(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            source.mkdir()
            build = root / "build"
            log = root / "private.log"
            cmake = root / "cmake"
            cmake.write_text("#!/bin/sh\n", encoding="utf-8")
            cmake.chmod(0o700)
            calls = []

            def run(argv, **kwargs):
                calls.append((argv, kwargs))
                if "--build" in argv:
                    executable = build / subject.SHADOW_CLI_RELATIVE
                    executable.parent.mkdir(parents=True)
                    executable.write_bytes(b"fixture")
                    executable.chmod(0o700)
                return mock.Mock(returncode=0)

            with (
                mock.patch.object(subject, "verify_patched_source"),
                mock.patch.object(subject.subprocess, "run", side_effect=run),
            ):
                executable = subject.build_fixture(source, build, cmake, log, jobs=2)
            self.assertEqual(len(calls), 2)
            self.assertIn("-DWITH_LARENOR_F62_OWNED_CHANNELS=ON", calls[0][0])
            self.assertIn("-DWITH_SHADOW_SUBSYSTEM=ON", calls[0][0])
            self.assertIn("-DWITH_X11=ON", calls[0][0])
            self.assertIn("-DCHANNEL_CLIPRDR_SERVER=ON", calls[0][0])
            self.assertIn("-DCHANNEL_DISP_SERVER=ON", calls[0][0])
            self.assertEqual(calls[1][0][-3:], ["freerdp-shadow-cli", "--parallel", "2"])
            self.assertEqual(executable, build / subject.SHADOW_CLI_RELATIVE)
            self.assertEqual(log.stat().st_mode & 0o777, 0o600)
            self.assertNotIn("source", calls[0][1]["env"])

    def test_build_rejects_unbounded_jobs_and_existing_outputs(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            source.mkdir()
            cmake = root / "cmake"
            cmake.write_text("x", encoding="utf-8")
            cmake.chmod(0o700)
            with self.assertRaisesRegex(subject.FixtureError, "invalid_jobs"):
                subject.build_fixture(source, root / "build", cmake, root / "log", jobs=0)
            (root / "build").mkdir()
            with self.assertRaisesRegex(subject.FixtureError, "build_must_not_exist"):
                subject.build_fixture(source, root / "build", cmake, root / "log", jobs=1)

    def test_witness_exposes_only_bounded_counts_and_flags(self):
        with tempfile.TemporaryDirectory() as temporary:
            witness = Path(temporary) / "witness.bin"
            values = [
                subject.FLAG_CLIPBOARD_EFFECT | subject.FLAG_DISP_EFFECT,
                2,
                2,
                2,
                1,
                1,
                0,
            ]
            data = struct.pack("<8sII7I20s", subject.WITNESS_MAGIC, 1, 64, *values, b"\0" * 20)
            witness.write_bytes(data)
            witness.chmod(0o600)
            result = subject.read_witness(witness)
            self.assertEqual(
                result,
                {
                    "schemaVersion": 1,
                    "clipboardEffect": True,
                    "displayEffect": True,
                    "formatLists": 2,
                    "dataRequests": 2,
                    "dataResponses": 2,
                    "emptyResponses": 1,
                    "displayLayouts": 1,
                    "channelErrors": 0,
                },
            )
            self.assertNotIn("clipboard", json.dumps(result).lower().replace("clipboardeffect", ""))

    def test_witness_rejects_wrong_size_reserved_bytes_and_unbounded_counts(self):
        with tempfile.TemporaryDirectory() as temporary:
            witness = Path(temporary) / "witness.bin"
            witness.write_bytes(b"short")
            witness.chmod(0o600)
            with self.assertRaisesRegex(subject.FixtureError, "invalid_witness"):
                subject.read_witness(witness)
            data = struct.pack(
                "<8sII7I20s", subject.WITNESS_MAGIC, 1, 64, 0, 0, 0, 0, 0, 0, 0, b"x" + b"\0" * 19
            )
            witness.write_bytes(data)
            witness.chmod(0o600)
            with self.assertRaisesRegex(subject.FixtureError, "invalid_witness"):
                subject.read_witness(witness)
            data = struct.pack(
                "<8sII7I20s", subject.WITNESS_MAGIC, 1, 64, 0, 9, 0, 0, 0, 0, 0, b"\0" * 20
            )
            witness.write_bytes(data)
            witness.chmod(0o600)
            with self.assertRaisesRegex(subject.FixtureError, "invalid_witness"):
                subject.read_witness(witness)

    def test_witness_rejects_symlink_wrong_mode_errors_and_impossible_effect(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            witness = root / "witness.bin"
            valid = struct.pack(
                "<8sII7I20s", subject.WITNESS_MAGIC, 1, 64, 0, 0, 0, 0, 0, 0, 0, b"\0" * 20
            )
            witness.write_bytes(valid)
            witness.chmod(0o644)
            with self.assertRaisesRegex(subject.FixtureError, "invalid_witness"):
                subject.read_witness(witness)

            witness.chmod(0o600)
            linked = root / "linked.bin"
            linked.symlink_to(witness)
            with self.assertRaisesRegex(subject.FixtureError, "invalid_witness"):
                subject.read_witness(linked)

            oversized = root / "oversized.bin"
            oversized.write_bytes(valid + b"x")
            oversized.chmod(0o600)
            with self.assertRaisesRegex(subject.FixtureError, "invalid_witness"):
                subject.read_witness(oversized)

            hard_link = root / "hard-linked.bin"
            os.link(witness, hard_link)
            with self.assertRaisesRegex(subject.FixtureError, "invalid_witness"):
                subject.read_witness(witness)
            hard_link.unlink()

            impossible = struct.pack(
                "<8sII7I20s",
                subject.WITNESS_MAGIC,
                1,
                64,
                subject.FLAG_CLIPBOARD_EFFECT,
                0,
                0,
                0,
                0,
                0,
                0,
                b"\0" * 20,
            )
            witness.write_bytes(impossible)
            witness.chmod(0o600)
            with self.assertRaisesRegex(subject.FixtureError, "invalid_witness"):
                subject.read_witness(witness)

            errors = struct.pack(
                "<8sII7I20s", subject.WITNESS_MAGIC, 1, 64, 0, 0, 0, 0, 0, 0, 1, b"\0" * 20
            )
            witness.write_bytes(errors)
            witness.chmod(0o600)
            with self.assertRaisesRegex(subject.FixtureError, "invalid_witness"):
                subject.read_witness(witness)

    def test_lifetimes_require_enabled_effects_then_zero_clipboard_transfer(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary) / "channels"
            first = struct.pack(
                "<8sII7I20s",
                subject.WITNESS_MAGIC,
                1,
                64,
                subject.FLAG_CLIPBOARD_EFFECT | subject.FLAG_DISP_EFFECT,
                2,
                2,
                2,
                1,
                1,
                0,
                b"\0" * 20,
            )
            second = struct.pack(
                "<8sII7I20s",
                subject.WITNESS_MAGIC,
                1,
                64,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                b"\0" * 20,
            )
            Path(f"{base}.1").write_bytes(first)
            Path(f"{base}.2").write_bytes(second)
            Path(f"{base}.1").chmod(0o600)
            Path(f"{base}.2").chmod(0o600)
            result = subject.read_lifetimes(base)
            self.assertTrue(result["enabled"]["clipboardEffect"])
            self.assertFalse(result["disabled"]["clipboardEffect"])

            Path(f"{base}.3").write_bytes(second)
            Path(f"{base}.3").chmod(0o600)
            with self.assertRaisesRegex(subject.FixtureError, "invalid_lifetime_witnesses"):
                subject.read_lifetimes(base)


if __name__ == "__main__":
    unittest.main()
