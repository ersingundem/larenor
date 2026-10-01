#!/usr/bin/env python3
"""Bounded owned-runner UHID access and evdev gamepad-effect witness for F60."""

from __future__ import annotations

from dataclasses import dataclass
import argparse
import os
from pathlib import Path
import re
import select
import stat
import struct
import subprocess
import sys
import time
from typing import Any, Callable, Mapping, Optional, Sequence

from tool.f60_sunshine_owned_host import HostFailure, require_owned_runner


UHID_NODE = Path("/dev/uhid")
UHID_SYSFS_DEV = Path("/sys/class/misc/uhid/dev")
INPUT_ROOT = Path("/dev/input")
INPUT_SYSFS = Path("/sys/class/input")
MAX_ACL_BYTES = 64 * 1024
MAX_SYSFS_BYTES = 4096
MAX_EVENT_BYTES = 64 * 1024
ACL_RESTORE_ATTEMPTS = 2
EVENT_STRUCT = struct.Struct("@llHHi")
EV_SYN = 0
EV_KEY = 1
SYN_REPORT = 0
SYN_DROPPED = 3
BTN_SOUTH = 304
GAMEPAD_NAME = "Sunshine (libvirtualhid) X-Box Series Controller"
GAMEPAD_VENDOR = "045e"
GAMEPAD_PRODUCT = "0b13"
GAMEPAD_UNIQ = "045e:0b13/sunshine-gamepad-0"
GAMEPAD_PHYS_PREFIX = "libvirtualhid/uhid/045e:0b13/"


class GamepadHostFailure(RuntimeError):
    """A bounded, secret-free owned-gamepad host failure."""


def _owned_runner(environment: Mapping[str, str]) -> None:
    try:
        require_owned_runner(environment)
    except HostFailure as error:
        raise GamepadHostFailure("gamepadHostUnavailable") from error


def _read_regular_nofollow(path: Path, maximum: int) -> bytes:
    try:
        info = path.lstat()
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
            raise GamepadHostFailure("gamepadHostUnavailable")
        if not 0 <= info.st_size <= maximum:
            raise GamepadHostFailure("gamepadHostUnavailable")
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(path, flags)
        try:
            opened = os.fstat(descriptor)
            if (opened.st_dev, opened.st_ino) != (info.st_dev, info.st_ino):
                raise GamepadHostFailure("gamepadHostUnavailable")
            data = os.read(descriptor, maximum + 1)
            if len(data) > maximum or os.read(descriptor, 1):
                raise GamepadHostFailure("gamepadHostUnavailable")
            return data
        finally:
            os.close(descriptor)
    except GamepadHostFailure:
        raise
    except OSError as error:
        raise GamepadHostFailure("gamepadHostUnavailable") from error


def _device_number(raw: bytes) -> tuple[int, int]:
    try:
        value = raw.decode("ascii").strip()
    except UnicodeDecodeError as error:
        raise GamepadHostFailure("gamepadHostUnavailable") from error
    match = re.fullmatch(r"([0-9]{1,5}):([0-9]{1,5})", value)
    if match is None:
        raise GamepadHostFailure("gamepadHostUnavailable")
    return int(match.group(1)), int(match.group(2))


def _char_identity(path: Path, sysfs_dev: Path) -> tuple[int, int, int]:
    try:
        info = path.lstat()
    except OSError as error:
        raise GamepadHostFailure("gamepadHostUnavailable") from error
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISCHR(info.st_mode):
        raise GamepadHostFailure("gamepadHostUnavailable")
    expected = _device_number(_read_regular_nofollow(sysfs_dev, MAX_SYSFS_BYTES))
    if (os.major(info.st_rdev), os.minor(info.st_rdev)) != expected:
        raise GamepadHostFailure("gamepadHostUnavailable")
    return info.st_dev, info.st_ino, info.st_rdev


