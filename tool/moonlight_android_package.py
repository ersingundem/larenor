#!/usr/bin/env python3
"""Build and verify Larenor's exact embedded Moonlight Android engine."""

import argparse
import gzip
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import struct
import subprocess
import sys
import tarfile
import xml.etree.ElementTree as ET
import zipfile


ROOT = Path(__file__).resolve().parents[1]
LOCK_PATH = ROOT / "android/moonlight/source-lock.json"
NOTICE_PATH = ROOT / "android/moonlight/NOTICE.md"
HEX40 = re.compile(r"[0-9a-f]{40}")
HEX64 = re.compile(r"[0-9a-f]{64}")
ABI_MACHINE = {"arm64-v8a": 183, "x86_64": 62}
ANDROID_NS = "{http://schemas.android.com/apk/res/android}"
MAX_AAR_BYTES = 256 * 1024 * 1024
MAX_APK_BYTES = 1024 * 1024 * 1024


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


def _git(root, *arguments):
    try:
        completed = subprocess.run(
            ["git", "-C", str(root), *arguments],
            check=True,
            capture_output=True,
            text=True,
            timeout=30,
        )
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        raise PackageError("invalid_source_git") from error
    return completed.stdout.rstrip("\r\n")


def load_lock(path=LOCK_PATH):
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise PackageError("invalid_lock") from error
    _require(
        set(value)
        == {
            "schemaVersion",
            "engineRevision",
            "upstream",
            "submodules",
            "patches",
            "reviewedFiles",
            "toolchain",
            "variant",
            "supportedAbis",
            "mavenDependencies",
            "bundledNativeArchives",
            "engineContracts",
            "requiredSources",
            "requiredClasses",
            "requiredLibraries",
        },
        "invalid_lock",
    )
    _require(
        value["schemaVersion"] == 1
        and value["engineRevision"] == "moonlight-android-12.2-larenor-embed-v2",
        "invalid_lock",
    )
    upstream = value["upstream"]
    _validate_repository(upstream, expected_path=None)
    _require(
        upstream == {
            "name": "Moonlight Android",
            "version": "12.2",
            "url": "https://github.com/moonlight-stream/moonlight-android.git",
            "commit": "b48494cb96bff23d8886c4775cc4f39a1075495d",
            "tree": "a47121faa2f8d7b13a31225cac7900b9c3644892",
            "license": "GPL-3.0-only",
            "licensePath": "LICENSE.txt",
            "licenseSha256": "8ceb4b9ee5adedde47b31e975c1d90c73ad27b6b165a1dcd80c7c545eb65b903",
        },
        "invalid_lock",
    )
    submodules = value["submodules"]
    _require(type(submodules) is list and len(submodules) == 3, "invalid_lock")
    for item in submodules:
        _validate_repository(item, expected_path=item.get("path"))
    paths = [item["path"] for item in submodules]
    _require(paths == sorted(paths, key=lambda item: (item.count("/"), item)), "invalid_lock")
    _require(len(set(paths)) == len(paths), "invalid_lock")
    _require(
        value["toolchain"]
        == {
            "java": "17",
            "androidGradlePlugin": "9.4.0",
            "gradle": "9.7.1",
            "compileSdk": "37.0",
            "targetSdk": 36,
            "minSdk": 21,
            "ndk": "29.0.14206865",
        },
        "invalid_lock",
    )
    _require(value["variant"] == "nonRootRelease", "invalid_lock")
    _require(value["supportedAbis"] == ["arm64-v8a", "x86_64"], "invalid_lock")
    _require(value["requiredLibraries"] == ["libmoonlight-core.so"], "invalid_lock")
    _require(
        value["engineContracts"]
        == ["pairing", "credentialStore", "video", "audio", "input", "stream", "causalStop"],
        "invalid_lock",
    )
    for key in ("mavenDependencies", "requiredSources", "requiredClasses"):
        items = value[key]
        _require(
            type(items) is list
            and items
            and all(type(item) is str and item for item in items)
            and len(items) == len(set(items)),
            "invalid_lock",
        )
    archives = value["bundledNativeArchives"]
    _require(type(archives) is list and len(archives) == 2, "invalid_lock")
    for archive in archives:
        _require(
            set(archive)
            == {"name", "reportedVersion", "license", "sourceUrl", "artifacts"}
            and archive["sourceUrl"].startswith("https://")
            and type(archive["artifacts"]) is dict
            and len(archive["artifacts"]) == 2
            and all(
                _safe_relative(name) and HEX64.fullmatch(digest or "")
                for name, digest in archive["artifacts"].items()
            ),
            "invalid_lock",
        )
    reviewed = value["reviewedFiles"]
    _require(
        type(reviewed) is dict
        and len(reviewed) >= 10
        and all(
            _safe_relative(name) and HEX40.fullmatch(digest or "")
            for name, digest in reviewed.items()
        ),
        "invalid_lock",
    )
    patches = value["patches"]
    _require(type(patches) is list and len(patches) == 1, "invalid_lock")
    for patch in patches:
        _require(
            set(patch) == {"path", "sha256"}
            and _safe_relative(patch["path"])
            and patch["path"].startswith("android/moonlight/patches/")
            and HEX64.fullmatch(patch["sha256"] or ""),
            "invalid_lock",
        )
        patch_path = ROOT / patch["path"]
        _require(
            patch_path.is_file() and _sha256(patch_path) == patch["sha256"],
            "patch_digest_mismatch",
        )
    return value


