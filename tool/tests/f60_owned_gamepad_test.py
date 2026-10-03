from __future__ import annotations

import os
from pathlib import Path
import stat
import subprocess
import unittest
from unittest import mock

from tool import f60_owned_gamepad as gamepad


class _Completed:
    def __init__(self, returncode: int = 0, stdout: bytes = b"") -> None:
        self.returncode = returncode
        self.stdout = stdout


def _char_stat(identity: tuple[int, int, int]):
    return type("Opened", (), {
        "st_mode": stat.S_IFCHR,
        "st_dev": identity[0],
        "st_ino": identity[1],
        "st_rdev": identity[2],
    })()


def _acl_lease(descriptor: int, identity: tuple[int, int, int], snapshot: bytes):
    return gamepad.AclLease(
        descriptor,
        Path(f"/proc/{os.getpid()}/fd/{descriptor}"),
        identity,
        snapshot,
    )


def _base_acl_bytes(*, group: str = "---") -> bytes:
    return (
        b"# file: /proc/123/fd/91\n# owner: 0\n# group: 0\n"
        + f"user::rw-\ngroup::{group}\nother::---\n".encode("ascii")
    )


def _granted_acl_bytes(*, permissions: str, mask: str, group: str = "---") -> bytes:
    return (
        b"# file: /proc/123/fd/91\n# owner: 0\n# group: 0\n"
        + (
            f"user::rw-\nuser:{os.getuid()}:{permissions}\ngroup::{group}\n"
            f"mask::{mask}\nother::---\n"
        ).encode("ascii")
    )


