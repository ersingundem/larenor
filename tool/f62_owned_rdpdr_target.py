#!/usr/bin/env python3
from __future__ import annotations
import argparse
import hashlib
import json
import os
import pathlib
import stat
import struct

SOURCE_REVISION = "63b948ca5cb94307fd5444ee6e73927a41ccdab4"
SOURCE_ARCHIVE_SHA256 = (
    "4a2629026896cb4e26fb8ed2d6ca6aa4ab89ca95528dfbae2550c2f6bc866991"
)
MANIFEST_KEYS = {
    "schemaVersion",
    "sourceRevision",
    "sourceArchiveSha256",
    "patchSha256",
    "originals",
    "patched",
    "witnessSchemaVersion",
    "deviceName",
}
RECEIPT_KEYS = {
    "schemaVersion",
    "sourceRevision",
    "sourceArchiveSha256",
    "targetPatchSha256",
    "targetBinarySha256",
    "witnessSchemaVersion",
}
REQUIRED_BINARY_MARKERS = (
    b"LrnXfer",
    b"LARENOR_F62_TARGET_NONCE",
    b"LARENOR_F62_TARGET_WITNESS",
    b"Larenor-F62-Gateway-outbound:",
    b"\\\\ToRemote\\\\upload-",
    b"\\\\FromRemote\\\\outbound-",
    b"owned RDPDR witness publication failed",
)


class PackageError(RuntimeError):
    pass


def fail(stage):
    raise PackageError(stage)


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def regular(path, *, executable=False, absent=False):
    if absent:
        if path.exists() or path.is_symlink():
            fail("outputExists")
        return
    info = path.lstat()
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        fail("unsafeFile")
    if info.st_uid != os.getuid() or info.st_mode & 0o077:
        fail("unsafeFile")
    if executable and not info.st_mode & stat.S_IXUSR:
        fail("notExecutable")


def directory(path):
    info = path.lstat()
    if (
        stat.S_ISLNK(info.st_mode)
        or not stat.S_ISDIR(info.st_mode)
        or info.st_uid != os.getuid()
        or info.st_mode & 0o077
    ):
        fail("unsafeDirectory")


def read_manifest(path):
    regular(path)
    raw = path.read_bytes()
    if not 0 < len(raw) <= 16384:
        fail("invalidManifest")
    value = json.loads(raw)
    if (
        not isinstance(value, dict)
        or set(value) != MANIFEST_KEYS
        or value["schemaVersion"] != 1
        or value["sourceRevision"] != SOURCE_REVISION
        or value["sourceArchiveSha256"] != SOURCE_ARCHIVE_SHA256
        or value["witnessSchemaVersion"] != 2
        or value["deviceName"] != "LrnXfer"
    ):
        fail("invalidManifest")
    if not isinstance(value["patchSha256"], str) or len(value["patchSha256"]) != 64:
        fail("invalidManifest")
    for group in ("originals", "patched"):
        if not isinstance(value[group], dict) or not value[group]:
            fail("invalidManifest")
        for name, expected in value[group].items():
            if (
                not isinstance(name, str)
                or name.startswith("/")
                or ".." in pathlib.PurePosixPath(name).parts
                or not isinstance(expected, str)
                or len(expected) != 64
            ):
                fail("invalidManifest")
    return value


def verify_tree(root, expected):
    directory(root)
    for relative, wanted in expected.items():
        path = root / relative
        regular(path)
        if digest(path) != wanted:
            fail("sourceDrift")


def verify_elf(binary):
    regular(binary, executable=True)
    raw = binary.read_bytes()
    if len(raw) < 64 or raw[:6] != b"\x7fELF\x02\x01":
        fail("invalidTargetBinary")
    e_type, e_machine = struct.unpack_from("<HH", raw, 16)
    if e_type not in (2, 3) or e_machine != 62:
        fail("invalidTargetBinary")
    for marker in REQUIRED_BINARY_MARKERS:
        if marker not in raw:
            fail("missingTargetEvidence")


def write_receipt(path, value):
    regular(path, absent=True)
    raw = (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode(
        "ascii"
    )
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, "wb", closefd=True) as f:
            f.write(raw)
            f.flush()
            os.fsync(f.fileno())
    except BaseException:
        try:
            path.unlink()
        except FileNotFoundError:
            pass
        raise


def verify(args):
    manifest = read_manifest(pathlib.Path(args.manifest))
    root = pathlib.Path(args.source_root)
    verify_tree(root, manifest["patched"] if args.prepared else manifest["originals"])
    patch = pathlib.Path(args.patch)
    regular(patch)
    if digest(patch) != manifest["patchSha256"]:
        fail("patchDrift")
    if args.prepared:
        binary = pathlib.Path(args.binary)
        verify_elf(binary)
        receipt = {
            "schemaVersion": 1,
            "sourceRevision": SOURCE_REVISION,
            "sourceArchiveSha256": SOURCE_ARCHIVE_SHA256,
            "targetPatchSha256": manifest["patchSha256"],
            "targetBinarySha256": digest(binary),
            "witnessSchemaVersion": 2,
        }
        write_receipt(pathlib.Path(args.receipt), receipt)
        print(
            json.dumps(
                {
                    "state": "targetVerified",
                    "receiptSha256": digest(pathlib.Path(args.receipt)),
                },
                sort_keys=True,
                separators=(",", ":"),
            )
        )
    else:
        print(
            json.dumps(
                {"state": "sourceVerified"}, sort_keys=True, separators=(",", ":")
            )
        )


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--manifest", required=True)
    p.add_argument("--patch", required=True)
    p.add_argument("--source-root", required=True)
    p.add_argument("--prepared", action="store_true")
    p.add_argument("--binary")
    p.add_argument("--receipt")
    args = p.parse_args()
    try:
        if args.prepared and (not args.binary or not args.receipt):
            fail("missingArguments")
        if not args.prepared and (args.binary or args.receipt):
            fail("invalidArguments")
        verify(args)
    except (PackageError, OSError, ValueError, json.JSONDecodeError) as error:
        stage = (
            error.args[0]
            if isinstance(error, PackageError) and error.args
            else "packageFailure"
        )
        print(
            json.dumps(
                {"state": "failed", "stage": stage},
                sort_keys=True,
                separators=(",", ":"),
            )
        )
        raise SystemExit(2)


if __name__ == "__main__":
    main()
