"""Reproducible dependency-free Unmanic callback plugin archive."""

import argparse
import hashlib
from importlib.resources import files
import io
import json
import os
from pathlib import Path
import sys
import zipfile


PLUGIN_ID = "larenor_archive_terminal"
PLUGIN_VERSION = "1.0.0"


def callback_plugin_package():
    """Plugin metadata follows Unmanic plugin handler v2, without vendored code."""
    metadata = {
        "id": PLUGIN_ID, "name": "Larenor archive terminal delivery",
        "author": "Larenor contributors", "version": PLUGIN_VERSION,
        "compatibility": [2], "platform": ["linux", "mac"],
        "description": "Durable authenticated terminal callbacks for confirmed Larenor archive jobs.",
        "tags": "larenor,archive,events", "icon": "",
        "priorities": {"emit_postprocessor_complete": 0},
    }
    source = files("larenor_server.media_archive_actions").joinpath("callback_plugin.py").read_bytes()
    compile(source, "plugin.py", "exec")
    archive = io.BytesIO()
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as output:
        for name, content in (
            ("info.json", json.dumps(metadata, sort_keys=True, separators=(",", ":")).encode()),
            ("plugin.py", source),
            ("description.md", b"# Larenor archive terminal delivery\n\n"
             b"Requires Unmanic 0.4.1 and an explicitly provisioned private callback configuration.\n"
             b"Set LARENOR_UNMANIC_CALLBACK_CONFIG to the owned 0600 JSON file before starting Unmanic.\n"
             b"This plugin observes completion; it does not alter the task or transcode media.\n"
             b"No Python packages, network downloads or external dependencies are installed.\n"),
        ):
            info = zipfile.ZipInfo(name, (2026, 9, 30, 0, 0, 0))
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            output.writestr(info, content)
    return archive.getvalue()


def encoder_plugin_package():
    metadata = {
        "id": "larenor_archive_encoder", "name": "Larenor confirmed archive encoder",
        "author": "Larenor contributors", "version": PLUGIN_VERSION,
        "compatibility": [2], "platform": ["linux", "mac"],
        "description": "Transcode isolated work copies using individually authenticated Larenor plans.",
        "tags": "larenor,archive,video", "icon": "",
        "priorities": {"on_library_management_file_test": 0, "on_worker_process": 0},
    }
    source = files("larenor_server.media_archive_actions").joinpath("encoder_plugin.py").read_bytes()
    compile(source, "plugin.py", "exec")
    archive = io.BytesIO()
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as output:
        for name, content in (
            ("info.json", json.dumps(metadata, sort_keys=True, separators=(",", ":")).encode()),
            ("plugin.py", source),
            ("description.md", b"# Larenor confirmed archive encoder\n\n"
             b"Requires Unmanic 0.4.1, FFmpeg with libx265/libsvtav1, and isolated work/cache roots.\n"
             b"Set LARENOR_UNMANIC_ENCODER_CONFIG to an owned 0600 JSON file before startup.\n"
             b"Only signed per-command plans are queued; all audio and subtitle streams are copied.\n"
             b"No Python packages, network downloads or external dependencies are installed.\n"),
        ):
            info = zipfile.ZipInfo(name, (2026, 9, 30, 0, 0, 0))
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            output.writestr(info, content)
    return archive.getvalue()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--kind", choices=("callback", "encoder"), default="callback")
    args = parser.parse_args(argv)
    descriptor = None
    try:
        if args.output.is_symlink():
            raise ValueError()
        package = callback_plugin_package() if args.kind == "callback" else encoder_plugin_package()
        descriptor = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644)
        with os.fdopen(descriptor, "wb") as stream:
            descriptor = None
            stream.write(package)
            stream.flush()
            os.fsync(stream.fileno())
        print("archive_" + args.kind + "_package_sha256=" + hashlib.sha256(package).hexdigest())
        return 0
    except (OSError, ValueError):
        print("archive_callback_package_unavailable", file=sys.stderr)
        return 2
    finally:
        if descriptor is not None:
            os.close(descriptor)


if __name__ == "__main__":
    raise SystemExit(main())