def preflight(
    environment: Mapping[str, str],
    *,
    runner: Callable[..., Any] = subprocess.run,
    uhid: Path = UHID_NODE,
    sysfs_dev: Path = UHID_SYSFS_DEV,
) -> None:
    """Load UHID only on a reviewed hosted runner, then verify its exact identity."""
    _owned_runner(environment)
    try:
        exists = uhid.exists()
    except OSError as error:
        raise GamepadHostFailure("gamepadHostUnavailable") from error
    if not exists:
        completed = runner(
            ["/usr/bin/sudo", "-n", "--", "/usr/sbin/modprobe", "uhid"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=10,
        )
        if completed.returncode != 0:
            raise GamepadHostFailure("gamepadHostUnavailable")
    _char_identity(uhid, sysfs_dev)


def _acl_snapshot(path: Path, runner: Callable[..., Any]) -> bytes:
    completed = runner(
        ["/usr/bin/getfacl", "--absolute-names", "--numeric", str(path)],
        stdin=subprocess.DEVNULL,
        capture_output=True,
        check=False,
        timeout=5,
    )
    output = completed.stdout if isinstance(completed.stdout, bytes) else b""
    if completed.returncode != 0 or not 1 <= len(output) <= MAX_ACL_BYTES:
        raise GamepadHostFailure("gamepadHostUnavailable")
    return output


def _acl_entries(raw: bytes) -> dict[tuple[str, str], str]:
    try:
        lines = raw.decode("ascii").splitlines()
    except UnicodeDecodeError as error:
        raise GamepadHostFailure("gamepadHostUnavailable") from error
    entries: dict[tuple[str, str], str] = {}
    comment_count = 0
    for line in lines:
        if not line:
            continue
        if line.startswith("#"):
            comment_count += 1
            if comment_count > 8 or re.fullmatch(r"#[ -~]{0,512}", line) is None:
                raise GamepadHostFailure("gamepadHostUnavailable")
            continue
        match = re.fullmatch(
            r"(user|group|mask|other):([^:]{0,10}):([r-][w-][x-])",
            line,
        )
        if match is None:
            raise GamepadHostFailure("gamepadHostUnavailable")
        kind, qualifier, permissions = match.groups()
        key = (kind, qualifier)
        if key in entries:
            raise GamepadHostFailure("gamepadHostUnavailable")
        entries[key] = permissions
    return entries


def _base_acl(raw: bytes) -> dict[str, str]:
    entries = _acl_entries(raw)
    expected = {("user", ""), ("group", ""), ("other", "")}
    if set(entries) != expected:
        raise GamepadHostFailure("gamepadHostUnavailable")
    return {kind: entries[(kind, "")] for kind in ("user", "group", "other")}


def _permission_union(left: str, right: str) -> str:
    if re.fullmatch(r"[r-][w-][x-]", left) is None or re.fullmatch(
        r"[r-][w-][x-]", right
    ) is None:
        raise GamepadHostFailure("gamepadHostUnavailable")
    return "".join(
        permission if permission in {left[index], right[index]} else "-"
        for index, permission in enumerate("rwx")
    )


def _verify_granted_acl(
    raw: bytes,
    *,
    base: Mapping[str, str],
    uid: int,
    permissions: str,
    mask: str,
) -> None:
    entries = _acl_entries(raw)
    expected = {
        ("user", ""),
        ("user", str(uid)),
        ("group", ""),
        ("mask", ""),
        ("other", ""),
    }
    if set(entries) != expected:
        raise GamepadHostFailure("gamepadHostUnavailable")
    if any(entries[(kind, "")] != base[kind] for kind in ("user", "group", "other")):
        raise GamepadHostFailure("gamepadHostUnavailable")
    if entries[("user", str(uid))] != permissions or entries[("mask", "")] != mask:
        raise GamepadHostFailure("gamepadHostUnavailable")
    effective = "".join(
        permission
        if entries[("user", str(uid))][index] != "-" and mask[index] != "-"
        else "-"
        for index, permission in enumerate("rwx")
    )
    if effective != permissions:
        raise GamepadHostFailure("gamepadHostUnavailable")


@dataclass(frozen=True)
class AclLease:
    descriptor: int
    proc_path: Path
    identity: tuple[int, int, int]
    snapshot: bytes


def _verify_acl_lease(lease: AclLease) -> None:
    try:
        opened = os.fstat(lease.descriptor)
    except OSError as error:
        raise GamepadHostFailure("gamepadHostUnavailable") from error
    if not stat.S_ISCHR(opened.st_mode) or (
        opened.st_dev,
        opened.st_ino,
        opened.st_rdev,
    ) != lease.identity:
        raise GamepadHostFailure("gamepadHostUnavailable")


def _prepare_acl_lease(
    path: Path,
    expected_identity: tuple[int, int, int],
    runner: Callable[..., Any],
) -> AclLease:
    o_path = getattr(os, "O_PATH", None)
    if o_path is None:
        raise GamepadHostFailure("gamepadHostUnavailable")
    descriptor: Optional[int] = None
    try:
        descriptor = os.open(
            path,
            o_path | os.O_CLOEXEC | getattr(os, "O_NOFOLLOW", 0),
        )
        opened = os.fstat(descriptor)
        identity = (opened.st_dev, opened.st_ino, opened.st_rdev)
        if not stat.S_ISCHR(opened.st_mode) or identity != expected_identity:
            raise GamepadHostFailure("gamepadHostUnavailable")
        proc_path = Path(f"/proc/{os.getpid()}/fd/{descriptor}")
        snapshot = _acl_snapshot(proc_path, runner)
        _base_acl(snapshot)
        lease = AclLease(descriptor, proc_path, identity, snapshot)
        _verify_acl_lease(lease)
        return lease
    except GamepadHostFailure:
        if descriptor is not None:
            os.close(descriptor)
        raise
    except OSError as error:
        if descriptor is not None:
            os.close(descriptor)
        raise GamepadHostFailure("gamepadHostUnavailable") from error


def _grant_acl(
    lease: AclLease,
    permissions: str,
    runner: Callable[..., Any],
) -> None:
    _verify_acl_lease(lease)
    base = _base_acl(lease.snapshot)
    mask = _permission_union(base["group"], permissions)
    uid = os.getuid()
    completed = runner(
        [
            "/usr/bin/sudo",
            "-n",
            "--",
            "/usr/bin/setfacl",
            "--modify",
            f"u:{uid}:{permissions},m::{mask}",
            str(lease.proc_path),
        ],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
        timeout=5,
    )
    if completed.returncode != 0:
        raise GamepadHostFailure("gamepadHostUnavailable")
    _verify_acl_lease(lease)
    _verify_granted_acl(
        _acl_snapshot(lease.proc_path, runner),
        base=base,
        uid=uid,
        permissions=permissions,
        mask=mask,
    )


def _restore_acl(lease: AclLease, runner: Callable[..., Any]) -> None:
    _verify_acl_lease(lease)
    completed = runner(
        ["/usr/bin/sudo", "-n", "--", "/usr/bin/setfacl", "--restore=-"],
        input=lease.snapshot,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
        timeout=5,
    )
    if completed.returncode != 0:
        raise GamepadHostFailure("gamepadHostUnavailable")
    _verify_acl_lease(lease)
    if _base_acl(_acl_snapshot(lease.proc_path, runner)) != _base_acl(lease.snapshot):
        raise GamepadHostFailure("gamepadHostUnavailable")


def _restore_acl_bounded(lease: AclLease, runner: Callable[..., Any]) -> None:
    last_error: Optional[BaseException] = None
    for _attempt in range(ACL_RESTORE_ATTEMPTS):
        try:
            _restore_acl(lease, runner)
            return
        except BaseException as error:
            last_error = error
    raise GamepadHostFailure("gamepadHostUnavailable") from last_error


def _sysfs_text(device: Path, name: str) -> str:
    if re.fullmatch(r"[a-z]+", name) is None:
        raise GamepadHostFailure("gamepadHostUnavailable")
    try:
        canonical = device.resolve(strict=True)
        canonical.relative_to(Path("/sys/devices"))
    except (OSError, ValueError) as error:
        raise GamepadHostFailure("gamepadHostUnavailable") from error
    raw = _read_regular_nofollow(canonical / name, MAX_SYSFS_BYTES)
    try:
        return raw.decode("utf-8").strip()
    except UnicodeDecodeError as error:
        raise GamepadHostFailure("gamepadHostUnavailable") from error


@dataclass(frozen=True)
class EventNode:
    path: Path
    sysfs_dev: Path
    identity: tuple[int, int, int]


class OwnedGamepadAccess:
    """Grant and restore exact hosted-runner ACLs while proving one owned evdev."""

    def __init__(
        self,
        environment: Mapping[str, str],
        *,
        runner: Callable[..., Any] = subprocess.run,
        uhid: Path = UHID_NODE,
        uhid_sysfs_dev: Path = UHID_SYSFS_DEV,
        input_root: Path = INPUT_ROOT,
        input_sysfs: Path = INPUT_SYSFS,
        monotonic: Callable[[], float] = time.monotonic,
        sleeper: Callable[[float], None] = time.sleep,
    ) -> None:
        _owned_runner(environment)
        self._environment = environment
        self._runner = runner
        self._uhid = uhid
        self._uhid_sysfs_dev = uhid_sysfs_dev
        self._input_root = input_root
        self._input_sysfs = input_sysfs
        self._monotonic = monotonic
        self._sleeper = sleeper
        self._baseline: set[tuple[int, int, int]] = set()
        self._uhid_identity: Optional[tuple[int, int, int]] = None
        self._uhid_acl: Optional[AclLease] = None
        self._event_acl: Optional[AclLease] = None
        self._event: Optional[EventNode] = None
        self._descriptor: Optional[int] = None

    def __enter__(self) -> "OwnedGamepadAccess":
        preflight(
            self._environment,
            runner=self._runner,
            uhid=self._uhid,
            sysfs_dev=self._uhid_sysfs_dev,
        )
        self._baseline = {node.identity for node in self._event_nodes(require_match=False)}
        identity = _char_identity(self._uhid, self._uhid_sysfs_dev)
        self._uhid_identity = identity
        flags = os.O_RDWR | os.O_NONBLOCK | getattr(os, "O_NOFOLLOW", 0)
        try:
            self._uhid_acl = _prepare_acl_lease(self._uhid, identity, self._runner)
            _grant_acl(self._uhid_acl, "rw-", self._runner)
            descriptor = os.open(self._uhid, flags)
            opened = os.fstat(descriptor)
            if (opened.st_dev, opened.st_ino, opened.st_rdev) != identity:
                raise GamepadHostFailure("gamepadHostUnavailable")
        except BaseException:
            if "descriptor" in locals():
                os.close(descriptor)
            self.close()
            raise
        os.close(descriptor)
        return self

    def _event_nodes(self, *, require_match: bool) -> list[EventNode]:
        try:
            names = sorted(path.name for path in self._input_root.glob("event*"))
        except OSError as error:
            raise GamepadHostFailure("gamepadHostUnavailable") from error
        result: list[EventNode] = []
        for name in names:
            if re.fullmatch(r"event[0-9]{1,5}", name) is None:
                continue
            path = self._input_root / name
            sysfs_entry = self._input_sysfs / name
            try:
                identity = _char_identity(path, sysfs_entry / "dev")
                if require_match:
                    device = sysfs_entry / "device"
                    if (
                        _sysfs_text(device, "name") != GAMEPAD_NAME
                        or _sysfs_text(device / "id", "vendor").lower() != GAMEPAD_VENDOR
                        or _sysfs_text(device / "id", "product").lower() != GAMEPAD_PRODUCT
                        or _sysfs_text(device, "uniq") != GAMEPAD_UNIQ
                        or not _sysfs_text(device, "phys").startswith(GAMEPAD_PHYS_PREFIX)
                    ):
                        continue
                result.append(EventNode(path, sysfs_entry / "dev", identity))
            except GamepadHostFailure:
                if require_match:
                    continue
                raise
        return result

    def arm(self, timeout_seconds: float = 10.0) -> None:
        if self._descriptor is not None or not 0 < timeout_seconds <= 30:
            raise GamepadHostFailure("gamepadHostUnavailable")
        deadline = self._monotonic() + timeout_seconds
        candidates: list[EventNode] = []
        while self._monotonic() < deadline:
            candidates = [
                node
                for node in self._event_nodes(require_match=True)
                if node.identity not in self._baseline
            ]
            if candidates:
                break
            self._sleeper(0.05)
        if len(candidates) != 1:
            raise GamepadHostFailure("gamepadHostUnavailable")
        event = candidates[0]
        if _char_identity(event.path, event.sysfs_dev) != event.identity:
            raise GamepadHostFailure("gamepadHostUnavailable")
        flags = os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_NOFOLLOW", 0)
        self._event = event
        try:
            self._event_acl = _prepare_acl_lease(event.path, event.identity, self._runner)
            _grant_acl(self._event_acl, "r--", self._runner)
            descriptor = os.open(event.path, flags)
            opened = os.fstat(descriptor)
            if (opened.st_dev, opened.st_ino, opened.st_rdev) != event.identity:
                raise GamepadHostFailure("gamepadHostUnavailable")
            drained = 0
            while True:
                try:
                    chunk = os.read(descriptor, EVENT_STRUCT.size * 32)
                except BlockingIOError:
                    break
                if not chunk:
                    break
                drained += len(chunk)
                if drained > MAX_EVENT_BYTES or len(chunk) % EVENT_STRUCT.size:
                    raise GamepadHostFailure("gamepadHostUnavailable")
        except BaseException:
            if "descriptor" in locals():
                os.close(descriptor)
            self.close()
            raise
        self._descriptor = descriptor

    def wait_effect(self, timeout_seconds: float = 10.0) -> None:
        descriptor = self._descriptor
        if descriptor is None or not 0 < timeout_seconds <= 30:
            raise GamepadHostFailure("gamepadHostUnavailable")
        deadline = self._monotonic() + timeout_seconds
        state = 0
        buffered = bytearray()
        total = 0
        while self._monotonic() < deadline:
            ready, _, _ = select.select([descriptor], [], [], max(0.0, deadline - self._monotonic()))
            if not ready:
                break
            try:
                chunk = os.read(descriptor, EVENT_STRUCT.size * 32)
            except BlockingIOError:
                continue
            if not chunk:
                break
            total += len(chunk)
            if total > MAX_EVENT_BYTES:
                raise GamepadHostFailure("gamepadHostUnavailable")
            buffered.extend(chunk)
            while len(buffered) >= EVENT_STRUCT.size:
                raw = bytes(buffered[: EVENT_STRUCT.size])
                del buffered[: EVENT_STRUCT.size]
                _seconds, _micros, event_type, code, value = EVENT_STRUCT.unpack(raw)
                if event_type == EV_SYN and code == SYN_DROPPED:
                    raise GamepadHostFailure("gamepadHostUnavailable")
                if state == 0 and event_type == EV_KEY and code == BTN_SOUTH and value == 1:
                    state = 1
                elif state == 1 and event_type == EV_SYN and code == SYN_REPORT:
                    state = 2
                elif state == 2 and event_type == EV_KEY and code == BTN_SOUTH and value == 0:
                    state = 3
                elif state == 3 and event_type == EV_SYN and code == SYN_REPORT:
                    return
                elif event_type == EV_KEY and code == BTN_SOUTH:
                    raise GamepadHostFailure("gamepadHostUnavailable")
        raise GamepadHostFailure("gamepadHostUnavailable")

    def disarm(self) -> None:
        failures = []
        if self._descriptor is not None:
            try:
                os.close(self._descriptor)
            except OSError as error:
                failures.append(error)
            self._descriptor = None
        if self._event_acl is not None:
            try:
                _restore_acl_bounded(self._event_acl, self._runner)
            except BaseException as error:
                failures.append(error)
            else:
                lease = self._event_acl
                self._event_acl = None
                self._event = None
                try:
                    os.close(lease.descriptor)
                except OSError as error:
                    failures.append(error)
        if failures:
            raise GamepadHostFailure("gamepadHostUnavailable") from failures[0]

    def close(self) -> None:
        failures = []
        try:
            self.disarm()
        except BaseException as error:
            failures.append(error)
        if self._uhid_acl is not None:
            try:
                _restore_acl_bounded(self._uhid_acl, self._runner)
            except BaseException as error:
                failures.append(error)
            else:
                lease = self._uhid_acl
                self._uhid_acl = None
                try:
                    os.close(lease.descriptor)
                except OSError as error:
                    failures.append(error)
        if failures:
            raise GamepadHostFailure("gamepadHostUnavailable") from failures[0]

    def __exit__(self, _kind: Any, _value: Any, _traceback: Any) -> None:
        self.close()


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Preflight the owned F60 gamepad host")
    parser.add_argument("command", choices=("preflight",))
    arguments = parser.parse_args(argv)
    if arguments.command == "preflight":
        preflight(os.environ)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except GamepadHostFailure as error:
        print("F60_GAMEPAD_FAILURE:" + str(error), file=sys.stderr)
        raise SystemExit(1) from None
