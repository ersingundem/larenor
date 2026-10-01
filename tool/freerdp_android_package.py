#!/usr/bin/env python3
"""Verify and receipt the exact FreeRDP Android native package input."""

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import struct
import sys
import tarfile
import zipfile


ROOT = Path(__file__).resolve().parents[1]
LOCK_PATH = ROOT / "android/freerdp-native.lock.json"
KOTLIN_PATH = ROOT / (
    "android/app/src/main/kotlin/com/ersingundem/larenor/rdp/"
    "RdpFreeRdpEngine.kt"
)
HEX40 = re.compile(r"[0-9a-f]{40}")
HEX64 = re.compile(r"[0-9a-f]{64}")
ABI_MACHINE = {"arm64-v8a": 183, "x86_64": 62}


class PackageError(ValueError):
    pass


def _require(condition, code):
    if not condition:
        raise PackageError(code)


def _sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _git_blob(data):
    header = f"blob {len(data)}\0".encode()
    return hashlib.sha1(header + data).hexdigest()


def load_lock(path=LOCK_PATH):
    try:
        value = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise PackageError("invalid_lock") from error
    _require(set(value) == {
        "schemaVersion", "engineRevision", "source", "reviewedFiles",
        "patches",
        "toolchain", "supportedAbis", "jniSchema", "defaultChannels",
        "requiredLibraries", "requiredClasses", "requiredJniSymbols",
        "requiredNativeEvidence",
    }, "invalid_lock")
    _require(value["schemaVersion"] == 1 and value["jniSchema"] == 1,
             "invalid_lock")
    source = value["source"]
    _require(set(source) == {"version", "commit", "url", "sha256"},
             "invalid_lock")
    _require(source["version"] == "3.31.1", "invalid_lock")
    _require(HEX40.fullmatch(source["commit"] or ""), "invalid_lock")
    _require(HEX64.fullmatch(source["sha256"] or ""), "invalid_lock")
    _require(source["url"] == (
        "https://github.com/FreeRDP/FreeRDP/releases/download/3.31.1/"
        "freerdp-3.31.1.tar.gz"
    ), "invalid_lock")
    reviewed = value["reviewedFiles"]
    _require(type(reviewed) is dict and len(reviewed) == 8 and
             all(type(name) is str and HEX40.fullmatch(digest or "")
                 for name, digest in reviewed.items()), "invalid_lock")
    patches = value["patches"]
    try:
        expected_patches = [
            {
                "path": "android/freerdp-certificate-pem.patch",
                "sha256": _sha256(ROOT / "android/freerdp-certificate-pem.patch"),
            },
            {
                "path": "android/freerdp-clipboard-utf8.patch",
                "sha256": _sha256(ROOT / "android/freerdp-clipboard-utf8.patch"),
            },
        ]
    except OSError as error:
        raise PackageError("invalid_lock") from error
    _require(
        type(patches) is list
        and len(patches) == 2
        and patches == expected_patches,
        "invalid_lock",
    )
    _require(value["toolchain"] == {
        "java": "17", "androidPlatform": "37.0",
        "androidBuildTools": "37.0.0", "ndk": "29.0.13113456",
        "cmake": "4.1.2", "gradle": "9.6.1",
    }, "invalid_lock")
    _require(value["supportedAbis"] == ["arm64-v8a", "x86_64"],
             "invalid_lock")
    _require(value["defaultChannels"] == [], "invalid_lock")
    _require(value["requiredLibraries"] == [
        "libfreerdp-android.so", "libfreerdp-client3.so",
        "libfreerdp3.so", "libwinpr3.so",
    ], "invalid_lock")
    _require(value["requiredClasses"] == [
        "com/freerdp/freerdpcore/services/LibFreeRDP.class",
        "com/freerdp/freerdpcore/services/LibFreeRDP$EventListener.class",
        "com/freerdp/freerdpcore/services/LibFreeRDP$UIEventListener.class",
        "com/freerdp/freerdpcore/application/GlobalApp.class",
        "com/freerdp/freerdpcore/application/SessionState.class",
    ], "invalid_lock")
    _require(value["requiredJniSymbols"] == ["JNI_OnLoad"], "invalid_lock")
    _require(
        value["requiredNativeEvidence"]
        == ["JNI_OnLoad", "ConvertWCharNToUtf8Alloc"],
        "invalid_lock",
    )
    kotlin = KOTLIN_PATH.read_text()
    for expected in (
        f'const val VERSION = "{source["version"]}"',
        f'const val SOURCE_COMMIT = "{source["commit"]}"',
        f'const val SOURCE_SHA256 = "{source["sha256"]}"',
        f'const val ENGINE_REVISION = "{value["engineRevision"]}"',
    ):
        _require(expected in kotlin, "kotlin_lock_mismatch")
    return value


