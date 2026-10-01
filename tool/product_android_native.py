#!/usr/bin/env python3
"""Compose and verify the two source-locked Android product engines."""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import sys
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tool import freerdp_android_package as freerdp_package
from tool import moonlight_android_package as moonlight_package


SCHEMA_VERSION = 1
PRODUCT_RECEIPT = "product-native-receipt.json"
FREERDP_ABIS = ("arm64-v8a", "x86_64")
MAX_AAR_BYTES = 1024 * 1024 * 1024
MAX_RECEIPT_BYTES = 1024 * 1024


class ProductNativeError(ValueError):
    pass


def _require(condition: bool, code: str) -> None:
    if not condition:
        raise ProductNativeError(code)


def _regular(path: Path, maximum: int, code: str) -> None:
    try:
        _require(
            path.is_file()
            and not path.is_symlink()
            and 0 < path.stat().st_size <= maximum,
            code,
        )
    except OSError as error:
        raise ProductNativeError(code) from error


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
    except OSError as error:
        raise ProductNativeError("native_input_unavailable") from error
    return digest.hexdigest()


def _load_json(path: Path, code: str) -> dict:
    _regular(path, MAX_RECEIPT_BYTES, code)
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ProductNativeError(code) from error
    _require(type(value) is dict, code)
    return value


def _safe_archive(bundle: zipfile.ZipFile, code: str) -> list[str]:
    entries = bundle.infolist()
    names = [entry.filename for entry in entries]
    _require(names and len(names) == len(set(names)), code)
    files = []
    for entry in entries:
        name = entry.filename
        value = PurePosixPath(name)
        _require(
            not value.is_absolute()
            and ".." not in value.parts
            and ((entry.external_attr >> 16) & 0o170000) != 0o120000,
            code,
        )
        if not entry.is_dir():
            files.append(name)
    return files


def _merge_freerdp(
    arm64_aar: Path,
    x86_aar: Path,
    output: Path,
) -> None:
    _regular(arm64_aar, MAX_AAR_BYTES, "invalid_freerdp_input")
    _regular(x86_aar, MAX_AAR_BYTES, "invalid_freerdp_input")
    try:
        with zipfile.ZipFile(arm64_aar) as arm64, zipfile.ZipFile(x86_aar) as x86:
            arm64_names = _safe_archive(arm64, "invalid_freerdp_input")
            x86_names = _safe_archive(x86, "invalid_freerdp_input")
            arm64_common = [name for name in arm64_names if not name.startswith("jni/")]
            x86_common = [name for name in x86_names if not name.startswith("jni/")]
            _require(set(arm64_common) == set(x86_common),
                     "freerdp_variant_mismatch")
            _require(
                all(arm64.read(name) == x86.read(name) for name in arm64_common),
                "freerdp_variant_mismatch",
            )
            arm64_native = [name for name in arm64_names if name.startswith("jni/")]
            x86_native = [name for name in x86_names if name.startswith("jni/")]
            _require(
                arm64_native
                and x86_native
                and all(name.startswith("jni/arm64-v8a/") for name in arm64_native)
                and all(name.startswith("jni/x86_64/") for name in x86_native),
                "freerdp_abi_mismatch",
            )
            with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as merged:
                for name in sorted(arm64_common) + sorted(arm64_native):
                    merged.writestr(name, arm64.read(name))
                for name in sorted(x86_native):
                    merged.writestr(name, x86.read(name))
    except (OSError, KeyError, zipfile.BadZipFile) as error:
        raise ProductNativeError("invalid_freerdp_input") from error


def _freerdp_receipts(destination: Path) -> list[tuple[str, Path, dict]]:
    values = []
    try:
        lock = freerdp_package.load_lock()
    except freerdp_package.PackageError as error:
        raise ProductNativeError("invalid_freerdp_package") from error
    for abi in FREERDP_ABIS:
        path = destination / f"freerdp/{abi}-receipt.json"
        receipt = _load_json(path, "invalid_freerdp_receipt")
        try:
            freerdp_package._verify_receipt_contract(receipt, lock)
        except freerdp_package.PackageError as error:
            raise ProductNativeError("invalid_freerdp_receipt") from error
        _require(receipt.get("abi") == abi, "freerdp_abi_mismatch")
        values.append((abi, path, receipt))
    _require(
        values[0][2]["engineRevision"] == values[1][2]["engineRevision"]
        and values[0][2]["sourceCommit"] == values[1][2]["sourceCommit"]
        and values[0][2]["sourceSha256"] == values[1][2]["sourceSha256"]
        and values[0][2]["classesSha256"] == values[1][2]["classesSha256"]
        and values[0][2]["patches"] == values[1][2]["patches"],
        "freerdp_variant_mismatch",
    )
    return values