def _validate_repository(item, expected_path):
    expected_keys = {
        "url",
        "commit",
        "tree",
        "license",
        "licensePath",
        "licenseSha256",
    }
    if expected_path is None:
        expected_keys |= {"name", "version"}
    else:
        expected_keys.add("path")
    _require(set(item) == expected_keys, "invalid_lock")
    _require(
        item["url"].startswith("https://github.com/")
        and item["url"].endswith(".git")
        and HEX40.fullmatch(item["commit"] or "")
        and HEX40.fullmatch(item["tree"] or "")
        and HEX64.fullmatch(item["licenseSha256"] or "")
        and _safe_relative(item["licensePath"]),
        "invalid_lock",
    )
    if expected_path is not None:
        _require(item["path"] == expected_path and _safe_relative(expected_path), "invalid_lock")


def _safe_relative(value):
    if type(value) is not str or not value:
        return False
    path = PurePosixPath(value)
    return not path.is_absolute() and ".." not in path.parts and "" not in path.parts


def verify_source_tree(source, lock):
    source = source.resolve()
    _require(source.is_dir() and not source.is_symlink(), "invalid_source_tree")
    _require(_git(source, "rev-parse", "HEAD") == lock["upstream"]["commit"], "source_commit_mismatch")
    _require(_git(source, "rev-parse", "HEAD^{tree}") == lock["upstream"]["tree"], "source_tree_mismatch")
    if "url" in lock["upstream"]:
        _require(_git(source, "remote", "get-url", "origin") == lock["upstream"]["url"], "source_remote_mismatch")
    _require(
        _git(source, "status", "--porcelain=v1", "--untracked-files=all", "--ignore-submodules=none") == "",
        "dirty_source_tree",
    )
    actual_submodules = {}
    status = _git(source, "submodule", "status", "--recursive")
    for line in status.splitlines() if status else []:
        _require(line and line[0] == " ", "submodule_not_clean")
        fields = line[1:].split()
        _require(len(fields) >= 2 and HEX40.fullmatch(fields[0]), "invalid_submodule_status")
        actual_submodules[fields[1]] = fields[0]
    expected_submodules = {item["path"]: item["commit"] for item in lock["submodules"]}
    _require(actual_submodules == expected_submodules, "submodule_identity_mismatch")
    for item in [lock["upstream"], *lock["submodules"]]:
        repository = source if "path" not in item else source / item["path"]
        _require(repository.is_dir() and not repository.is_symlink(), "invalid_submodule_tree")
        _require(_git(repository, "rev-parse", "HEAD") == item["commit"], "submodule_identity_mismatch")
        _require(_git(repository, "rev-parse", "HEAD^{tree}") == item["tree"], "submodule_tree_mismatch")
        if "url" in item:
            _require(_git(repository, "remote", "get-url", "origin") == item["url"], "submodule_remote_mismatch")
        if "licensePath" in item:
            license_path = repository / item["licensePath"]
            _require(
                license_path.is_file()
                and _sha256(license_path) == item["licenseSha256"],
                "license_digest_mismatch",
            )
    for relative, expected in lock["reviewedFiles"].items():
        path = source / relative
        _require(path.is_file() and not path.is_symlink(), "reviewed_source_missing")
        _require(_git(source, "hash-object", relative) == expected, "reviewed_source_mismatch")
    for archive in lock.get("bundledNativeArchives", []):
        for relative, expected in archive["artifacts"].items():
            path = source / relative
            _require(
                path.is_file()
                and not path.is_symlink()
                and path.stat().st_size <= 64 * 1024 * 1024
                and _sha256(path) == expected,
                "bundled_archive_mismatch",
            )