def verify_source(archive, lock):
    _require(archive.is_file() and _sha256(archive) == lock["source"]["sha256"],
             "source_digest_mismatch")
    prefix = f'freerdp-{lock["source"]["version"]}/'
    try:
        with tarfile.open(archive, "r:gz") as bundle:
            names = bundle.getnames()
            _require(names and all(
                PurePosixPath(name).parts and
                PurePosixPath(name).parts[0] == prefix[:-1] and
                ".." not in PurePosixPath(name).parts and
                not PurePosixPath(name).is_absolute()
                for name in names
            ), "unsafe_source_archive")
            for relative, expected in lock["reviewedFiles"].items():
                member = bundle.getmember(prefix + relative)
                _require(member.isfile() and member.size <= 2 * 1024 * 1024,
                         "invalid_reviewed_source")
                stream = bundle.extractfile(member)
                _require(stream is not None and _git_blob(stream.read()) == expected,
                         "reviewed_source_mismatch")
    except (tarfile.TarError, KeyError, OSError) as error:
        raise PackageError("invalid_source_archive") from error


def _elf_machine(data):
    _require(len(data) >= 20 and data[:4] == b"\x7fELF" and data[5] in (1, 2),
             "invalid_native_library")
    order = "<" if data[5] == 1 else ">"
    return struct.unpack(order + "H", data[18:20])[0]


def verify_certificate_patch(source):
    try:
        text = source.read_text(encoding="utf-8")
    except OSError as error:
        raise PackageError("invalid_certificate_patch") from error
    function = text.find("static BOOL android_pre_connect(freerdp* instance)")
    following = text.find("static BOOL android_post_connect", function + 1)
    marker = (
        "if (!freerdp_settings_set_bool(settings, "
        "FreeRDP_CertificateCallbackPreferPEM, TRUE))\n\t\treturn FALSE;"
    )
    position = text.find(marker)
    declaration = text.find(
        "rdpSettings* settings = instance->context->settings;", function
    )
    subscription = text.find(
        "int rc = PubSub_SubscribeChannelConnected", function
    )
    _require(
        function >= 0
        and following > function
        and text.count(marker) == 1
        and function < declaration < position < subscription < following,
        "invalid_certificate_patch",
    )


