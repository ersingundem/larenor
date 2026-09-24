"""Fail-closed capability contract for privileged Linux btrfs capture."""

import os
from pathlib import Path
from types import SimpleNamespace
import time

import pytest

from larenor_server.core_backups.component_linux_capture_preflight import (
    CAP_SYS_ADMIN,
    LinuxBtrfsCaptureCapability,
    LinuxBtrfsCapturePreflight,
    LinuxCapturePreflightError,
    parse_effective_capabilities,
)
from larenor_server.plugins.linux_mount_observation import (
    MountObservation,
    MountRecord,
)


class System:
    def __init__(self, root):
        self.root = root
        self.platform = "linux"
        self.uid = 0
        self.capabilities = 1 << CAP_SYS_ADMIN
        self.filesystem = "btrfs"
        self.read_only = False
        self.idmapped = False
        self.path_reads = 0
        self.drift_path = False
        self.opened = []
        self.closed = []

    def platform_name(self):
        return self.platform

    def effective_uid(self):
        return self.uid

    def effective_capabilities(self, deadline):
        assert time.monotonic() < deadline
        return self.capabilities

    def open_directory(self, path):
        descriptor = os.open(
            path,
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
        )
        self.opened.append(descriptor)
        return descriptor

    def path_info(self, path):
        assert path == self.root
        self.path_reads += 1
        value = path.lstat()
        value = SimpleNamespace(
            st_mode=value.st_mode,
            st_dev=value.st_dev,
            st_ino=value.st_ino,
            st_uid=self.uid,
            st_gid=0,
        )
        if self.drift_path and self.path_reads > 1:
            return SimpleNamespace(
                st_mode=value.st_mode,
                st_dev=value.st_dev,
                st_ino=value.st_ino + 1,
                st_uid=value.st_uid,
                st_gid=value.st_gid,
            )
        return value

    def descriptor_info(self, descriptor):
        value = os.fstat(descriptor)
        return SimpleNamespace(
            st_mode=value.st_mode,
            st_dev=value.st_dev,
            st_ino=value.st_ino,
            st_uid=self.uid,
            st_gid=0,
        )

    def observe_mount(self, descriptor, deadline):
        assert time.monotonic() < deadline
        value = os.fstat(descriptor)
        options = (("ro",) if self.read_only else ("rw",)) + (
            ("idmapped",) if self.idmapped else ()
        )
        optional = ()
        mount = MountRecord(
            17,
            1,
            os.major(value.st_dev),
            os.minor(value.st_dev),
            "/",
            str(self.root),
            options,
            optional,
            self.filesystem,
            options,
        )
        return MountObservation(
            mount,
            (
                value.st_dev,
                value.st_ino,
                self.uid,
                0,
                value.st_mode & 0o7777,
            ),
            (31, 32),
            (41, 42, 0, 0, 0o755, 1),
        )

    def close(self, descriptor):
        os.close(descriptor)
        self.closed.append(descriptor)


def test_preflight_returns_exact_secret_free_btrfs_capability(tmp_path):
    root = tmp_path / "private-capture-root"
    root.mkdir(mode=0o700)
    system = System(root)

    capability = LinuxBtrfsCapturePreflight(root, system=system).verify(
        time.monotonic() + 2
    )

    info = root.stat()
    assert capability == LinuxBtrfsCaptureCapability(
        schema_version=1,
        capture_device=info.st_dev,
        capture_inode=info.st_ino,
        mount_id=17,
        namespace_device=31,
        namespace_inode=32,
    )
    assert repr(capability) == "LinuxBtrfsCaptureCapability(<private>)"
    assert str(root) not in repr(capability)
    assert system.closed == system.opened


def test_capability_receipt_rejects_non_exact_fields():
    for values in (
        (True, 11, 12, 13, 14, 15),
        (1, -1, 12, 13, 14, 15),
        (1, 11, 0, 13, 14, 15),
        (1, 11, 12, 0, 14, 15),
    ):
        with pytest.raises(
            LinuxCapturePreflightError, match="^linux_capture_unavailable$"
        ):
            LinuxBtrfsCaptureCapability(*values)


@pytest.mark.parametrize(
    ("damage", "value"),
    [
        ("platform", "darwin"),
        ("uid", 1000),
        ("capabilities", 0),
        ("filesystem", "ext4"),
        ("read_only", True),
        ("idmapped", True),
        ("drift_path", True),
    ],
)
def test_preflight_rejects_unsupported_or_stale_host_without_details(
    tmp_path, damage, value
):
    root = tmp_path / "private-host-detail"
    root.mkdir(mode=0o700)
    system = System(root)
    setattr(system, damage, value)

    with pytest.raises(
        LinuxCapturePreflightError, match="^linux_capture_unavailable$"
    ) as caught:
        LinuxBtrfsCapturePreflight(root, system=system).verify(
            time.monotonic() + 2
        )

    assert str(root) not in repr(caught.value)
    assert system.closed == system.opened
    for descriptor in system.closed:
        with pytest.raises(OSError):
            os.fstat(descriptor)


def test_preflight_revalidation_fails_closed_on_identity_drift(tmp_path):
    root = tmp_path / "capture-root"
    root.mkdir(mode=0o700)
    system = System(root)
    preflight = LinuxBtrfsCapturePreflight(root, system=system)
    capability = preflight.verify(time.monotonic() + 2)

    system.drift_path = True
    system.path_reads = 1
    assert preflight.revalidate(capability, time.monotonic() + 2) is False
    assert preflight.revalidate(object(), time.monotonic() + 2) is False


@pytest.mark.parametrize(
    "value",
    [
        b"Name:\tworker\n",
        b"CapEff:\t0000000000200000\nCapEff:\t0000000000200000\n",
        b"CapEff:\t000000000020000G\n",
        b"CapEff:\t200000\n",
        b"CapEff:\t0000000000200000",
        b"CapEff:\t0000000000200000\x00\n",
    ],
)
def test_effective_capability_parser_rejects_noncanonical_status(value):
    with pytest.raises(
        LinuxCapturePreflightError, match="^linux_capture_unavailable$"
    ):
        parse_effective_capabilities(value)


def test_effective_capability_parser_accepts_exact_kernel_field():
    assert parse_effective_capabilities(
        b"Name:\tworker\nCapEff:\t0000000000200000\nNoNewPrivs:\t0\n"
    ) == 1 << CAP_SYS_ADMIN