class F60OwnedGamepadTest(unittest.TestCase):
    def test_self_hosted_preflight_stops_before_device_or_privilege_calls(self) -> None:
        runner = mock.Mock()
        with self.assertRaisesRegex(gamepad.GamepadHostFailure, "gamepadRunnerUnavailable"):
            gamepad.preflight(
                {"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "self-hosted"},
                runner=runner,
            )
        runner.assert_not_called()

    def test_missing_uhid_load_is_fixed_argv_and_identity_is_required(self) -> None:
        runner = mock.Mock(return_value=_Completed())
        with mock.patch.object(gamepad, "require_owned_runner"), \
                mock.patch.object(gamepad.Path, "exists", return_value=False), \
                mock.patch.object(gamepad, "_char_identity", return_value=(1, 2, 3)) as identity:
            gamepad.preflight({}, runner=runner)
        self.assertEqual(
            ["/usr/bin/sudo", "-n", "--", "/usr/sbin/modprobe", "uhid"],
            runner.call_args.args[0],
        )
        identity.assert_called_once_with(gamepad.UHID_NODE, gamepad.UHID_SYSFS_DEV)

    def test_preflight_distinguishes_module_load_failure_without_output(self) -> None:
        runner = mock.Mock(return_value=_Completed(returncode=1))
        with mock.patch.object(gamepad, "require_owned_runner"), \
                mock.patch.object(gamepad.Path, "exists", return_value=False):
            with self.assertRaisesRegex(
                gamepad.GamepadHostFailure, "gamepadKernelModuleUnavailable"
            ):
                gamepad.preflight({}, runner=runner)
        self.assertEqual(subprocess.DEVNULL, runner.call_args.kwargs["stderr"])

    def test_module_spawn_and_timeout_cannot_leak_private_command_data(self) -> None:
        for failure in (
            OSError("private spawn details"),
            subprocess.TimeoutExpired(["private", "credential"], 10),
        ):
            with self.subTest(failure=type(failure).__name__), \
                    mock.patch.object(gamepad, "require_owned_runner"), \
                    mock.patch.object(gamepad.Path, "exists", return_value=False), \
                    mock.patch.object(gamepad, "_char_identity") as identity:
                with self.assertRaises(gamepad.GamepadHostFailure) as caught:
                    gamepad.preflight({}, runner=mock.Mock(side_effect=failure))
                self.assertEqual("gamepadKernelModuleUnavailable", str(caught.exception))
                identity.assert_not_called()

    def test_preflight_distinguishes_missing_or_mismatched_device_identity(self) -> None:
        runner = mock.Mock(return_value=_Completed())
        with mock.patch.object(gamepad, "require_owned_runner"), \
                mock.patch.object(gamepad.Path, "exists", return_value=False), \
                mock.patch.object(
                    gamepad,
                    "_char_identity",
                    side_effect=gamepad.GamepadHostFailure("gamepadHostUnavailable"),
                ):
            with self.assertRaisesRegex(
                gamepad.GamepadHostFailure, "gamepadDeviceIdentityUnavailable"
            ):
                gamepad.preflight({}, runner=runner)

    def test_preflight_distinguishes_device_query_failure_before_module_load(self) -> None:
        runner = mock.Mock()
        with mock.patch.object(gamepad, "require_owned_runner"), \
                mock.patch.object(gamepad.Path, "exists", side_effect=OSError("private")):
            with self.assertRaisesRegex(
                gamepad.GamepadHostFailure, "gamepadDeviceUnavailable"
            ):
                gamepad.preflight({}, runner=runner)
        runner.assert_not_called()

    def test_acl_grants_are_exact_uid_scoped_and_restore_original_bytes(self) -> None:
        identity = (1, 2, os.makedev(10, 239))
        snapshot = _base_acl_bytes(group="---")
        lease = _acl_lease(88, identity, snapshot)
        calls = []
        readbacks = iter([
            _granted_acl_bytes(permissions="rw-", mask="rw-", group="---"),
            snapshot,
        ])

        def runner(argv, **kwargs):
            calls.append((list(argv), kwargs))
            if argv[0] == "/usr/bin/getfacl":
                return _Completed(stdout=next(readbacks))
            return _Completed()

        with mock.patch.object(gamepad.os, "fstat", return_value=_char_stat(identity)):
            gamepad._grant_acl(lease, "rw-", runner)
            gamepad._restore_acl(lease, runner)
        self.assertEqual("--modify", calls[0][0][4])
        self.assertEqual(f"u:{os.getuid()}:rw-,m::rw-", calls[0][0][5])
        self.assertEqual(str(lease.proc_path), calls[0][0][-1])
        self.assertEqual(
            ["/usr/bin/sudo", "-n", "--", "/usr/bin/setfacl", "--restore=-"],
            calls[2][0],
        )
        self.assertEqual(snapshot, calls[2][1]["input"])

    def test_acl_lease_anchors_snapshot_to_verified_proc_descriptor(self) -> None:
        identity = (11, 12, os.makedev(13, 14))
        snapshot = _base_acl_bytes()
        with mock.patch.object(gamepad.os, "O_PATH", 0x200000, create=True), \
                mock.patch.object(gamepad.os, "open", return_value=91) as open_node, \
                mock.patch.object(gamepad.os, "fstat", return_value=_char_stat(identity)), \
                mock.patch.object(gamepad, "_acl_snapshot", return_value=snapshot) as capture, \
                mock.patch.object(gamepad.os, "close"):
            lease = gamepad._prepare_acl_lease(Path("/dev/input/event9"), identity, mock.Mock())
        self.assertEqual(91, lease.descriptor)
        self.assertEqual(Path(f"/proc/{os.getpid()}/fd/91"), lease.proc_path)
        self.assertEqual(snapshot, lease.snapshot)
        self.assertTrue(open_node.call_args.args[1] & 0x200000)
        capture.assert_called_once_with(lease.proc_path, mock.ANY)

    def test_acl_lease_rejects_preexisting_named_or_mask_entries(self) -> None:
        identity = (11, 12, os.makedev(13, 14))
        extended = _granted_acl_bytes(permissions="r--", mask="r--")
        with mock.patch.object(gamepad.os, "O_PATH", 0x200000, create=True), \
                mock.patch.object(gamepad.os, "open", return_value=91), \
                mock.patch.object(gamepad.os, "fstat", return_value=_char_stat(identity)), \
                mock.patch.object(gamepad, "_acl_snapshot", return_value=extended), \
                mock.patch.object(gamepad.os, "close") as close_descriptor:
            with self.assertRaises(gamepad.GamepadHostFailure):
                gamepad._prepare_acl_lease(Path("/dev/input/event9"), identity, mock.Mock())
        close_descriptor.assert_called_once_with(91)

    def test_acl_grant_rejects_effective_permission_readback_drift(self) -> None:
        identity = (11, 12, os.makedev(13, 14))
        lease = _acl_lease(91, identity, _base_acl_bytes())

        def runner(argv, **_kwargs):
            if argv[0] == "/usr/bin/getfacl":
                return _Completed(
                    stdout=_granted_acl_bytes(permissions="r--", mask="---")
                )
            return _Completed()

        with mock.patch.object(gamepad.os, "fstat", return_value=_char_stat(identity)):
            with self.assertRaises(gamepad.GamepadHostFailure):
                gamepad._grant_acl(lease, "r--", runner)

    def test_failed_acl_mutation_keeps_lease_available_for_exact_cleanup(self) -> None:
        identity = (11, 12, os.makedev(13, 14))
        snapshot = _base_acl_bytes()
        lease = _acl_lease(91, identity, snapshot)
        calls = []

        def runner(argv, **kwargs):
            calls.append((list(argv), kwargs))
            if "--modify" in argv:
                return _Completed(returncode=1)
            if argv[0] == "/usr/bin/getfacl":
                return _Completed(stdout=snapshot)
            return _Completed()

        access = object.__new__(gamepad.OwnedGamepadAccess)
        access._descriptor = None
        access._event = gamepad.EventNode(
            Path("/dev/input/event9"), Path("/sys/event9/dev"), identity
        )
        access._event_acl = lease
        access._uhid_acl = None
        access._runner = runner
        with mock.patch.object(gamepad.os, "fstat", return_value=_char_stat(identity)), \
                mock.patch.object(gamepad.os, "close"):
            with self.assertRaises(gamepad.GamepadHostFailure):
                gamepad._grant_acl(lease, "r--", runner)
            self.assertIs(access._event_acl, lease)
            access.disarm()
        self.assertIsNone(access._event_acl)
        self.assertEqual(
            ["/usr/bin/sudo", "-n", "--", "/usr/bin/setfacl", "--restore=-"],
            calls[-2][0],
        )
        self.assertEqual(snapshot, calls[-2][1]["input"])

    def test_transient_restore_failure_retries_before_releasing_acl_snapshot(self) -> None:
        identity = (11, 12, os.makedev(13, 14))
        snapshot = b"# file: /proc/123/fd/91\nuser::rw-\ngroup::---\nother::---\n"
        lease = _acl_lease(91, identity, snapshot)
        access = object.__new__(gamepad.OwnedGamepadAccess)
        access._descriptor = None
        access._event = gamepad.EventNode(
            Path("/dev/input/event9"), Path("/sys/event9/dev"), identity
        )
        access._event_acl = lease
        access._uhid_acl = None
        access._runner = mock.Mock()

        with mock.patch.object(
            gamepad, "_restore_acl", side_effect=[
                gamepad.GamepadHostFailure("gamepadHostUnavailable"), None
            ]
        ) as restore, mock.patch.object(gamepad.os, "close") as close_descriptor:
            access.disarm()
        self.assertIsNone(access._event_acl)
        self.assertEqual([mock.call(lease, access._runner)] * 2, restore.call_args_list)
        close_descriptor.assert_called_once_with(lease.descriptor)

    def test_persistent_restore_failure_retains_acl_snapshot_for_later_retry(self) -> None:
        identity = (11, 12, os.makedev(13, 14))
        lease = _acl_lease(91, identity, b"event-acl")
        access = object.__new__(gamepad.OwnedGamepadAccess)
        access._descriptor = None
        access._event = gamepad.EventNode(
            Path("/dev/input/event9"), Path("/sys/event9/dev"), identity
        )
        access._event_acl = lease
        access._uhid_acl = None
        access._runner = mock.Mock()
        with mock.patch.object(
            gamepad, "_restore_acl", side_effect=gamepad.GamepadHostFailure(
                "gamepadHostUnavailable"
            )
        ) as restore, mock.patch.object(gamepad.os, "close") as close_descriptor:
            with self.assertRaises(gamepad.GamepadHostFailure):
                access.disarm()
        self.assertIs(access._event_acl, lease)
        self.assertEqual(gamepad.ACL_RESTORE_ATTEMPTS, restore.call_count)
        close_descriptor.assert_not_called()

    def test_arm_requires_one_new_identity_matched_event_and_read_only_open(self) -> None:
        identity = (11, 12, os.makedev(13, 14))
        event = gamepad.EventNode(Path("/dev/input/event9"), Path("/sys/event9/dev"), identity)
        access = object.__new__(gamepad.OwnedGamepadAccess)
        access._descriptor = None
        access._event_acl = None
        access._event = None
        access._baseline = {(1, 2, 3)}
        access._monotonic = mock.Mock(side_effect=[0.0, 0.0])
        access._sleeper = mock.Mock()
        access._runner = mock.Mock()
        access._event_nodes = mock.Mock(return_value=[event])
        lease = _acl_lease(90, identity, b"acl")
        opened = _char_stat(identity)
        with mock.patch.object(gamepad, "_char_identity", return_value=identity), \
                mock.patch.object(gamepad, "_prepare_acl_lease", return_value=lease), \
                mock.patch.object(gamepad, "_grant_acl") as grant, \
                mock.patch.object(gamepad.os, "open", return_value=91) as open_node, \
                mock.patch.object(gamepad.os, "fstat", return_value=opened), \
                mock.patch.object(gamepad.os, "read", side_effect=BlockingIOError):
            access.arm()
        self.assertEqual(91, access._descriptor)
        grant.assert_called_once_with(lease, "r--", access._runner)
        flags = open_node.call_args.args[1]
        self.assertEqual(os.O_RDONLY, flags & os.O_ACCMODE)
        self.assertTrue(flags & os.O_NONBLOCK)

    def test_arm_open_failure_restores_event_acl_using_preassigned_identity(self) -> None:
        identity = (11, 12, os.makedev(13, 14))
        event = gamepad.EventNode(Path("/dev/input/event9"), Path("/sys/event9/dev"), identity)
        access = object.__new__(gamepad.OwnedGamepadAccess)
        access._descriptor = None
        access._event_acl = None
        access._event = None
        access._uhid_acl = None
        access._baseline = set()
        access._monotonic = mock.Mock(side_effect=[0.0, 0.0])
        access._sleeper = mock.Mock()
        access._runner = mock.Mock()
        access._event_nodes = mock.Mock(return_value=[event])
        lease = _acl_lease(90, identity, b"event-acl")
        with mock.patch.object(gamepad, "_char_identity", return_value=identity), \
                mock.patch.object(gamepad, "_prepare_acl_lease", return_value=lease), \
                mock.patch.object(gamepad, "_grant_acl"), \
                mock.patch.object(gamepad.os, "open", side_effect=OSError("open failed")), \
                mock.patch.object(gamepad, "_restore_acl") as restore, \
                mock.patch.object(gamepad.os, "close"):
            with self.assertRaises(OSError):
                access.arm()
        restore.assert_called_once_with(lease, access._runner)

    def test_arm_malformed_drain_restores_event_acl_using_preassigned_identity(self) -> None:
        identity = (11, 12, os.makedev(13, 14))
        event = gamepad.EventNode(Path("/dev/input/event9"), Path("/sys/event9/dev"), identity)
        access = object.__new__(gamepad.OwnedGamepadAccess)
        access._descriptor = None
        access._event_acl = None
        access._event = None
        access._uhid_acl = None
        access._baseline = set()
        access._monotonic = mock.Mock(side_effect=[0.0, 0.0])
        access._sleeper = mock.Mock()
        access._runner = mock.Mock()
        access._event_nodes = mock.Mock(return_value=[event])
        lease = _acl_lease(90, identity, b"event-acl")
        opened = _char_stat(identity)
        with mock.patch.object(gamepad, "_char_identity", return_value=identity), \
                mock.patch.object(gamepad, "_prepare_acl_lease", return_value=lease), \
                mock.patch.object(gamepad, "_grant_acl"), \
                mock.patch.object(gamepad.os, "open", return_value=91), \
                mock.patch.object(gamepad.os, "fstat", return_value=opened), \
                mock.patch.object(gamepad.os, "read", return_value=b"malformed"), \
                mock.patch.object(gamepad.os, "close"), \
                mock.patch.object(gamepad, "_restore_acl") as restore:
            with self.assertRaises(gamepad.GamepadHostFailure):
                access.arm()
        restore.assert_called_once_with(lease, access._runner)

    def test_effect_requires_btn_south_down_and_up_each_committed_by_syn(self) -> None:
        with mock.patch.object(gamepad, "require_owned_runner"):
            access = gamepad.OwnedGamepadAccess({})
        read_descriptor, write_descriptor = os.pipe()
        access._descriptor = read_descriptor
        try:
            events = (
                (gamepad.EV_KEY, gamepad.BTN_SOUTH, 1),
                (gamepad.EV_SYN, gamepad.SYN_REPORT, 0),
                (gamepad.EV_KEY, gamepad.BTN_SOUTH, 0),
                (gamepad.EV_SYN, gamepad.SYN_REPORT, 0),
            )
            os.write(
                write_descriptor,
                b"".join(gamepad.EVENT_STRUCT.pack(0, 0, kind, code, value)
                         for kind, code, value in events),
            )
            access.wait_effect(timeout_seconds=1)
        finally:
            os.close(write_descriptor)
            os.close(read_descriptor)
            access._descriptor = None

    def test_delayed_prepare_b_cannot_satisfy_and_post_arm_a_is_required(self) -> None:
        with mock.patch.object(gamepad, "require_owned_runner"):
            access = gamepad.OwnedGamepadAccess({})
        read_descriptor, write_descriptor = os.pipe()
        access._descriptor = read_descriptor
        try:
            # Sunshine's uinput backend emits a full button-state report. A
            # delayed B prepare includes idle BTN_SOUTH=0, B itself, and SYN.
            prepare_b = (
                (gamepad.EV_KEY, gamepad.BTN_SOUTH, 0),
                (gamepad.EV_KEY, 305, 1),
                (gamepad.EV_SYN, gamepad.SYN_REPORT, 0),
                (gamepad.EV_KEY, gamepad.BTN_SOUTH, 0),
                (gamepad.EV_KEY, 305, 0),
                (gamepad.EV_SYN, gamepad.SYN_REPORT, 0),
            )
            witness_a = (
                (gamepad.EV_KEY, gamepad.BTN_SOUTH, 1),
                (gamepad.EV_SYN, gamepad.SYN_REPORT, 0),
                (gamepad.EV_KEY, gamepad.BTN_SOUTH, 0),
                (gamepad.EV_SYN, gamepad.SYN_REPORT, 0),
            )
            os.write(
                write_descriptor,
                b"".join(
                    gamepad.EVENT_STRUCT.pack(0, 0, kind, code, value)
                    for kind, code, value in prepare_b + witness_a
                ),
            )
            access.wait_effect(timeout_seconds=1)
        finally:
            os.close(write_descriptor)
            os.close(read_descriptor)
            access._descriptor = None

    def test_delayed_prepare_b_alone_never_satisfies_btn_south_witness(self) -> None:
        with mock.patch.object(gamepad, "require_owned_runner"):
            access = gamepad.OwnedGamepadAccess({})
        read_descriptor, write_descriptor = os.pipe()
        access._descriptor = read_descriptor
        try:
            events = (
                (gamepad.EV_KEY, gamepad.BTN_SOUTH, 0),
                (gamepad.EV_KEY, 305, 1),
                (gamepad.EV_SYN, gamepad.SYN_REPORT, 0),
                (gamepad.EV_KEY, gamepad.BTN_SOUTH, 0),
                (gamepad.EV_KEY, 305, 0),
                (gamepad.EV_SYN, gamepad.SYN_REPORT, 0),
            )
            os.write(
                write_descriptor,
                b"".join(
                    gamepad.EVENT_STRUCT.pack(0, 0, kind, code, value)
                    for kind, code, value in events
                ),
            )
            with self.assertRaises(gamepad.GamepadHostFailure):
                access.wait_effect(timeout_seconds=0.05)
        finally:
            os.close(write_descriptor)
            os.close(read_descriptor)
            access._descriptor = None

    def test_arm_reports_closed_discovery_timeout_before_any_device_open(self) -> None:
        with mock.patch.object(gamepad, "require_owned_runner"):
            access = gamepad.OwnedGamepadAccess({})
        access._monotonic = mock.Mock(side_effect=[0.0, 0.0, 0.06])
        access._sleeper = mock.Mock()
        access._event_nodes = mock.Mock(return_value=[])
        with self.assertRaisesRegex(
            gamepad.GamepadHostFailure, "gamepadDiscoveryTimeout"
        ):
            access.arm(timeout_seconds=0.05)
        access._event_nodes.assert_called_once_with(require_match=True)
        self.assertIsNone(access._descriptor)

    def test_effect_rejects_button_transition_without_syn_commit(self) -> None:
        with mock.patch.object(gamepad, "require_owned_runner"):
            access = gamepad.OwnedGamepadAccess({})
        read_descriptor, write_descriptor = os.pipe()
        access._descriptor = read_descriptor
        try:
            os.write(
                write_descriptor,
                gamepad.EVENT_STRUCT.pack(0, 0, gamepad.EV_KEY, gamepad.BTN_SOUTH, 1)
                + gamepad.EVENT_STRUCT.pack(0, 0, gamepad.EV_KEY, gamepad.BTN_SOUTH, 0),
            )
            with self.assertRaises(gamepad.GamepadHostFailure):
                access.wait_effect(timeout_seconds=0.05)
        finally:
            os.close(write_descriptor)
            os.close(read_descriptor)
            access._descriptor = None

    def test_effect_rejects_syn_dropped_before_apparently_valid_release(self) -> None:
        with mock.patch.object(gamepad, "require_owned_runner"):
            access = gamepad.OwnedGamepadAccess({})
        read_descriptor, write_descriptor = os.pipe()
        access._descriptor = read_descriptor
        try:
            events = (
                (gamepad.EV_KEY, gamepad.BTN_SOUTH, 1),
                (gamepad.EV_SYN, gamepad.SYN_REPORT, 0),
                (gamepad.EV_SYN, gamepad.SYN_DROPPED, 0),
                (gamepad.EV_KEY, gamepad.BTN_SOUTH, 0),
                (gamepad.EV_SYN, gamepad.SYN_REPORT, 0),
            )
            os.write(
                write_descriptor,
                b"".join(gamepad.EVENT_STRUCT.pack(0, 0, kind, code, value)
                         for kind, code, value in events),
            )
            with self.assertRaises(gamepad.GamepadHostFailure):
                access.wait_effect(timeout_seconds=1)
        finally:
            os.close(write_descriptor)
            os.close(read_descriptor)
            access._descriptor = None

    def test_cleanup_restores_both_descriptor_anchored_private_acls(self) -> None:
        event_identity = (20, 21, os.makedev(22, 23))
        uhid_identity = (30, 31, os.makedev(10, 239))
        event = gamepad.EventNode(
            Path("/dev/input/event7"), Path("/sys/class/input/event7/dev"), event_identity
        )
        event_lease = _acl_lease(90, event_identity, b"event-acl")
        uhid_lease = _acl_lease(91, uhid_identity, b"uhid-acl")
        with mock.patch.object(gamepad, "require_owned_runner"):
            access = gamepad.OwnedGamepadAccess({})
        access._event = event
        access._event_acl = event_lease
        access._uhid_identity = uhid_identity
        access._uhid_acl = uhid_lease
        with mock.patch.object(gamepad, "_restore_acl") as restore, \
                mock.patch.object(gamepad.os, "close") as close_descriptor:
            access.close()
        self.assertEqual(
            [mock.call(event_lease, access._runner), mock.call(uhid_lease, access._runner)],
            restore.call_args_list,
        )
        self.assertEqual(
            [mock.call(event_lease.descriptor), mock.call(uhid_lease.descriptor)],
            close_descriptor.call_args_list,
        )

    def test_cleanup_uses_original_descriptor_after_device_path_identity_changes(self) -> None:
        identity = (20, 21, os.makedev(22, 23))
        lease = _acl_lease(90, identity, b"event-acl")
        with mock.patch.object(gamepad, "require_owned_runner"):
            access = gamepad.OwnedGamepadAccess({})
        access._event = gamepad.EventNode(
            Path("/dev/input/event7"), Path("/sys/class/input/event7/dev"), identity
        )
        access._event_acl = lease
        with mock.patch.object(gamepad, "_char_identity") as path_identity, \
                mock.patch.object(gamepad, "_restore_acl") as restore, \
                mock.patch.object(gamepad.os, "close"):
            access.disarm()
        path_identity.assert_not_called()
        restore.assert_called_once_with(lease, access._runner)


if __name__ == "__main__":
    unittest.main()