def verify_clipboard_patch(source):
    try:
        text = source.read_text(encoding="utf-8")
    except OSError as error:
        raise PackageError("invalid_clipboard_patch") from error
    start = text.find(
        "Java_com_freerdp_freerdpcore_services_LibFreeRDP_"
        "freerdp_1send_1clipboard_1data"
    )
    following = text.find("static BOOL android_is_image_mime_supported", start + 1)
    function = text[start:following] if start >= 0 and following > start else ""
    required = (
        "#define ANDROID_CLIPBOARD_TEXT_MAX_BYTES (64U * 1024U)",
        "#include <winpr/crt.h>",
        "#include <winpr/string.h>",
        "GetStringLength(env, jdata)",
        "GetStringChars(env, jdata, nullptr)",
        "android_copy_clipboard_utf16(chars, wide_length, wide)",
        "ConvertWCharNToUtf8Alloc(wide, (size_t)wide_length, &data_length)",
        "data_length > ANDROID_CLIPBOARD_TEXT_MAX_BYTES",
        'android_push_clipboard_event(inst, data, data_length, "text/plain")',
        "SecureZeroMemory(data, data_length + 1U)",
        "SecureZeroMemory(wide, ((size_t)wide_length + 1U) * sizeof(WCHAR))",
        "ReleaseStringChars(env, jdata, chars)",
    )
    helper_start = text.find("static BOOL android_copy_clipboard_utf16")
    helper_end = start
    helper = text[helper_start:helper_end] if 0 <= helper_start < helper_end else ""
    event_source = source.with_name("android_event.c")
    try:
        event_text = event_source.read_text(encoding="utf-8")
    except OSError as error:
        raise PackageError("invalid_clipboard_patch") from error
    event_start = event_text.find("static void android_event_clipboard_free")
    event_following = event_text.find("BOOL android_event_queue_init", event_start + 1)
    event_free = (
        event_text[event_start:event_following]
        if event_start >= 0 and event_following > event_start
        else ""
    )
    _require(
        function
        and all(marker in text if marker.startswith("#") else marker in function
                for marker in required)
        and "value == 0" in helper
        and "value >= 0xD800U" in helper
        and "value <= 0xDBFFU" in helper
        and "chars[x + 1] < 0xDC00U" in helper
        and "chars[x + 1] > 0xDFFFU" in helper
        and "value >= 0xDC00U" in helper
        and "value <= 0xDFFFU" in helper
        and "GetStringUTFChars" not in function
        and "GetStringUTFLength" not in function
        and 'send_clipboard_data: (%s)' not in function
        and function.find("GetStringChars")
        < function.find("ConvertWCharNToUtf8Alloc")
        < function.find("android_push_clipboard_event")
        < function.find("SecureZeroMemory(data")
        and "SecureZeroMemory(event->data, event->data_length)" in event_free
        and event_free.find("SecureZeroMemory(event->data")
        < event_free.find("free(event->data)"),
        "invalid_clipboard_patch",
    )


def package_receipt(aar, abi, lock):
    _require(abi in lock["supportedAbis"], "unsupported_abi")
    _require(aar.is_file() and aar.stat().st_size <= 512 * 1024 * 1024,
             "invalid_aar")
    prefix = f"jni/{abi}/"
    try:
        with zipfile.ZipFile(aar) as bundle:
            names = bundle.namelist()
            _require("AndroidManifest.xml" in names and "classes.jar" in names,
                     "invalid_aar")
            classes = bundle.read("classes.jar")
            with zipfile.ZipFile(__import__("io").BytesIO(classes)) as jar:
                class_names = set(jar.namelist())
                _require(all(name in class_names for name in lock["requiredClasses"]),
                         "missing_java_contract")
            native = [name for name in names if name.startswith("jni/") and
                      name.endswith(".so")]
            _require(native and all(name.startswith(prefix) for name in native),
                     "mixed_abi_aar")
            entries = []
            by_name = {PurePosixPath(name).name: name for name in native}
            for required in lock["requiredLibraries"]:
                _require(required in by_name, "missing_native_library")
                data = bundle.read(by_name[required])
                _require(_elf_machine(data) == ABI_MACHINE[abi],
                         "wrong_native_architecture")
                entries.append({
                    "name": required,
                    "size": len(data),
                    "sha256": hashlib.sha256(data).hexdigest(),
                })
            primary = bundle.read(by_name["libfreerdp-android.so"])
            _require(all(symbol.encode() in primary for symbol in lock["requiredJniSymbols"]),
                     "missing_jni_symbol")
            _require(
                all(
                    evidence.encode() in primary
                    for evidence in lock["requiredNativeEvidence"]
                ),
                "missing_native_evidence",
            )
    except (zipfile.BadZipFile, KeyError, OSError) as error:
        raise PackageError("invalid_aar") from error
    return {
        "schemaVersion": 1,
        "engineRevision": lock["engineRevision"],
        "sourceCommit": lock["source"]["commit"],
        "sourceSha256": lock["source"]["sha256"],
        "abi": abi,
        "aarSha256": _sha256(aar),
        "classesSha256": hashlib.sha256(classes).hexdigest(),
        "patches": lock["patches"],
        "defaultChannels": [],
        "libraries": entries,
    }