def prepare_source(source, output, lock):
    source = source.resolve()
    output = output.resolve()
    verify_source_tree(source, lock)
    _require(not output.exists() and output.parent.is_dir(), "output_must_not_exist")
    try:
        shutil.copytree(source, output, symlinks=True)
        for item in lock["patches"]:
            subprocess.run(
                ["git", "-C", str(output), "apply", "--unidiff-zero", "--check", str(ROOT / item["path"])],
                check=True,
                capture_output=True,
                timeout=30,
            )
            subprocess.run(
                ["git", "-C", str(output), "apply", "--unidiff-zero", str(ROOT / item["path"])],
                check=True,
                capture_output=True,
                timeout=30,
            )
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        raise PackageError("source_transform_failed") from error
    verify_transformed_tree(output, lock)


def verify_transformed_tree(root, lock):
    root = root.resolve()
    gradle = _bounded_text(root / "app/build.gradle", 256 * 1024)
    _require(
        "apply plugin: 'com.android.library'" in gradle
        and "com.android.application" not in gradle
        and "applicationId " not in gradle
        and "applicationIdSuffix" not in gradle
        and "abiFilters 'arm64-v8a', 'x86_64'" in gradle
        and 'buildConfigField "String", "APPLICATION_ID", \'"com.ersingundem.larenor"\'' in gradle
        and "consumerProguardFiles 'consumer-rules.pro'" in gradle
        and "minifyEnabled false" in gradle,
        "invalid_library_transform",
    )
    for dependency in lock["mavenDependencies"]:
        _require(dependency in gradle, "dependency_contract_missing")
    consumer = _bounded_text(root / "app/consumer-rules.pro", 64 * 1024)
    _require("-dontobfuscate" not in consumer and "com.limelight.nvstream.jni" in consumer, "invalid_consumer_rules")
    try:
        manifest = ET.parse(root / "app/src/main/AndroidManifest.xml").getroot()
    except (OSError, ET.ParseError) as error:
        raise PackageError("invalid_embedded_manifest") from error
    application = manifest.find("application")
    _require(application is not None and not application.attrib, "unsafe_embedded_manifest")
    components = {
        (element.tag, element.get(ANDROID_NS + "name")): element
        for element in application
        if element.tag in {"activity", "provider", "service"}
    }
    for tag, name in (
        ("activity", ".PcView"),
        ("activity", ".ShortcutTrampoline"),
        ("activity", ".AppView"),
        ("activity", ".Game"),
        ("provider", ".PosterContentProvider"),
    ):
        _require((tag, name) in components, "engine_component_missing")
    for key in (("activity", ".PcView"), ("activity", ".ShortcutTrampoline"), ("provider", ".PosterContentProvider")):
        _require(components[key].get(ANDROID_NS + "exported") == "false", "unsafe_embedded_manifest")
    provider = components[("provider", ".PosterContentProvider")]
    _require(provider.get(ANDROID_NS + "authorities") == "poster.com.ersingundem.larenor", "unsafe_embedded_manifest")
    _require(
        not manifest.findall(".//intent-filter")
        and "android.intent.action.MAIN" not in ET.tostring(manifest, encoding="unicode")
        and "android.intent.category.LAUNCHER" not in ET.tostring(manifest, encoding="unicode"),
        "unsafe_embedded_manifest",
    )
    for relative in lock["requiredSources"]:
        path = root / relative
        _require(path.is_file() and not path.is_symlink() and path.stat().st_size <= 4 * 1024 * 1024, "engine_source_missing")
    game = _bounded_text(root / "app/src/main/java/com/limelight/Game.java", 4 * 1024 * 1024)
    _require(
        "onConnectionStopStarted();\n            new Thread()" in game
        and "conn.stop();\n                    onConnectionStopCompleted();" in game
        and "protected void onConnectionStopStarted()" in game
        and "protected void onConnectionStopCompleted()" in game,
        "causal_stop_hook_missing",
    )


