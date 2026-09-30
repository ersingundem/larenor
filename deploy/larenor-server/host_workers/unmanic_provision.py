#!/usr/bin/env python3
"""Install the two reviewed local plugin archives with Unmanic's own API."""

import argparse
import importlib.util
import os
from pathlib import Path
import shutil
import stat
import tempfile

from unmanic import config
from unmanic.libs.plugins import PluginsHandler
from unmanic.service import init_db


EXPECTED = {
    "callback": "larenor_archive_terminal",
    "encoder": "larenor_archive_encoder",
}


def _archive(path):
    value = Path(path)
    before = os.stat(value, follow_symlinks=False)
    if (not stat.S_ISREG(before.st_mode) or before.st_uid != 0
            or stat.S_IMODE(before.st_mode) != 0o644 or before.st_nlink != 1
            or not 1 <= before.st_size <= 256 * 1024):
        raise ValueError()
    return value, before


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--callback", required=True)
    parser.add_argument("--encoder", required=True)
    args = parser.parse_args(argv)
    database = None
    try:
        archives = {name: _archive(getattr(args, name)) for name in EXPECTED}
        settings = config.Config()
        database = init_db(settings.get_config_path())
        handler = PluginsHandler()
        with tempfile.TemporaryDirectory(
                prefix="larenor-unmanic-plugins-",
                dir=settings.get_config_path()) as directory:
            for name, expected_id in EXPECTED.items():
                source, identity = archives[name]
                copied = Path(directory) / (name + ".zip")
                shutil.copyfile(source, copied, follow_symlinks=False)
                copied.chmod(0o600)
                after = os.stat(source, follow_symlinks=False)
                if ((identity.st_dev, identity.st_ino, identity.st_size,
                     identity.st_mtime_ns, identity.st_ctime_ns)
                        != (after.st_dev, after.st_ino, after.st_size,
                            after.st_mtime_ns, after.st_ctime_ns)
                        or not handler.install_plugin_from_path_on_disk(str(copied))):
                    raise ValueError()
                installed = handler.get_plugin_info(expected_id)
                if (not isinstance(installed, dict)
                        or installed.get("id") != expected_id
                        or installed.get("version") != "1.0.0"):
                    raise ValueError()
        encoder_path = Path(handler.get_plugin_path(EXPECTED["encoder"])) / "plugin.py"
        spec = importlib.util.spec_from_file_location(
            "larenor_installed_archive_encoder", encoder_path)
        if spec is None or spec.loader is None:
            raise ValueError()
        encoder = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(encoder)
        encoder._configured()
        return 0
    except Exception:
        return 1
    finally:
        if database is not None:
            database.stop()


if __name__ == "__main__":
    raise SystemExit(main())