def verify_install(aar, receipt_path, lock):
    try:
        receipt = json.loads(receipt_path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise PackageError("invalid_receipt") from error
    _require(type(receipt) is dict and receipt.get("abi") in lock["supportedAbis"],
             "invalid_receipt")
    _require(receipt == package_receipt(aar, receipt["abi"], lock),
             "receipt_mismatch")


def _verify_receipt_contract(receipt, lock):
    _require(
        type(receipt) is dict
        and set(receipt) == {
            "schemaVersion",
            "engineRevision",
            "sourceCommit",
            "sourceSha256",
            "abi",
            "aarSha256",
            "classesSha256",
            "patches",
            "defaultChannels",
            "libraries",
        }
        and receipt["schemaVersion"] == 1
        and receipt["engineRevision"] == lock["engineRevision"]
        and receipt["sourceCommit"] == lock["source"]["commit"]
        and receipt["sourceSha256"] == lock["source"]["sha256"]
        and receipt["abi"] in lock["supportedAbis"]
        and type(receipt["aarSha256"]) is str
        and HEX64.fullmatch(receipt["aarSha256"] or "")
        and type(receipt["classesSha256"]) is str
        and HEX64.fullmatch(receipt["classesSha256"] or "")
        and receipt["patches"] == lock["patches"]
        and receipt["defaultChannels"] == [],
        "receipt_mismatch",
    )
    libraries = receipt["libraries"]
    _require(
        type(libraries) is list
        and all(
            type(item) is dict
            and set(item) == {"name", "size", "sha256"}
            and type(item["size"]) is int
            and item["size"] > 0
            and type(item["sha256"]) is str
            and HEX64.fullmatch(item["sha256"] or "")
            for item in libraries
        )
        and [item["name"] for item in libraries] == lock["requiredLibraries"],
        "receipt_mismatch",
    )


def verify_apk(apk, receipt_path, lock):
    try:
        receipt = json.loads(receipt_path.read_text())
        _verify_receipt_contract(receipt, lock)
        with zipfile.ZipFile(apk) as bundle:
            for item in receipt["libraries"]:
                data = bundle.read(f'lib/{receipt["abi"]}/{item["name"]}')
                _require(hashlib.sha256(data).hexdigest() == item["sha256"],
                         "apk_library_mismatch")
    except (OSError, KeyError, zipfile.BadZipFile, json.JSONDecodeError) as error:
        raise PackageError("invalid_apk") from error


def main(argv=None):
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("verify-lock")
    source = sub.add_parser("verify-source")
    source.add_argument("archive", type=Path)
    patch = sub.add_parser("verify-patch")
    patch.add_argument("source", type=Path)
    receipt = sub.add_parser("receipt")
    receipt.add_argument("aar", type=Path)
    receipt.add_argument("--abi", required=True)
    receipt.add_argument("--output", type=Path, required=True)
    install = sub.add_parser("verify-install")
    install.add_argument("aar", type=Path)
    install.add_argument("receipt", type=Path)
    apk = sub.add_parser("verify-apk")
    apk.add_argument("apk", type=Path)
    apk.add_argument("receipt", type=Path)
    args = parser.parse_args(argv)
    try:
        lock = load_lock()
        if args.command == "verify-source":
            verify_source(args.archive, lock)
        elif args.command == "verify-patch":
            verify_certificate_patch(args.source)
            verify_clipboard_patch(args.source)
        elif args.command == "receipt":
            value = package_receipt(args.aar, args.abi, lock)
            args.output.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
        elif args.command == "verify-install":
            verify_install(args.aar, args.receipt, lock)
        elif args.command == "verify-apk":
            verify_apk(args.apk, args.receipt, lock)
        return 0
    except PackageError as error:
        print(f"FreeRDP package error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
