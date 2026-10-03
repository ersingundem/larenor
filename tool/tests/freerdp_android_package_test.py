import hashlib
import io
import json
from pathlib import Path
import shutil
import struct
import subprocess
import tarfile
import tempfile
import unittest
import zipfile

from tool.freerdp_android_package import (
    EVENT_LISTENER_CLASS,
    GLOBAL_APP_CLASS,
    PackageError,
    REQUIRED_EVENT_LISTENER_API,
    REQUIRED_FREERDP_API,
    REQUIRED_GLOBAL_APP_API,
    REQUIRED_MICROPHONE_CONSTANTS,
    REQUIRED_REMOTE_AUDIO_CONSTANTS,
    REQUIRED_AUDIN_NATIVE_EVIDENCE,
    load_lock,
    package_receipt,
    verify_apk,
    verify_certificate_patch,
    verify_clipboard_patch,
    verify_display_pointer_patch,
    verify_remote_audio_patch,
    verify_install,
    verify_source,
)


ROOT = Path(__file__).resolve().parents[2]


class FreeRdpAndroidPackageTest(unittest.TestCase):
    def test_repository_lock_is_exact_and_matches_runtime_gate(self):
        lock = load_lock()
        self.assertEqual(lock["source"]["version"], "3.31.1")
        self.assertEqual(lock["jniSchema"], 5)
        self.assertEqual(
            lock["engineRevision"],
            "freerdp-3.31.1-63b948ca-remote-access-v5",
        )
        self.assertEqual(lock["supportedAbis"], ["arm64-v8a", "x86_64"])
        self.assertEqual(lock["defaultChannels"], [])
        self.assertEqual(
            [item["path"] for item in lock["patches"]],
            [
                "android/freerdp-certificate-pem.patch",
                "android/freerdp-clipboard-utf8.patch",
                "android/freerdp-display-pointer-v2.patch",
                "android/freerdp-remote-audio-v3.patch",
                "android/freerdp-always-pin-v4.patch",
                "android/freerdp-microphone-v4.patch",
                "android/freerdp-remote-access-v5.patch",
            ],
        )
        self.assertEqual(
            REQUIRED_FREERDP_API,
            (
                ("sendRelativeCursorEvent", "(JIII)Z"),
                ("isRelativeMouseInputSupported", "(J)Z"),
                ("sendMonitorLayout", "(JII)Z"),
                ("sendMonitorLayout", "(JIIII)Z"),
                ("configureGateway", "(JLjava/lang/String;I)Z"),
                ("configureFileTransfer", "(JLjava/lang/String;)Z"),
                ("freeInstanceDrained", "(JI)Z"),
            ),
        )
        self.assertEqual(
            REQUIRED_EVENT_LISTENER_API,
            (
                ("OnDisplayControlReady", "(J)V"),
                ("OnRemoteAudioPlayback", "(JZJJI)V"),
                ("OnMicrophoneCapture", "(JZJJI)V"),
            ),
        )
        self.assertEqual(
            lock["requiredNativeEvidence"],
            [
                "JNI_OnLoad",
                "ConvertWCharNToUtf8Alloc",
                "freerdp_input_send_rel_mouse_event",
                "Java_com_freerdp_freerdpcore_services_LibFreeRDP_freerdp_1send_1relative_1cursor_1event",
                "Java_com_freerdp_freerdpcore_services_LibFreeRDP_freerdp_1is_1relative_1mouse_1input_1supported",
                "Java_com_freerdp_freerdpcore_services_LibFreeRDP_freerdp_1send_1monitor_1layout",
                "OnDisplayControlReady",
                "OnRemoteAudioPlayback",
                "OnVerifyX509Certificate",
                "OnMicrophoneCapture",
                "Java_com_freerdp_freerdpcore_services_LibFreeRDP_freerdp_1configure_1gateway",
                "Java_com_freerdp_freerdpcore_services_LibFreeRDP_freerdp_1configure_1file_1transfer",
                "Java_com_freerdp_freerdpcore_services_LibFreeRDP_freerdp_1drain_1and_1free",
                "LrnXfer",
                "/proc/self/fd/",
            ],
        )

    def test_schema5_receipt_rejects_old_java_missing_audin_and_drive_evidence(self):
        lock = load_lock()
        with tempfile.TemporaryDirectory() as directory:
            aar = Path(directory) / "old.aar"
            self._aar(
                aar, lock, "arm64-v8a",
                microphone_constants={},
            )
            with self.assertRaisesRegex(PackageError, "missing_java_contract"):
                package_receipt(aar, "arm64-v8a", lock)

            self._aar(
                aar, lock, "arm64-v8a",
                audin_evidence=False,
            )
            with self.assertRaisesRegex(PackageError, "missing_audin_evidence"):
                package_receipt(aar, "arm64-v8a", lock)

            self._aar(
                aar, lock, "arm64-v8a",
                java_api=tuple(
                    (0x0001 | 0x0008 | 0x0100, method, descriptor)
                    for method, descriptor in REQUIRED_FREERDP_API[:-1]
                ),
            )
            with self.assertRaisesRegex(PackageError, "missing_java_contract"):
                package_receipt(aar, "arm64-v8a", lock)

            self._aar(
                aar, lock, "arm64-v8a",
                drive_evidence=False,
            )
            with self.assertRaisesRegex(PackageError, "missing_drive_evidence"):
                package_receipt(aar, "arm64-v8a", lock)

    def test_lock_rejects_tampered_or_reordered_reviewed_patches(self):
        lock = load_lock()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "lock.json"
            reordered = json.loads(json.dumps(lock))
            reordered["patches"].reverse()
            path.write_text(json.dumps(reordered))
            with self.assertRaisesRegex(PackageError, "invalid_lock"):
                load_lock(path)

            tampered = json.loads(json.dumps(lock))
            tampered["patches"][1]["sha256"] = "0" * 64
            path.write_text(json.dumps(tampered))
            with self.assertRaisesRegex(PackageError, "invalid_lock"):
                load_lock(path)

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

    def test_receipt_rejects_old_native_without_clipboard_utf8_evidence(self):
        lock = load_lock()
        with tempfile.TemporaryDirectory() as directory:
            aar = Path(directory) / "old-core.aar"
            self._aar(aar, lock, "arm64-v8a", native_evidence=False)
            with self.assertRaisesRegex(PackageError, "missing_native_evidence"):
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
            old_receipt = root / "old-receipt.json"
            old_value = json.loads(json.dumps(value))
            old_value["engineRevision"] = "freerdp-3.31.1-63b948ca"
            old_receipt.write_text(json.dumps(old_value))
            with self.assertRaisesRegex(PackageError, "receipt_mismatch"):
                verify_apk(apk, old_receipt, lock)
            old_value = json.loads(json.dumps(value))
            old_value["jniSchema"] = 1
            old_receipt.write_text(json.dumps(old_value))
            with self.assertRaisesRegex(PackageError, "receipt_mismatch"):
                verify_apk(apk, old_receipt, lock)
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

    def test_clipboard_patch_replaces_modified_utf8_with_bounded_standard_utf8(self):
        lock = load_lock()
        fixture = ROOT / (
            "tool/tests/fixtures/freerdp-3.31.1/android_freerdp.c"
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / (
                "client/Android/Studio/freeRDPCore/src/main/cpp/"
                "android_freerdp.c"
            )
            source.parent.mkdir(parents=True)
            shutil.copyfile(fixture, source)
            self._write_event_source(source.with_name("android_event.c"))

            with self.assertRaisesRegex(PackageError, "invalid_clipboard_patch"):
                verify_clipboard_patch(source)

            for item in lock["patches"][:2]:
                subprocess.run(
                    ["git", "apply", str(ROOT / item["path"])],
                    cwd=root,
                    check=True,
                )
            verify_certificate_patch(source)
            verify_clipboard_patch(source)

            text = source.read_text()
            function = text[text.index("freerdp_1send_1clipboard_1data") :]
            function = function[: function.index("static BOOL android_is_image_mime_supported")]
            self.assertIn("GetStringChars", function)
            self.assertIn("ConvertWCharNToUtf8Alloc", function)
            self.assertIn("SecureZeroMemory", function)
            self.assertNotIn("GetStringUTFChars", function)
            self.assertNotIn("GetStringUTFLength", function)
            self.assertNotIn('WLog_DBG(TAG, "send_clipboard_data: (%s)"', function)
            event_text = source.with_name("android_event.c").read_text()
            self.assertIn(
                "SecureZeroMemory(event->data, event->data_length)", event_text
            )

            source.write_text(source.read_text().replace(
                "ConvertWCharNToUtf8Alloc", "ConvertWCharToUtf8Alloc", 1
            ))
            with self.assertRaisesRegex(PackageError, "invalid_clipboard_patch"):
                verify_clipboard_patch(source)

    def test_display_pointer_patch_is_queued_negotiated_and_scale_bound(self):
        lock = load_lock()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._copy_reviewed_android_sources(root)
            for item in lock["patches"][:4]:
                subprocess.run(
                    ["git", "apply", str(ROOT / item["path"])],
                    cwd=root,
                    check=True,
                )
            verify_display_pointer_patch(root)

            event = root / (
                "client/Android/Studio/freeRDPCore/src/main/cpp/android_event.c"
            )
            event.write_text(event.read_text().replace(
                "freerdp_input_send_rel_mouse_event",
                "freerdp_input_send_mouse_event",
                1,
            ))
            with self.assertRaisesRegex(
                PackageError, "invalid_display_pointer_patch"
            ):
                verify_display_pointer_patch(root)

            self._copy_reviewed_android_sources(root)
            for item in lock["patches"][:4]:
                subprocess.run(
                    ["git", "apply", str(ROOT / item["path"])],
                    cwd=root,
                    check=True,
                )
            display = root / (
                "client/Android/Studio/freeRDPCore/src/main/cpp/android_disp.c"
            )
            display.write_text(display.read_text().replace(
                " || (width & 1) != 0", "", 1
            ))
            with self.assertRaisesRegex(
                PackageError, "invalid_display_pointer_patch"
            ):
                verify_display_pointer_patch(root)

    def test_display_pointer_patch_rejects_unnegotiated_query_and_stale_scale(self):
        lock = load_lock()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._copy_reviewed_android_sources(root)
            for item in lock["patches"][:4]:
                subprocess.run(
                    ["git", "apply", str(ROOT / item["path"])],
                    cwd=root,
                    check=True,
                )
            native = root / (
                "client/Android/Studio/freeRDPCore/src/main/cpp/android_freerdp.c"
            )
            native.write_text(native.read_text().replace(
                "FreeRDP_HasRelativeMouseEvent",
                "FreeRDP_UnicodeInput",
                1,
            ))
            with self.assertRaisesRegex(
                PackageError, "invalid_display_pointer_patch"
            ):
                verify_display_pointer_patch(root)

            self._copy_reviewed_android_sources(root)
            for item in lock["patches"][:4]:
                subprocess.run(
                    ["git", "apply", str(ROOT / item["path"])],
                    cwd=root,
                    check=True,
                )
            native = root / (
                "client/Android/Studio/freeRDPCore/src/main/cpp/android_freerdp.c"
            )
            native.write_text(native.read_text().replace(
                "LibFreeRDP_freerdp_1is_1relative_1mouse_1input_1supported",
                "LibFreeRDP_ freerdp_1is_1relative_1mouse_1input_1supported",
                1,
            ))
            with self.assertRaisesRegex(
                PackageError, "invalid_display_pointer_patch"
            ):
                verify_display_pointer_patch(root)

            self._copy_reviewed_android_sources(root)
            for item in lock["patches"][:4]:
                subprocess.run(
                    ["git", "apply", str(ROOT / item["path"])],
                    cwd=root,
                    check=True,
                )
            display = root / (
                "client/Android/Studio/freeRDPCore/src/main/cpp/android_disp.c"
            )
            display.write_text(display.read_text().replace(
                "layout.DesktopScaleFactor = desktopScaleFactor;",
                "layout.DesktopScaleFactor = freerdp_settings_get_uint32(settings, FreeRDP_DesktopScaleFactor);",
                1,
            ))
            with self.assertRaisesRegex(
                PackageError, "invalid_display_pointer_patch"
            ):
                verify_display_pointer_patch(root)

    def test_display_ready_callback_is_exact_instance_bound_and_after_peer_caps(self):
        lock = load_lock()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._copy_reviewed_android_sources(root)
            for item in lock["patches"][:4]:
                subprocess.run(
                    ["git", "apply", str(ROOT / item["path"])],
                    cwd=root,
                    check=True,
                )
            verify_display_pointer_patch(root)

            display = root / (
                "client/Android/Studio/freeRDPCore/src/main/cpp/android_disp.c"
            )
            text = display.read_text()
            assignment = "\tafc->dispReady = TRUE;\n"
            callback = (
                '\tfreerdp_callback("OnDisplayControlReady", "(J)V",\n'
                "\t                 (jlong)afc->common.context.instance);\n"
            )
            self.assertEqual(text.count(assignment), 1)
            self.assertEqual(text.count(callback), 1)
            display.write_text(
                text.replace(assignment, "", 1).replace(
                    callback, callback + assignment, 1
                )
            )
            with self.assertRaisesRegex(
                PackageError, "invalid_display_pointer_patch"
            ):
                verify_display_pointer_patch(root)

            self._copy_reviewed_android_sources(root)
            for item in lock["patches"][:4]:
                subprocess.run(
                    ["git", "apply", str(ROOT / item["path"])],
                    cwd=root,
                    check=True,
                )
            display = root / (
                "client/Android/Studio/freeRDPCore/src/main/cpp/android_disp.c"
            )
            display.write_text(display.read_text().replace(
                "if (!afc->dispReady || !disp || !disp->SendMonitorLayout)",
                "if (!disp || !disp->SendMonitorLayout)",
                1,
            ))
            with self.assertRaisesRegex(
                PackageError, "invalid_display_pointer_patch"
            ):
                verify_display_pointer_patch(root)

            self._copy_reviewed_android_sources(root)
            for item in lock["patches"][:4]:
                subprocess.run(
                    ["git", "apply", str(ROOT / item["path"])],
                    cwd=root,
                    check=True,
                )
            display = root / (
                "client/Android/Studio/freeRDPCore/src/main/cpp/android_disp.c"
            )
            display.write_text(display.read_text().replace(
                "if (requestedArea > maximumArea)",
                "if (FALSE)",
                1,
            ))
            with self.assertRaisesRegex(
                PackageError, "invalid_display_pointer_patch"
            ):
                verify_display_pointer_patch(root)

    def test_receipt_rejects_old_or_wrong_java_display_pointer_contract(self):
        lock = load_lock()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            old = root / "old.aar"
            self._aar(old, lock, "x86_64", java_api=())
            with self.assertRaisesRegex(PackageError, "missing_java_contract"):
                package_receipt(old, "x86_64", lock)

            wrong = root / "wrong.aar"
            self._aar(
                wrong,
                lock,
                "x86_64",
                java_api=(
                    (0x0001 | 0x0008 | 0x0100, "sendRelativeCursorEvent", "(JIII)Z"),
                    (0x0001 | 0x0008 | 0x0100, "isRelativeMouseInputSupported", "(J)Z"),
                    (0x0001 | 0x0008 | 0x0100, "sendMonitorLayout", "(JII)Z"),
                ),
            )
            with self.assertRaisesRegex(PackageError, "missing_java_contract"):
                package_receipt(wrong, "x86_64", lock)

            stale_callback = root / "stale-callback.aar"
            self._aar(stale_callback, lock, "x86_64", event_listener_api=())
            with self.assertRaisesRegex(PackageError, "missing_java_contract"):
                package_receipt(stale_callback, "x86_64", lock)

            wrong_callback = root / "wrong-callback.aar"
            self._aar(
                wrong_callback,
                lock,
                "x86_64",
                event_listener_api=((0x0001 | 0x0400, "OnDisplayControlReady", "(I)V"),),
            )
            with self.assertRaisesRegex(PackageError, "missing_java_contract"):
                package_receipt(wrong_callback, "x86_64", lock)

            stale_audio = root / "stale-audio.aar"
            self._aar(
                stale_audio,
                lock,
                "x86_64",
                event_listener_api=(
                    (0x0001, "OnDisplayControlReady", "(J)V"),
                ),
            )
            with self.assertRaisesRegex(PackageError, "missing_java_contract"):
                package_receipt(stale_audio, "x86_64", lock)

            wrong_audio_state = root / "wrong-audio-state.aar"
            constants = dict(REQUIRED_REMOTE_AUDIO_CONSTANTS)
            constants["REMOTE_AUDIO_BUFFER_COMPLETED"] = 2
            self._aar(
                wrong_audio_state,
                lock,
                "x86_64",
                remote_audio_constants=constants,
            )
            with self.assertRaisesRegex(PackageError, "missing_java_contract"):
                package_receipt(wrong_audio_state, "x86_64", lock)

    def test_remote_audio_patch_is_bounded_causal_and_lifecycle_bound(self):
        lock = load_lock()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._copy_reviewed_android_sources(root)
            for item in lock["patches"][:4]:
                subprocess.run(
                    ["git", "apply", str(ROOT / item["path"])],
                    cwd=root,
                    check=True,
                )
            verify_remote_audio_patch(root)

            io_source = root / "channels/rdpsnd/client/opensles/opensl_io.c"
            io_source.write_text(io_source.read_text().replace(
                "GetTickCount64() + 2000ULL", "GetTickCount64() + INFINITE", 1
            ))
            with self.assertRaisesRegex(PackageError, "invalid_remote_audio_patch"):
                verify_remote_audio_patch(root)

    def test_remote_audio_patch_rejects_enqueue_and_teardown_shortcuts(self):
        lock = load_lock()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._copy_reviewed_android_sources(root)
            for item in lock["patches"][:4]:
                subprocess.run(
                    ["git", "apply", str(ROOT / item["path"])],
                    cwd=root,
                    check=True,
                )
            io_source = root / "channels/rdpsnd/client/opensles/opensl_io.c"
            text = io_source.read_text()
            offset = text.index("int android_AudioOut(")
            tail = text[offset:].replace(
                "if (result != SL_RESULT_SUCCESS)",
                "if (FALSE)",
                1,
            )
            io_source.write_text(text[:offset] + tail)
            with self.assertRaisesRegex(PackageError, "invalid_remote_audio_patch"):
                verify_remote_audio_patch(root)

            self._copy_reviewed_android_sources(root)
            for item in lock["patches"][:4]:
                subprocess.run(
                    ["git", "apply", str(ROOT / item["path"])],
                    cwd=root,
                    check=True,
                )
            io_source = root / "channels/rdpsnd/client/opensles/opensl_io.c"
            io_source.write_text(io_source.read_text().replace(
                "if (!p->closing && p->head)", "if (p->head)", 1
            ))
            with self.assertRaisesRegex(PackageError, "invalid_remote_audio_patch"):
                verify_remote_audio_patch(root)

    def test_remote_audio_patch_rejects_wrong_public_state_contract(self):
        lock = load_lock()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._copy_reviewed_android_sources(root)
            for item in lock["patches"][:4]:
                subprocess.run(
                    ["git", "apply", str(ROOT / item["path"])],
                    cwd=root,
                    check=True,
                )
            java = root / (
                "client/Android/Studio/freeRDPCore/src/main/java/"
                "com/freerdp/freerdpcore/services/LibFreeRDP.java"
            )
            java.write_text(java.read_text().replace(
                "REMOTE_AUDIO_BUFFER_COMPLETED = 3",
                "REMOTE_AUDIO_BUFFER_COMPLETED = 2",
                1,
            ))
            with self.assertRaisesRegex(PackageError, "invalid_remote_audio_patch"):
                verify_remote_audio_patch(root)

    def test_remote_audio_patch_serializes_publication_and_fails_counter_exhaustion(self):
        lock = load_lock()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._copy_reviewed_android_sources(root)
            for item in lock["patches"][:4]:
                subprocess.run(
                    ["git", "apply", str(ROOT / item["path"])],
                    cwd=root,
                    check=True,
                )
            plugin = root / "channels/rdpsnd/client/opensles/rdpsnd_opensles.c"
            plugin.write_text(plugin.read_text().replace(
                "opensles->acceptedCount >= LARENOR_JS_SAFE_COUNTER_MAX",
                "FALSE",
                1,
            ))
            with self.assertRaisesRegex(PackageError, "invalid_remote_audio_patch"):
                verify_remote_audio_patch(root)

            self._copy_reviewed_android_sources(root)
            for item in lock["patches"][:4]:
                subprocess.run(
                    ["git", "apply", str(ROOT / item["path"])],
                    cwd=root,
                    check=True,
                )
            plugin = root / "channels/rdpsnd/client/opensles/rdpsnd_opensles.c"
            text = plugin.read_text()
            publish = (
                "\tif (publish)\n"
                "\t\trdpsnd_opensles_publish(opensles, deviceOpen, acceptedCount, completedCount,\n"
                "\t\t                        publishedState);\n"
                "\tLeaveCriticalSection(&opensles->observerLock);\n"
            )
            unlocked = (
                "\tLeaveCriticalSection(&opensles->observerLock);\n"
                "\tif (publish)\n"
                "\t\trdpsnd_opensles_publish(opensles, deviceOpen, acceptedCount, completedCount,\n"
                "\t\t                        publishedState);\n"
            )
            self.assertIn(publish, text)
            plugin.write_text(text.replace(publish, unlocked, 1))
            with self.assertRaisesRegex(PackageError, "invalid_remote_audio_patch"):
                verify_remote_audio_patch(root)

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

    @staticmethod
    def _write_event_source(path):
        path.write_text(
            """static void android_event_clipboard_free(ANDROID_EVENT_CLIPBOARD* event)
{
\tif (event)
\t{
\t\tfree(event->data);
\t\tfree(event->mimeType);
\t\tfree(event);
\t}
}

BOOL android_event_queue_init(freerdp* inst)
"""
        )

    @staticmethod
    def _copy_reviewed_android_sources(root):
        fixture = ROOT / "tool/tests/fixtures/freerdp-3.31.1"
        relative = {
            "LibFreeRDP.java": (
                "client/Android/Studio/freeRDPCore/src/main/java/"
                "com/freerdp/freerdpcore/services/LibFreeRDP.java"
            ),
            "android_freerdp.c": (
                "client/Android/Studio/freeRDPCore/src/main/cpp/android_freerdp.c"
            ),
            "android_freerdp.h": (
                "client/Android/Studio/freeRDPCore/src/main/cpp/android_freerdp.h"
            ),
            "android_event.h": (
                "client/Android/Studio/freeRDPCore/src/main/cpp/android_event.h"
            ),
            "android_event.c": (
                "client/Android/Studio/freeRDPCore/src/main/cpp/android_event.c"
            ),
            "android_disp.h": (
                "client/Android/Studio/freeRDPCore/src/main/cpp/android_disp.h"
            ),
            "android_disp.c": (
                "client/Android/Studio/freeRDPCore/src/main/cpp/android_disp.c"
            ),
            "opensl_io.c": (
                "channels/rdpsnd/client/opensles/opensl_io.c"
            ),
            "opensl_io.h": (
                "channels/rdpsnd/client/opensles/opensl_io.h"
            ),
            "rdpsnd_opensles.c": (
                "channels/rdpsnd/client/opensles/rdpsnd_opensles.c"
            ),
            "event.h": "include/freerdp/event.h",
        }
        for source_name, target_name in relative.items():
            target = root / target_name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(fixture / source_name, target)

    def _aar(
        self,
        path,
        lock,
        abi,
        second=None,
        native_evidence=True,
        java_api=None,
        event_listener_api=None,
        remote_audio_constants=None,
        microphone_constants=None,
        audin_evidence=True,
        drive_evidence=True,
    ):
        classes = io.BytesIO()
        with zipfile.ZipFile(classes, "w") as jar:
            for name in lock["requiredClasses"]:
                if name == "com/freerdp/freerdpcore/services/LibFreeRDP.class":
                    methods = java_api
                    if methods is None:
                        methods = tuple(
                            (0x0001 | 0x0008 | 0x0100, method, descriptor)
                            for method, descriptor in REQUIRED_FREERDP_API
                        )
                    jar.writestr(
                        name,
                        self._class_file(
                            "com/freerdp/freerdpcore/services/LibFreeRDP",
                            methods,
                            tuple(
                                (
                                    0x0001 | 0x0008 | 0x0010,
                                    field,
                                    "I",
                                    value,
                                )
                                for field, value in ({
                                    **(REQUIRED_REMOTE_AUDIO_CONSTANTS
                                       if remote_audio_constants is None
                                       else remote_audio_constants),
                                    **(REQUIRED_MICROPHONE_CONSTANTS
                                       if microphone_constants is None
                                       else microphone_constants),
                                }).items()
                            ),
                        ),
                    )
                elif name == GLOBAL_APP_CLASS:
                    jar.writestr(
                        name,
                        self._class_file(
                            "com/freerdp/freerdpcore/application/GlobalApp",
                            tuple(
                                (0x0001 | 0x0008, method, descriptor)
                                for method, descriptor in REQUIRED_GLOBAL_APP_API
                            ),
                        ),
                    )
                elif name == EVENT_LISTENER_CLASS:
                    methods = event_listener_api
                    if methods is None:
                        methods = tuple(
                            (0x0001, method, descriptor)
                            for method, descriptor in REQUIRED_EVENT_LISTENER_API
                        )
                    jar.writestr(
                        name,
                        self._class_file(
                            "com/freerdp/freerdpcore/services/LibFreeRDP$EventListener",
                            methods,
                        ),
                    )
                else:
                    jar.writestr(name, b"fixture")
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("AndroidManifest.xml", b"manifest")
            archive.writestr("classes.jar", classes.getvalue())
            for name in lock["requiredLibraries"]:
                payload = self._elf(183 if abi == "arm64-v8a" else 62)
                if name == "libfreerdp-android.so":
                    evidence = lock.get("requiredNativeEvidence", ["JNI_OnLoad"])
                    payload += b"JNI_OnLoad"
                    if native_evidence:
                        payload += b"".join(item.encode() for item in evidence)
                if name == "libfreerdp-client3.so" and audin_evidence:
                    payload += REQUIRED_AUDIN_NATIVE_EVIDENCE.encode()
                    if drive_evidence:
                        payload += b"".join(
                            item.encode()
                            for item in lock.get("requiredDriveEvidence", [])
                        )
                archive.writestr(f"jni/{abi}/{name}", payload)
            if second:
                archive.writestr(f"jni/{second}/extra.so", self._elf(62))

    @staticmethod
    def _class_file(class_name, method_specs, field_specs=()):
        constants = []

        def utf8(value):
            encoded = value.encode("utf-8")
            constants.append(b"\x01" + struct.pack(">H", len(encoded)) + encoded)
            return len(constants)

        def class_info(name_index):
            constants.append(b"\x07" + struct.pack(">H", name_index))
            return len(constants)

        def integer(value):
            constants.append(b"\x03" + struct.pack(">i", value))
            return len(constants)

        class_name_index = utf8(class_name)
        this_class_index = class_info(class_name_index)
        object_name_index = utf8("java/lang/Object")
        super_class_index = class_info(object_name_index)
        constant_value_index = utf8("ConstantValue") if field_specs else None
        field_indexes = []
        for access, name, descriptor, value in field_specs:
            field_indexes.append(
                (access, utf8(name), utf8(descriptor), integer(value))
            )
        method_indexes = []
        for access, name, descriptor in method_specs:
            method_indexes.append((access, utf8(name), utf8(descriptor)))

        payload = bytearray(b"\xca\xfe\xba\xbe")
        payload += struct.pack(">HHH", 0, 52, len(constants) + 1)
        payload += b"".join(constants)
        payload += struct.pack(">HHHH", 0x0021, this_class_index, super_class_index, 0)
        payload += struct.pack(">H", len(field_indexes))
        for access, name_index, descriptor_index, value_index in field_indexes:
            payload += struct.pack(">HHHH", access, name_index, descriptor_index, 1)
            payload += struct.pack(">HIH", constant_value_index, 2, value_index)
        payload += struct.pack(">H", len(method_indexes))
        for access, name_index, descriptor_index in method_indexes:
            payload += struct.pack(">HHHH", access, name_index, descriptor_index, 0)
        payload += struct.pack(">H", 0)
        return bytes(payload)

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
