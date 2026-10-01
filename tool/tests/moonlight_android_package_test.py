import hashlib
import io
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tool"))

from moonlight_android_package import (  # noqa: E402
    PackageError,
    load_lock,
    package_receipt,
    verify_apk,
    verify_install,
    verify_source_tree,
    verify_transformed_tree,
)


class MoonlightAndroidPackageTest(unittest.TestCase):
    def test_repository_lock_pins_complete_upstream_and_runtime_contract(self):
        lock = load_lock()
        self.assertEqual(
            lock["upstream"]["commit"],
            "b48494cb96bff23d8886c4775cc4f39a1075495d",
        )
        self.assertEqual(
            [(item["path"], item["commit"]) for item in lock["submodules"]],
            [
                (
                    "app/src/main/jni/moonlight-core/moonlight-common-c",
                    "874ac9548f1bd6f095ef2b435c42cdde460e7821",
                ),
                (
                    "app/src/main/jni/moonlight-core/moonlight-common-c/enet",
                    "aca87840b57f045a1f7f9299e4b1b9b8e2a5e2f1",
                ),
                (
                    "app/src/main/jni/moonlight-core/moonlight-common-c/nanors",
                    "b1e3c22ca0cdc0bb83e3cd6ed1a2fc77869ed99a",
                ),
            ],
        )
        self.assertEqual(lock["supportedAbis"], ["arm64-v8a", "x86_64"])
        self.assertEqual(lock["variant"], "nonRootRelease")
        self.assertEqual(
            set(lock["engineContracts"]),
            {
                "pairing", "credentialStore", "video", "audio", "input", "stream",
                "causalStop", "renderedFrameWitness", "acceptedPcmWriteWitness",
            },
        )
        self.assertEqual(
            [item["reportedVersion"] for item in lock["bundledNativeArchives"]],
            ["4.0.2", "unknown-upstream-prebuilt"],
        )

    def test_source_tree_requires_exact_clean_git_identity_and_reviewed_blobs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "source"
            root.mkdir()
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            subprocess.run(
                ["git", "-C", str(root), "config", "user.email", "fixture@example.test"],
                check=True,
            )
            subprocess.run(
                ["git", "-C", str(root), "config", "user.name", "Fixture"],
                check=True,
            )
            source = root / "engine.java"
            source.write_text("final class Engine {}\n")
            subprocess.run(["git", "-C", str(root), "add", "engine.java"], check=True)
            subprocess.run(["git", "-C", str(root), "commit", "-qm", "fixture"], check=True)
            commit = self._git(root, "rev-parse", "HEAD")
            tree = self._git(root, "rev-parse", "HEAD^{tree}")
            blob = self._git(root, "hash-object", "engine.java")
            lock = {
                "upstream": {"commit": commit, "tree": tree},
                "submodules": [],
                "reviewedFiles": {"engine.java": blob},
            }
            verify_source_tree(root, lock)
            source.write_text("tampered\n")
            with self.assertRaisesRegex(PackageError, "dirty_source_tree"):
                verify_source_tree(root, lock)

    def test_transformation_keeps_full_engine_and_removes_standalone_entrypoints(self):
        lock = load_lock()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._transformed_tree(root, lock)
            verify_transformed_tree(root, lock)
            manifest = root / "app/src/main/AndroidManifest.xml"
            manifest.write_text(manifest.read_text().replace(
                'android:exported="false"', 'android:exported="true"', 1
            ))
            with self.assertRaisesRegex(PackageError, "unsafe_embedded_manifest"):
                verify_transformed_tree(root, lock)

    def test_receipt_binds_complete_classes_and_exact_two_abi_payload(self):
        lock = load_lock()
        with tempfile.TemporaryDirectory() as directory:
            aar = Path(directory) / "moonlight.aar"
            self._aar(aar, lock)
            receipt = json.loads(json.dumps(package_receipt(aar, lock)))
            self.assertEqual(set(receipt["abis"]), set(lock["supportedAbis"]))
            self.assertEqual(
                {item["name"] for item in receipt["libraries"]["arm64-v8a"]},
                set(lock["requiredLibraries"]),
            )
            self.assertEqual(receipt["sourceCommit"], lock["upstream"]["commit"])
            self.assertEqual(receipt["patches"], lock["patches"])
            self.assertEqual(
                [item["name"] for item in receipt["requiredApiMethods"]],
                [
                    "onConnectionStopCompleted",
                    "onVideoFrameRendered",
                    "onAudioPcmWritten",
                ],
            )

            mixed = Path(directory) / "mixed.aar"
            self._aar(mixed, lock, extra_abi="armeabi-v7a")
            with self.assertRaisesRegex(PackageError, "unexpected_aar_abi"):
                package_receipt(mixed, lock)

    def test_transformation_requires_actual_render_and_pcm_acceptance_hooks(self):
        lock = load_lock()
        for relative, marker, error in (
            (
                "app/src/main/java/com/limelight/binding/video/MediaCodecDecoderRenderer.java",
                "((Game) activity).onVideoFrameRendered(presentationTimeUs, renderTimeNanos);",
                "rendered_frame_hook_missing",
            ),
            (
                "app/src/main/java/com/limelight/binding/audio/AndroidAudioRenderer.java",
                "writtenSamples > 0 && writtenSamples == audioData.length",
                "accepted_pcm_hook_missing",
            ),
        ):
            with self.subTest(relative=relative), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                self._transformed_tree(root, lock)
                path = root / relative
                path.write_text(path.read_text().replace(marker, "removed witness hook"))
                with self.assertRaisesRegex(PackageError, error):
                    verify_transformed_tree(root, lock)

    def test_install_and_apk_require_receipted_native_and_dex_contracts(self):
        lock = load_lock()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            aar = root / "moonlight.aar"
            apk = root / "host.apk"
            receipt_path = root / "receipt.json"
            self._aar(aar, lock)
            receipt = package_receipt(aar, lock)
            receipt_path.write_text(json.dumps(receipt, sort_keys=True))
            verify_install(aar, receipt_path, lock)
            self._apk(apk, aar, lock)
            verify_apk(apk, receipt_path, lock)

            tampered = root / "tampered.apk"
            with zipfile.ZipFile(apk) as source, zipfile.ZipFile(tampered, "w") as target:
                for name in source.namelist():
                    payload = source.read(name)
                    if name.endswith("/libmoonlight-core.so"):
                        payload = b"tampered"
                    target.writestr(name, payload)
            with self.assertRaisesRegex(PackageError, "apk_library_mismatch"):
                verify_apk(tampered, receipt_path, lock)

    def test_receipt_tamper_never_enables_install(self):
        lock = load_lock()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            aar = root / "moonlight.aar"
            receipt_path = root / "receipt.json"
            self._aar(aar, lock)
            receipt = package_receipt(aar, lock)
            receipt["engineRevision"] = "unreviewed"
            receipt_path.write_text(json.dumps(receipt))
            with self.assertRaisesRegex(PackageError, "receipt_mismatch"):
                verify_install(aar, receipt_path, lock)

    def test_old_receipt_and_aar_without_current_hooks_fail_closed(self):
        lock = load_lock()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            current = root / "current.aar"
            stale = root / "stale.aar"
            receipt_path = root / "receipt.json"
            self._aar(current, lock)
            current_receipt = package_receipt(current, lock)
            self._aar(stale, lock, include_current_api=False)
            legacy_receipt = dict(current_receipt)
            legacy_receipt.pop("patches")
            legacy_receipt.pop("requiredApiMethods")
            legacy_receipt["aarSha256"] = hashlib.sha256(stale.read_bytes()).hexdigest()
            with zipfile.ZipFile(stale) as archive:
                legacy_receipt["classesSha256"] = hashlib.sha256(
                    archive.read("classes.jar")
                ).hexdigest()
            receipt_path.write_text(json.dumps(legacy_receipt))

            with self.assertRaisesRegex(PackageError, "missing_engine_api"):
                verify_install(stale, receipt_path, lock)

    def test_patch_identity_is_part_of_install_receipt(self):
        lock = load_lock()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            aar = root / "moonlight.aar"
            receipt_path = root / "receipt.json"
            self._aar(aar, lock)
            receipt = json.loads(json.dumps(package_receipt(aar, lock)))
            receipt["patches"][0]["sha256"] = "0" * 64
            receipt_path.write_text(json.dumps(receipt))

            with self.assertRaisesRegex(PackageError, "receipt_mismatch"):
                verify_install(aar, receipt_path, lock)

    def _transformed_tree(self, root, lock):
        (root / "app/src/main").mkdir(parents=True)
        (root / "app/build.gradle").write_text(
            "apply plugin: 'com.android.library'\n"
            "abiFilters 'arm64-v8a', 'x86_64'\n"
            "buildConfigField \"String\", \"APPLICATION_ID\", "
            "'\"com.ersingundem.larenor\"'\n"
            "consumerProguardFiles 'consumer-rules.pro'\n"
            "minifyEnabled false\n"
        )
        (root / "app/consumer-rules.pro").write_text(
            "-keep class com.limelight.nvstream.jni.** {*;}\n"
        )
        for dependency in lock["mavenDependencies"]:
            with (root / "app/build.gradle").open("a") as stream:
                stream.write(f"implementation '{dependency}'\n")
        (root / "app/src/main/AndroidManifest.xml").write_text(
            '<manifest xmlns:android="http://schemas.android.com/apk/res/android">'
            '<application><provider android:name=".PosterContentProvider" '
            'android:authorities="poster.com.ersingundem.larenor" '
            'android:exported="false"/><activity android:name=".PcView" '
            'android:exported="false"/><activity android:name=".ShortcutTrampoline" '
            'android:exported="false"/><activity android:name=".AppView"/>'
            '<activity android:name=".Game"/></application></manifest>'
        )
        for path in lock["requiredSources"]:
            target = root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("retained upstream engine source\n")
        (root / "app/src/main/java/com/limelight/Game.java").write_text(
            "onConnectionStopStarted();\n"
            "            new Thread() {}\n"
            "conn.stop();\n"
            "                    onConnectionStopCompleted();\n"
            "protected void onConnectionStopStarted() {}\n"
            "protected void onConnectionStopCompleted() {}\n"
            "public void onVideoFrameRendered(long presentationTimeUs, long renderTimeNanos) {}\n"
            "public void onAudioPcmWritten(int requestedSamples, int writtenSamples) {}\n"
        )
        (root / "app/src/main/java/com/limelight/binding/video/MediaCodecDecoderRenderer.java").write_text(
            "if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {\n"
            "setOnFrameRenderedListener\n"
            "((Game) activity).onVideoFrameRendered(presentationTimeUs, renderTimeNanos);\n"
        )
        (root / "app/src/main/java/com/limelight/binding/audio/AndroidAudioRenderer.java").write_text(
            "int writtenSamples = track.write(audioData, 0, audioData.length);\n"
            "if (writtenSamples > 0 && writtenSamples == audioData.length) {\n"
            "((Game) context).onAudioPcmWritten(audioData.length, writtenSamples);\n"
        )

    def _aar(self, path, lock, extra_abi=None, include_current_api=True):
        classes = io.BytesIO()
        with zipfile.ZipFile(classes, "w") as jar:
            for name in lock["requiredClasses"]:
                if name == "com/limelight/Game.class":
                    jar.writestr(
                        name,
                        self._game_class(include_current_api=include_current_api),
                    )
                else:
                    jar.writestr(name, b"fixture")
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("AndroidManifest.xml", b"manifest")
            archive.writestr("classes.jar", classes.getvalue())
            for abi in lock["supportedAbis"]:
                machine = 183 if abi == "arm64-v8a" else 62
                for name in lock["requiredLibraries"]:
                    archive.writestr(f"jni/{abi}/{name}", self._elf(machine))
            if extra_abi:
                archive.writestr(
                    f"jni/{extra_abi}/libmoonlight-core.so", self._elf(40)
                )

    def _apk(self, path, aar, lock):
        dex = b"dex\n035\0" + b"\0" * 128
        dex += b"\0".join(
            f"L{name.removesuffix('.class')};".encode()
            for name in lock["requiredClasses"]
        )
        with zipfile.ZipFile(aar) as source, zipfile.ZipFile(path, "w") as target:
            target.writestr("classes.dex", dex)
            for abi in lock["supportedAbis"]:
                for name in lock["requiredLibraries"]:
                    target.writestr(
                        f"lib/{abi}/{name}", source.read(f"jni/{abi}/{name}")
                    )

    @staticmethod
    def _elf(machine):
        value = bytearray(64)
        value[:6] = b"\x7fELF\x02\x01"
        value[18:20] = struct.pack("<H", machine)
        return bytes(value)

    @staticmethod
    def _game_class(*, include_current_api):
        method_specs = []
        if include_current_api:
            method_specs = [
                (0x0004 | 0x0100, "onConnectionStopCompleted", "()V"),
                (0x0001 | 0x0100, "onVideoFrameRendered", "(JJ)V"),
                (0x0001 | 0x0100, "onAudioPcmWritten", "(II)V"),
            ]
        utf8_values = ["com/limelight/Game", "java/lang/Object"]
        for _access, name, descriptor in method_specs:
            utf8_values.extend((name, descriptor))
        constants = []
        for value in utf8_values:
            encoded = value.encode("utf-8")
            constants.append(b"\x01" + struct.pack(">H", len(encoded)) + encoded)
        constants.insert(1, b"\x07" + struct.pack(">H", 1))
        constants.insert(3, b"\x07" + struct.pack(">H", 3))
        payload = bytearray(b"\xca\xfe\xba\xbe")
        payload += struct.pack(">HHH", 0, 52, len(constants) + 1)
        payload += b"".join(constants)
        payload += struct.pack(">HHHH", 0x0021, 2, 4, 0)
        payload += struct.pack(">H", 0)
        payload += struct.pack(">H", len(method_specs))
        next_index = 5
        for access, _name, _descriptor in method_specs:
            payload += struct.pack(">HHHH", access, next_index, next_index + 1, 0)
            next_index += 2
        payload += struct.pack(">H", 0)
        return bytes(payload)

    @staticmethod
    def _git(root, *args):
        return subprocess.run(
            ["git", "-C", str(root), *args],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()


if __name__ == "__main__":
    unittest.main()
