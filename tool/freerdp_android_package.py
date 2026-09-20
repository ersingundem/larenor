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
        "toolchain", "supportedAbis", "jniSchema", "defaultChannels",
        "requiredLibraries",
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
    _require(type(reviewed) is dict and len(reviewed) == 4 and
             all(type(name) is str and HEX40.fullmatch(digest or "")
                 for name, digest in reviewed.items()), "invalid_lock")
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
    except (zipfile.BadZipFile, KeyError, OSError) as error:
        raise PackageError("invalid_aar") from error
    return {
        "schemaVersion": 1,
        "engineRevision": lock["engineRevision"],
        "sourceCommit": lock["source"]["commit"],
        "sourceSha256": lock["source"]["sha256"],
        "abi": abi,
        "aarSha256": _sha256(aar),
        "defaultChannels": [],
        "libraries": entries,
    }


def main(argv=None):
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("verify-lock")
    source = sub.add_parser("verify-source")
    source.add_argument("archive", type=Path)
    receipt = sub.add_parser("receipt")
    receipt.add_argument("aar", type=Path)
    receipt.add_argument("--abi", required=True)
    receipt.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        lock = load_lock()
        if args.command == "verify-source":
            verify_source(args.archive, lock)
        elif args.command == "receipt":
            value = package_receipt(args.aar, args.abi, lock)
            args.output.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
        return 0
    except PackageError as error:
        print(f"FreeRDP package error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