def _bounded_text(path, maximum):
    try:
        _require(path.is_file() and not path.is_symlink() and path.stat().st_size <= maximum, "invalid_source_file")
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise PackageError("invalid_source_file") from error


def _elf_machine(data):
    _require(len(data) >= 20 and data[:4] == b"\x7fELF" and data[5] in (1, 2), "invalid_native_library")
    order = "<" if data[5] == 1 else ">"
    return struct.unpack(order + "H", data[18:20])[0]


def package_receipt(aar, lock):
    _require(aar.is_file() and not aar.is_symlink() and aar.stat().st_size <= MAX_AAR_BYTES, "invalid_aar")
    try:
        with zipfile.ZipFile(aar) as bundle:
            names = bundle.namelist()
            _require(len(names) == len(set(names)) and "AndroidManifest.xml" in names and "classes.jar" in names, "invalid_aar")
            classes = bundle.read("classes.jar")
            with zipfile.ZipFile(io.BytesIO(classes)) as jar:
                class_names = set(jar.namelist())
                _require(all(name in class_names for name in lock["requiredClasses"]), "missing_engine_class")
            native_names = [name for name in names if name.startswith("jni/") and name.endswith(".so")]
            actual_abis = sorted({PurePosixPath(name).parts[1] for name in native_names})
            _require(actual_abis == sorted(lock["supportedAbis"]), "unexpected_aar_abi")
            libraries = {}
            for abi in lock["supportedAbis"]:
                by_name = {
                    PurePosixPath(name).name: name
                    for name in native_names
                    if name.startswith(f"jni/{abi}/")
                }
                _require(set(by_name) == set(lock["requiredLibraries"]), "unexpected_native_library")
                entries = []
                for required in lock["requiredLibraries"]:
                    data = bundle.read(by_name[required])
                    _require(_elf_machine(data) == ABI_MACHINE[abi], "wrong_native_architecture")
                    entries.append({
                        "name": required,
                        "size": len(data),
                        "sha256": hashlib.sha256(data).hexdigest(),
                    })
                libraries[abi] = entries
    except (OSError, KeyError, zipfile.BadZipFile) as error:
        raise PackageError("invalid_aar") from error
    return {
        "schemaVersion": 1,
        "engineRevision": lock["engineRevision"],
        "sourceCommit": lock["upstream"]["commit"],
        "sourceTree": lock["upstream"]["tree"],
        "submodules": [
            {"path": item["path"], "commit": item["commit"], "tree": item["tree"]}
            for item in lock["submodules"]
        ],
        "abis": lock["supportedAbis"],
        "aarSha256": _sha256(aar),
        "classesSha256": hashlib.sha256(classes).hexdigest(),
        "requiredClasses": lock["requiredClasses"],
        "libraries": libraries,
        "bundledNativeArchives": [
            {
                "name": item["name"],
                "reportedVersion": item["reportedVersion"],
                "artifacts": item["artifacts"],
            }
            for item in lock["bundledNativeArchives"]
        ],
        "licenseSha256": lock["upstream"]["licenseSha256"],
    }