def _verify_merged_freerdp(destination: Path, receipts) -> None:
    aar = destination / "freerdp/freeRDPCore.aar"
    _regular(aar, MAX_AAR_BYTES, "invalid_product_freerdp")
    try:
        with zipfile.ZipFile(aar) as bundle:
            names = _safe_archive(bundle, "invalid_product_freerdp")
            _require("classes.jar" in names and "AndroidManifest.xml" in names,
                     "invalid_product_freerdp")
            classes_sha = hashlib.sha256(bundle.read("classes.jar")).hexdigest()
            expected_native = set()
            for abi, _path, receipt in receipts:
                _require(classes_sha == receipt["classesSha256"],
                         "freerdp_variant_mismatch")
                for item in receipt["libraries"]:
                    name = f"jni/{abi}/{item['name']}"
                    data = bundle.read(name)
                    _require(
                        len(data) == item["size"]
                        and hashlib.sha256(data).hexdigest() == item["sha256"],
                        "product_freerdp_mismatch",
                    )
                    expected_native.add(name)
            actual_native = {
                name for name in names if name.startswith("jni/") and name.endswith(".so")
            }
            _require(
                expected_native <= actual_native
                and actual_native
                and all(
                    PurePosixPath(name).parts[1] in FREERDP_ABIS
                    for name in actual_native
                ),
                "product_freerdp_mismatch",
            )
    except (OSError, KeyError, zipfile.BadZipFile) as error:
        raise ProductNativeError("invalid_product_freerdp") from error


def _product_receipt(destination: Path, receipts) -> dict:
    moon_receipt = _load_json(
        destination / "moonlight/receipt.json", "invalid_moonlight_receipt"
    )
    freerdp_aar = destination / "freerdp/freeRDPCore.aar"
    try:
        with zipfile.ZipFile(freerdp_aar) as bundle:
            native_names = sorted(
                name
                for name in _safe_archive(bundle, "invalid_product_freerdp")
                if name.startswith("jni/") and name.endswith(".so")
            )
            libraries = {
                abi: [
                    {
                        "name": PurePosixPath(name).name,
                        "size": len(bundle.read(name)),
                        "sha256": hashlib.sha256(bundle.read(name)).hexdigest(),
                    }
                    for name in native_names
                    if name.startswith(f"jni/{abi}/")
                ]
                for abi in FREERDP_ABIS
            }
    except (OSError, zipfile.BadZipFile) as error:
        raise ProductNativeError("invalid_product_freerdp") from error
    return {
        "schemaVersion": SCHEMA_VERSION,
        "engines": {
            "freerdp": {
                "engineRevision": receipts[0][2]["engineRevision"],
                "abis": list(FREERDP_ABIS),
                "aarSha256": _sha256(destination / "freerdp/freeRDPCore.aar"),
                "libraries": libraries,
                "receiptSha256": {
                    abi: _sha256(path) for abi, path, _receipt in receipts
                },
            },
            "moonlight": {
                "engineRevision": moon_receipt.get("engineRevision"),
                "abis": moon_receipt.get("abis"),
                "aarSha256": _sha256(destination / "moonlight/moonlight-engine.aar"),
                "receiptSha256": _sha256(destination / "moonlight/receipt.json"),
            },
        },
    }


def verify_installed(destination: Path) -> None:
    destination = destination.resolve()
    moon_aar = destination / "moonlight/moonlight-engine.aar"
    moon_receipt = destination / "moonlight/receipt.json"
    try:
        moonlight_package.verify_install(
            moon_aar, moon_receipt, moonlight_package.load_lock()
        )
    except moonlight_package.PackageError as error:
        raise ProductNativeError("invalid_moonlight_package") from error
    receipts = _freerdp_receipts(destination)
    _verify_merged_freerdp(destination, receipts)
    stored = _load_json(destination / PRODUCT_RECEIPT, "invalid_product_receipt")
    _require(stored == _product_receipt(destination, receipts),
             "product_receipt_mismatch")


