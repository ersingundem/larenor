#!/usr/bin/env python3
"""Create one offline, hash-complete host-worker installation bundle."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import stat


REVISION = re.compile(r"[0-9a-f]{40}\Z")
WHEEL = re.compile(r"[A-Za-z0-9_.+-]{1,180}\.whl\Z")
UNMANIC_REVISION = "1c324b8fc3974ffce3d7cc945adb938fe7182910"
PLATFORMS = {"x86_64": "linux/amd64", "aarch64": "linux/arm64"}


def _rows(source, destination):
    values = []
    entries = tuple(sorted(Path(source).iterdir(), key=lambda item: item.name))
    if not 1 <= len(entries) <= 256:
        raise ValueError()
    destination.mkdir(mode=0o755)
    for item in entries:
        info = os.stat(item, follow_symlinks=False)
        if (not WHEEL.fullmatch(item.name) or not stat.S_ISREG(info.st_mode)
                or info.st_nlink != 1 or not 1 <= info.st_size <= 256 * 1024 * 1024):
            raise ValueError()
        target = destination / item.name
        descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
        digest = hashlib.sha256()
        try:
            with item.open("rb") as source_file, os.fdopen(descriptor, "wb") as output:
                descriptor = -1
                while chunk := source_file.read(1024 * 1024):
                    digest.update(chunk)
                    output.write(chunk)
                output.flush()
                os.fsync(output.fileno())
        finally:
            if descriptor >= 0:
                os.close(descriptor)
        after = os.stat(item, follow_symlinks=False)
        if ((info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)
                != (after.st_dev, after.st_ino, after.st_size,
                    after.st_mtime_ns, after.st_ctime_ns)):
            raise ValueError()
        values.append({"file": item.name, "sha256": digest.hexdigest()})
    return values


def build(output, server, unmanic, revision, selected_platform):
    if (not REVISION.fullmatch(revision)
            or selected_platform not in {"linux/amd64", "linux/arm64"}
            or output.exists() or output.is_symlink()):
        raise ValueError()
    staging = output.with_name("." + output.name + ".building")
    if staging.exists() or staging.is_symlink():
        raise ValueError()
    staging.mkdir(mode=0o755, parents=False)
    try:
        server_rows = _rows(server, staging / "server")
        unmanic_rows = _rows(unmanic, staging / "unmanic")
        if (not any(item["file"].lower().startswith("larenor_server-")
                    for item in server_rows)
                or not any(item["file"].lower().startswith("unmanic-0.4.1-")
                           for item in unmanic_rows)):
            raise ValueError()
        value = {
            "schemaVersion": 1,
            "sourceRevision": revision,
            "platform": selected_platform,
            "serverWheels": server_rows,
            "unmanic": {"version": "0.4.1", "upstreamRevision": UNMANIC_REVISION,
                        "wheels": unmanic_rows},
        }
        manifest = staging / "bundle.json"
        manifest.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n")
        manifest.chmod(0o644)
        os.rename(staging, output)
        return output / "bundle.json"
    except Exception:
        shutil.rmtree(staging, ignore_errors=True)
        raise


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--server-wheels", required=True, type=Path)
    parser.add_argument("--unmanic-wheels", required=True, type=Path)
    parser.add_argument("--source-revision", required=True)
    parser.add_argument("--platform", choices=("linux/amd64", "linux/arm64"),
                        default=PLATFORMS.get(platform.machine().lower()))
    args = parser.parse_args(argv)
    try:
        manifest = build(args.output, args.server_wheels, args.unmanic_wheels,
                         args.source_revision, args.platform)
        print(manifest)
        return 0
    except Exception:
        print("host_worker_bundle_invalid", file=os.sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
