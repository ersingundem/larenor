import os
from pathlib import Path
import platform
import shutil
import subprocess

import pytest


ROOT = Path(__file__).resolve().parents[2]
ASSETS = ROOT / "deploy/larenor-server/host_workers"
UNITS = (
    "larenor-preflight-worker.service",
    "larenor-installation-worker.service",
    "larenor-unmanic-provision.service",
    "larenor-unmanic.service",
    "larenor-media-archive-worker.service",
    "larenor-ai-worker.service",
)


def _hosted_root_gate():
    return (platform.system() == "Linux" and os.geteuid() == 0
            and os.environ.get("CI") == "true"
            and os.environ.get("GITHUB_ACTIONS") == "true"
            and os.environ.get("RUNNER_ENVIRONMENT") == "github-hosted"
            and os.environ.get("LARENOR_HOST_WORKER_SYSTEMD_ACCEPTANCE") == "1")


@pytest.mark.skipif(not _hosted_root_gate(), reason="requires isolated hosted Linux root")
def test_production_units_are_loaded_and_verified_by_real_systemd():
    systemctl = Path("/usr/bin/systemctl")
    analyze = Path("/usr/bin/systemd-analyze")
    sysusers = Path("/usr/bin/systemd-sysusers")
    assert systemctl.is_file() and analyze.is_file() and sysusers.is_file()
    destination = Path("/etc/systemd/system")
    installed = []
    prefix = Path("/opt/larenor-server-host")
    helper = Path("/usr/libexec/larenor-unmanic-provision")
    assert not prefix.exists() and not helper.exists()
    try:
        subprocess.run([sysusers, ASSETS / "larenor-host-workers.sysusers"],
                       check=True, timeout=20)
        current = prefix / "current"
        current.mkdir(parents=True)
        (current / "server").symlink_to(ROOT / "server/.venv", target_is_directory=True)
        (current / "unmanic/bin").mkdir(parents=True)
        (current / "unmanic/bin/python").symlink_to("/bin/true")
        (current / "unmanic/bin/unmanic").symlink_to("/bin/true")
        shutil.copyfile(ASSETS / "unmanic_provision.py", helper)
        helper.chmod(0o755)
        for name in UNITS:
            target = destination / name
            assert not target.exists(), "host_worker_unit_already_exists"
            shutil.copyfile(ASSETS / name, target)
            target.chmod(0o644)
            installed.append(target)
        subprocess.run([systemctl, "daemon-reload"], check=True, timeout=20)
        subprocess.run([analyze, "verify", *installed], check=True, timeout=20,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        for source, target in zip((ASSETS / name for name in UNITS), installed):
            assert target.read_bytes() == source.read_bytes()
            shown = subprocess.run([systemctl, "show", target.name,
                                    "--property=LoadState", "--value"],
                                   check=True, timeout=10, text=True,
                                   stdout=subprocess.PIPE).stdout.strip()
            assert shown == "loaded"
    finally:
        for target in installed:
            target.unlink(missing_ok=True)
        subprocess.run([systemctl, "daemon-reload"], check=False, timeout=20,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        helper.unlink(missing_ok=True)
        shutil.rmtree(prefix, ignore_errors=True)