def verify_install(aar, receipt_path, lock):
    try:
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise PackageError("invalid_receipt") from error
    _require(type(receipt) is dict and receipt == package_receipt(aar, lock), "receipt_mismatch")


def _verify_receipt_contract(receipt, lock):
    _require(
        type(receipt) is dict
        and set(receipt)
        == {
            "schemaVersion",
            "engineRevision",
            "sourceCommit",
            "sourceTree",
            "submodules",
            "abis",
            "aarSha256",
            "classesSha256",
            "requiredClasses",
            "libraries",
            "bundledNativeArchives",
            "licenseSha256",
        }
        and receipt["schemaVersion"] == 1
        and receipt["engineRevision"] == lock["engineRevision"]
        and receipt["sourceCommit"] == lock["upstream"]["commit"]
        and receipt["sourceTree"] == lock["upstream"]["tree"]
        and receipt["abis"] == lock["supportedAbis"]
        and receipt["requiredClasses"] == lock["requiredClasses"]
        and HEX64.fullmatch(receipt["aarSha256"] or "")
        and HEX64.fullmatch(receipt["classesSha256"] or "")
        and receipt["licenseSha256"] == lock["upstream"]["licenseSha256"],
        "invalid_receipt",
    )
    expected_submodules = [
        {"path": item["path"], "commit": item["commit"], "tree": item["tree"]}
        for item in lock["submodules"]
    ]
    expected_archives = [
        {
            "name": item["name"],
            "reportedVersion": item["reportedVersion"],
            "artifacts": item["artifacts"],
        }
        for item in lock["bundledNativeArchives"]
    ]
    _require(
        receipt["submodules"] == expected_submodules
        and receipt["bundledNativeArchives"] == expected_archives
        and set(receipt["libraries"]) == set(lock["supportedAbis"]),
        "invalid_receipt",
    )
    for abi in lock["supportedAbis"]:
        items = receipt["libraries"][abi]
        _require(
            type(items) is list
            and [item.get("name") for item in items] == lock["requiredLibraries"]
            and all(
                set(item) == {"name", "size", "sha256"}
                and type(item["size"]) is int
                and 0 < item["size"] <= 64 * 1024 * 1024
                and HEX64.fullmatch(item["sha256"] or "")
                for item in items
            ),
            "invalid_receipt",
        )


def verify_apk(apk, receipt_path, lock):
    _require(apk.is_file() and not apk.is_symlink() and apk.stat().st_size <= MAX_APK_BYTES, "invalid_apk")
    try:
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        _verify_receipt_contract(receipt, lock)
        with zipfile.ZipFile(apk) as bundle:
            names = bundle.namelist()
            _require(len(names) == len(set(names)), "invalid_apk")
            dex_names = [name for name in names if re.fullmatch(r"classes(?:\d+)?\.dex", name)]
            _require(dex_names, "apk_engine_classes_missing")
            _require(
                sum(bundle.getinfo(name).file_size for name in dex_names)
                <= 512 * 1024 * 1024,
                "invalid_apk",
            )
            dex = b"".join(bundle.read(name) for name in dex_names)
            for class_name in lock["requiredClasses"]:
                descriptor = f"L{class_name.removesuffix('.class')};".encode()
                _require(descriptor in dex, "apk_engine_classes_missing")
            for abi in lock["supportedAbis"]:
                for item in receipt["libraries"][abi]:
                    data = bundle.read(f"lib/{abi}/{item['name']}")
                    _require(
                        len(data) == item["size"]
                        and hashlib.sha256(data).hexdigest() == item["sha256"],
                        "apk_library_mismatch",
                    )
    except (OSError, KeyError, zipfile.BadZipFile, json.JSONDecodeError) as error:
        raise PackageError("invalid_apk") from error