def install(
    *,
    destination: Path,
    moonlight_aar: Path,
    moonlight_receipt: Path,
    freerdp_arm64_aar: Path,
    freerdp_arm64_receipt: Path,
    freerdp_x86_aar: Path,
    freerdp_x86_receipt: Path,
) -> None:
    inputs = (
        moonlight_aar,
        moonlight_receipt,
        freerdp_arm64_aar,
        freerdp_arm64_receipt,
        freerdp_x86_aar,
        freerdp_x86_receipt,
    )
    _require(all(path.is_absolute() for path in inputs), "absolute_inputs_required")
    destination = destination.resolve()
    _require(destination.name == "app", "invalid_product_destination")
    for target in (destination / "moonlight", destination / "freerdp",
                   destination / PRODUCT_RECEIPT):
        _require(not target.exists() and not target.is_symlink(),
                 "product_native_already_installed")
    try:
        moonlight_package.verify_install(
            moonlight_aar,
            moonlight_receipt,
            moonlight_package.load_lock(),
        )
        free_lock = freerdp_package.load_lock()
        freerdp_package.verify_install(
            freerdp_arm64_aar, freerdp_arm64_receipt, free_lock
        )
        freerdp_package.verify_install(
            freerdp_x86_aar, freerdp_x86_receipt, free_lock
        )
    except (moonlight_package.PackageError, freerdp_package.PackageError) as error:
        raise ProductNativeError("native_package_verification_failed") from error
    arm_receipt = _load_json(freerdp_arm64_receipt, "invalid_freerdp_receipt")
    x86_receipt = _load_json(freerdp_x86_receipt, "invalid_freerdp_receipt")
    _require(
        arm_receipt.get("abi") == "arm64-v8a"
        and x86_receipt.get("abi") == "x86_64",
        "freerdp_abi_mismatch",
    )

    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix=".product-native-", dir=destination.parent
    ) as temporary:
        staged = Path(temporary) / "app"
        (staged / "moonlight").mkdir(parents=True)
        (staged / "freerdp").mkdir()
        shutil.copyfile(moonlight_aar, staged / "moonlight/moonlight-engine.aar")
        shutil.copyfile(moonlight_receipt, staged / "moonlight/receipt.json")
        shutil.copyfile(
            freerdp_arm64_receipt, staged / "freerdp/arm64-v8a-receipt.json"
        )
        shutil.copyfile(
            freerdp_x86_receipt, staged / "freerdp/x86_64-receipt.json"
        )
        _merge_freerdp(
            freerdp_arm64_aar,
            freerdp_x86_aar,
            staged / "freerdp/freeRDPCore.aar",
        )
        receipts = _freerdp_receipts(staged)
        _verify_merged_freerdp(staged, receipts)
        (staged / PRODUCT_RECEIPT).write_text(
            json.dumps(_product_receipt(staged, receipts), indent=2, sort_keys=True)
            + "\n",
            encoding="utf-8",
        )
        verify_installed(staged)
        destination.mkdir(parents=True, exist_ok=True)
        os.replace(staged / "moonlight", destination / "moonlight")
        os.replace(staged / "freerdp", destination / "freerdp")
        os.replace(staged / PRODUCT_RECEIPT, destination / PRODUCT_RECEIPT)


def verify_product_apk(*, apk: Path, destination: Path) -> None:
    verify_installed(destination)
    try:
        moonlight_package.verify_apk(
            apk,
            destination / "moonlight/receipt.json",
            moonlight_package.load_lock(),
        )
        free_lock = freerdp_package.load_lock()
        for abi in FREERDP_ABIS:
            freerdp_package.verify_apk(
                apk, destination / f"freerdp/{abi}-receipt.json", free_lock
            )
        product = _load_json(
            destination / PRODUCT_RECEIPT, "invalid_product_receipt"
        )
        with zipfile.ZipFile(apk) as bundle:
            names = _safe_archive(bundle, "invalid_product_apk")
            expected = set()
            for abi, libraries in product["engines"]["freerdp"]["libraries"].items():
                for item in libraries:
                    name = f"lib/{abi}/{item['name']}"
                    data = bundle.read(name)
                    _require(
                        len(data) == item["size"]
                        and hashlib.sha256(data).hexdigest() == item["sha256"],
                        "product_apk_native_mismatch",
                    )
                    expected.add(name)
            actual = {
                name
                for name in names
                if name.startswith("lib/")
                and PurePosixPath(name).name
                in {
                    item["name"]
                    for libraries in product["engines"]["freerdp"]["libraries"].values()
                    for item in libraries
                }
            }
            _require(actual == expected, "product_apk_native_mismatch")
    except (
        moonlight_package.PackageError,
        freerdp_package.PackageError,
        OSError,
        KeyError,
        zipfile.BadZipFile,
    ) as error:
        raise ProductNativeError("product_apk_native_mismatch") from error


def main(argv=None) -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    install_parser = sub.add_parser("install")
    install_parser.add_argument("--destination", type=Path, required=True)
    install_parser.add_argument("--moonlight-aar", type=Path, required=True)
    install_parser.add_argument("--moonlight-receipt", type=Path, required=True)
    install_parser.add_argument("--freerdp-arm64-aar", type=Path, required=True)
    install_parser.add_argument("--freerdp-arm64-receipt", type=Path, required=True)
    install_parser.add_argument("--freerdp-x86-aar", type=Path, required=True)
    install_parser.add_argument("--freerdp-x86-receipt", type=Path, required=True)
    installed = sub.add_parser("verify-installed")
    installed.add_argument("--destination", type=Path, required=True)
    apk = sub.add_parser("verify-apk")
    apk.add_argument("apk", type=Path)
    apk.add_argument("--destination", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == "install":
            install(
                destination=args.destination,
                moonlight_aar=args.moonlight_aar,
                moonlight_receipt=args.moonlight_receipt,
                freerdp_arm64_aar=args.freerdp_arm64_aar,
                freerdp_arm64_receipt=args.freerdp_arm64_receipt,
                freerdp_x86_aar=args.freerdp_x86_aar,
                freerdp_x86_receipt=args.freerdp_x86_receipt,
            )
        elif args.command == "verify-installed":
            verify_installed(args.destination)
        else:
            verify_product_apk(apk=args.apk, destination=args.destination)
        return 0
    except ProductNativeError as error:
        print(f"Product native package error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
