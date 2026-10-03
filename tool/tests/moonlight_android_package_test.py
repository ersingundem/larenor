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
            lock["engineRevision"],
            "moonlight-android-12.2-larenor-embed-v5",
        )
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
                "pairing", "credentialStore", "boundedPairingCancellation",
                "video", "audio", "input", "stream",
                "causalStop", "renderedFrameWitness",
                "acceptedNonZeroPcmWriteWitness",
                "ownedLaunchRiKeyHandoff",
            },
        )
        self.assertEqual(
            [item["path"] for item in lock["patches"]],
            [
                "android/moonlight/patches/0001-embed-library.patch",
                "android/moonlight/patches/0002-nonzero-pcm-witness.patch",
                "android/moonlight/patches/0003-owned-launch-ri-key.patch",
            ],
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

    def test_lock_rejects_non_object_patch_entry_as_bounded_invalid_lock(self):
        lock = json.loads((ROOT / "android/moonlight/source-lock.json").read_text())
        lock["patches"] = [None]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "source-lock.json"
            path.write_text(json.dumps(lock))
            with self.assertRaisesRegex(PackageError, "invalid_lock"):
                load_lock(path)

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
                [(item["class"], item["name"]) for item in receipt["requiredApiMethods"]],
                [
                    ("com/limelight/Game.class", "onConnectionStopCompleted"),
                    ("com/limelight/Game.class", "onVideoFrameRendered"),
                    ("com/limelight/Game.class", "onAudioPcmWritten"),
                    ("com/limelight/Game.class", "createConnection"),
                    (
                        "com/limelight/nvstream/http/NvHTTP.class",
                        "cancelPendingRequests",
                    ),
                    ("com/limelight/nvstream/NvConnection.class", "<init>"),
                ],
            )

            mixed = Path(directory) / "mixed.aar"
            self._aar(mixed, lock, extra_abi="armeabi-v7a")
            with self.assertRaisesRegex(PackageError, "unexpected_aar_abi"):
                package_receipt(mixed, lock)

    def test_transformation_requires_actual_render_and_nonzero_pcm_acceptance_hooks(self):
        lock = load_lock()
        for relative, marker, error in (
            (
                "app/src/main/java/com/limelight/binding/video/MediaCodecDecoderRenderer.java",
                "((Game) activity).onVideoFrameRendered(presentationTimeUs, renderTimeNanos);",
                "rendered_frame_hook_missing",
            ),
            (
                "app/src/main/java/com/limelight/binding/audio/AndroidAudioRenderer.java",
                "boolean containsNonZeroPcm = false;",
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

    def test_transformation_requires_owned_ri_key_factory_clone_and_wipe(self):
        lock = load_lock()
        for relative, marker in (
            (
                "app/src/main/java/com/limelight/Game.java",
                "conn = createConnection(getApplicationContext(),",
            ),
            (
                "app/src/main/java/com/limelight/nvstream/NvConnection.java",
                "byte[] ownedCopy = encodedKey.clone();",
            ),
            (
                "app/src/main/java/com/limelight/nvstream/NvConnection.java",
                "Arrays.fill(ownedCopy, (byte) 0);",
            ),
        ):
            with self.subTest(relative=relative, marker=marker), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                self._transformed_tree(root, lock)
                path = root / relative
                path.write_text(path.read_text().replace(marker, "removed owned RI key contract"))
                with self.assertRaisesRegex(PackageError, "owned_ri_key_handoff_missing"):
                    verify_transformed_tree(root, lock)

    def test_receipt_rejects_legacy_complete_write_only_pcm_hook(self):
        lock = load_lock()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            legacy = root / "legacy-pcm.aar"
            self._aar(legacy, lock, include_nonzero_pcm_api=False)
            with self.assertRaisesRegex(PackageError, "missing_engine_api"):
                package_receipt(legacy, lock)

    def test_receipt_rejects_engine_without_owned_ri_key_factory_and_constructor(self):
        lock = load_lock()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stale = root / "stale-ri-key.aar"
            self._aar(stale, lock, include_owned_ri_key_api=False)
            with self.assertRaisesRegex(PackageError, "missing_engine_api"):
                package_receipt(stale, lock)

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

    def test_old_receipt_and_aar_without_bounded_pairing_cancel_api_fail_closed(self):
        lock = load_lock()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            current = root / "current.aar"
            stale = root / "stale.aar"
            receipt_path = root / "receipt.json"
            self._aar(current, lock)
            current_receipt = package_receipt(current, lock)
            self._aar(stale, lock, include_cancel_api=False)
            stale_claiming_current_contract = json.loads(json.dumps(current_receipt))
            stale_claiming_current_contract["aarSha256"] = hashlib.sha256(
                stale.read_bytes()
            ).hexdigest()
            with zipfile.ZipFile(stale) as archive:
                stale_claiming_current_contract["classesSha256"] = hashlib.sha256(
                    archive.read("classes.jar")
                ).hexdigest()
            receipt_path.write_text(json.dumps(stale_claiming_current_contract))

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
            receipt["patches"][1]["sha256"] = "0" * 64
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
            "public void onAudioPcmWritten(int requestedSamples, int writtenSamples, "
            "boolean containsNonZeroPcm) {}\n"
            "conn = createConnection(getApplicationContext(), host, httpsPort, uniqueId, "
            "config, cryptoProvider, serverCert);\n"
            "protected NvConnection createConnection(Context appContext, "
            "ComputerDetails.AddressTuple host, int httpsPort, String uniqueId, "
            "StreamConfiguration config, LimelightCryptoProvider cryptoProvider, "
            "X509Certificate serverCert) {\n"
            "return new NvConnection(appContext, host, httpsPort, uniqueId, config, "
            "cryptoProvider, serverCert);\n}\n"
        )
        (root / "app/src/main/java/com/limelight/binding/video/MediaCodecDecoderRenderer.java").write_text(
            "if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {\n"
            "setOnFrameRenderedListener\n"
            "((Game) activity).onVideoFrameRendered(presentationTimeUs, renderTimeNanos);\n"
        )
        (root / "app/src/main/java/com/limelight/binding/audio/AndroidAudioRenderer.java").write_text(
            "int writtenSamples = track.write(audioData, 0, audioData.length);\n"
            "if (writtenSamples > 0 && writtenSamples == audioData.length) {\n"
            "boolean containsNonZeroPcm = false;\n"
            "for (short sample : audioData) {\n"
            "if (sample != 0) { containsNonZeroPcm = true; break; }\n"
            "}\n"
            "((Game) context).onAudioPcmWritten(audioData.length, writtenSamples, "
            "containsNonZeroPcm);\n"
        )
        (root / "app/src/main/java/com/limelight/nvstream/NvConnection.java").write_text(
            "public NvConnection(Context appContext, ComputerDetails.AddressTuple host, "
            "int httpsPort, String uniqueId, StreamConfiguration config, "
            "LimelightCryptoProvider cryptoProvider, X509Certificate serverCert, "
            "byte[] remoteInputAesKey, int remoteInputAesKeyId) {\n"
            "importRiAesKey(requireOwnedRiAesKey(remoteInputAesKey, remoteInputAesKeyId));\n}\n"
            "if (keyId < 0) {}\n"
            "if (encodedKey == null || encodedKey.length != 16) {}\n"
            "byte[] ownedCopy = encodedKey.clone();\n"
            "new SecretKeySpec(ownedCopy, \"AES\");\n"
            "Arrays.fill(ownedCopy, (byte) 0);\n"
            "this.context.riKey = remoteInputAesKey;\n"
            "this.context.riKeyId = remoteInputAesKeyId;\n"
        )

    def _aar(
        self,
        path,
        lock,
        extra_abi=None,
        include_current_api=True,
        include_cancel_api=True,
        include_nonzero_pcm_api=True,
        include_owned_ri_key_api=True,
    ):
        classes = io.BytesIO()
        with zipfile.ZipFile(classes, "w") as jar:
            for name in lock["requiredClasses"]:
                if name == "com/limelight/Game.class":
                    jar.writestr(
                        name,
                        self._game_class(
                            include_current_api=include_current_api,
                            include_nonzero_pcm_api=include_nonzero_pcm_api,
                            include_owned_ri_key_api=include_owned_ri_key_api,
                        ),
                    )
                elif name == "com/limelight/nvstream/NvConnection.class":
                    jar.writestr(
                        name,
                        self._nvconnection_class(
                            include_owned_ri_key_api=include_owned_ri_key_api,
                        ),
                    )
                elif name == "com/limelight/nvstream/http/NvHTTP.class":
                    jar.writestr(
                        name,
                        self._nvhttp_class(include_cancel_api=include_cancel_api),
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
    def _game_class(
        *, include_current_api, include_nonzero_pcm_api=True,
        include_owned_ri_key_api=True,
    ):
        method_specs = []
        if include_current_api:
            method_specs = [
                (0x0004 | 0x0100, "onConnectionStopCompleted", "()V"),
                (0x0001 | 0x0100, "onVideoFrameRendered", "(JJ)V"),
                (
                    0x0001 | 0x0100,
                    "onAudioPcmWritten",
                    "(IIZ)V" if include_nonzero_pcm_api else "(II)V",
                ),
            ]
            if include_owned_ri_key_api:
                method_specs.append((
                    0x0004 | 0x0100,
                    "createConnection",
                    "(Landroid/content/Context;Lcom/limelight/nvstream/http/ComputerDetails$AddressTuple;ILjava/lang/String;Lcom/limelight/nvstream/StreamConfiguration;Lcom/limelight/nvstream/http/LimelightCryptoProvider;Ljava/security/cert/X509Certificate;)Lcom/limelight/nvstream/NvConnection;",
                ))
        return MoonlightAndroidPackageTest._class_file(
            "com/limelight/Game", method_specs,
        )

    @staticmethod
    def _nvhttp_class(*, include_cancel_api):
        methods = []
        if include_cancel_api:
            methods.append((0x0001 | 0x0100, "cancelPendingRequests", "()V"))
        return MoonlightAndroidPackageTest._class_file(
            "com/limelight/nvstream/http/NvHTTP", methods,
        )

    @staticmethod
    def _nvconnection_class(*, include_owned_ri_key_api):
        methods = []
        if include_owned_ri_key_api:
            methods.append((
                0x0001 | 0x0100,
                "<init>",
                "(Landroid/content/Context;Lcom/limelight/nvstream/http/ComputerDetails$AddressTuple;ILjava/lang/String;Lcom/limelight/nvstream/StreamConfiguration;Lcom/limelight/nvstream/http/LimelightCryptoProvider;Ljava/security/cert/X509Certificate;[BI)V",
            ))
        return MoonlightAndroidPackageTest._class_file(
            "com/limelight/nvstream/NvConnection", methods,
        )

    @staticmethod
    def _class_file(class_name, method_specs):
        utf8_values = [class_name, "java/lang/Object"]
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