def build_library(source, work, aar_output, receipt_output, lock):
    prepare_source(source, work, lock)
    android_home = Path(os.environ.get("ANDROID_HOME", ""))
    _require(android_home.is_dir(), "android_sdk_unavailable")
    _require((android_home / "ndk" / lock["toolchain"]["ndk"]).is_dir(), "ndk_unavailable")
    _require(not aar_output.exists() and not receipt_output.exists(), "output_must_not_exist")
    try:
        subprocess.run(
            [str(work / "gradlew"), "--no-daemon", ":app:assembleNonRootRelease"],
            cwd=work,
            env={**os.environ, "ANDROID_HOME": str(android_home)},
            check=True,
            timeout=3600,
        )
        built = work / "app/build/outputs/aar/app-nonRoot-release.aar"
        _require(built.is_file(), "aar_not_produced")
        receipt = package_receipt(built, lock)
        shutil.copyfile(built, aar_output)
        receipt_output.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        raise PackageError("moonlight_build_failed") from error


def source_bundle(source, output, lock):
    verify_source_tree(source, lock)
    _require(not output.exists() and output.parent.is_dir(), "output_must_not_exist")
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w", format=tarfile.PAX_FORMAT) as archive:
        for path in sorted(source.rglob("*")):
            relative = path.relative_to(source)
            if ".git" in relative.parts or "build" in relative.parts:
                continue
            _add_deterministic(archive, path, PurePosixPath("moonlight-android-source") / PurePosixPath(relative.as_posix()))
        for path, name in (
            (LOCK_PATH, "larenor-packaging/source-lock.json"),
            (NOTICE_PATH, "larenor-packaging/NOTICE.md"),
            *((ROOT / item["path"], f"larenor-packaging/{item['path']}") for item in lock["patches"]),
        ):
            _add_deterministic(archive, path, PurePosixPath(name))
    with output.open("wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
            compressed.write(buffer.getvalue())


def _add_deterministic(archive, path, name):
    info = archive.gettarinfo(str(path), arcname=str(name))
    info.uid = info.gid = 0
    info.uname = info.gname = "root"
    info.mtime = 0
    if path.is_file():
        with path.open("rb") as stream:
            archive.addfile(info, stream)
    else:
        archive.addfile(info)


def main(argv=None):
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("verify-lock")
    verify_source_parser = commands.add_parser("verify-source")
    verify_source_parser.add_argument("source", type=Path)
    prepare_parser = commands.add_parser("prepare")
    prepare_parser.add_argument("source", type=Path)
    prepare_parser.add_argument("output", type=Path)
    build_parser = commands.add_parser("build")
    build_parser.add_argument("source", type=Path)
    build_parser.add_argument("work", type=Path)
    build_parser.add_argument("aar", type=Path)
    build_parser.add_argument("receipt", type=Path)
    receipt_parser = commands.add_parser("receipt")
    receipt_parser.add_argument("aar", type=Path)
    receipt_parser.add_argument("output", type=Path)
    install_parser = commands.add_parser("verify-install")
    install_parser.add_argument("aar", type=Path)
    install_parser.add_argument("receipt", type=Path)
    apk_parser = commands.add_parser("verify-apk")
    apk_parser.add_argument("apk", type=Path)
    apk_parser.add_argument("receipt", type=Path)
    source_bundle_parser = commands.add_parser("source-bundle")
    source_bundle_parser.add_argument("source", type=Path)
    source_bundle_parser.add_argument("output", type=Path)
    args = parser.parse_args(argv)
    lock = load_lock()
    if args.command == "verify-source":
        verify_source_tree(args.source, lock)
    elif args.command == "prepare":
        prepare_source(args.source, args.output, lock)
    elif args.command == "build":
        build_library(args.source, args.work, args.aar, args.receipt, lock)
    elif args.command == "receipt":
        receipt = package_receipt(args.aar, lock)
        _require(not args.output.exists(), "output_must_not_exist")
        args.output.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    elif args.command == "verify-install":
        verify_install(args.aar, args.receipt, lock)
    elif args.command == "verify-apk":
        verify_apk(args.apk, args.receipt, lock)
    elif args.command == "source-bundle":
        source_bundle(args.source, args.output, lock)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except PackageError as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(2)
