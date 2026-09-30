"""Process entry point for the isolated Zigbee2MQTT broker worker."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import json
import os
from pathlib import Path
import signal
import stat
import threading

from .managed_ota_transport import Zigbee2MqttManagedOtaTransport
from .mqtt_transport import MqttBrokerConfig, MqttObservationError, MqttRetainedObserver
from .worker_ipc import MeshWorkerError, Zigbee2MqttWorkerServer


@dataclass(frozen=True)
class MeshWorkerConfig:
    socket_path: Path
    core_uid: int
    socket_gid: int
    broker: MqttBrokerConfig


def _private_bytes(path: Path, maximum: int) -> bytes:
    if not path.is_absolute() or ".." in path.parts:
        raise MeshWorkerError("invalid_request")
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
        try:
            before = os.fstat(descriptor)
            if (
                not stat.S_ISREG(before.st_mode)
                or before.st_nlink != 1
                or before.st_uid != os.geteuid()
                or stat.S_IMODE(before.st_mode) != 0o600
                or not 1 <= before.st_size <= maximum
            ):
                raise MeshWorkerError("invalid_request")
            raw = os.read(descriptor, maximum + 1)
            after = os.fstat(descriptor)
        finally:
            os.close(descriptor)
        current = os.stat(path, follow_symlinks=False)
        identity = lambda value: (
            value.st_dev,
            value.st_ino,
            value.st_uid,
            value.st_gid,
            stat.S_IFMT(value.st_mode),
            stat.S_IMODE(value.st_mode),
            value.st_nlink,
            value.st_size,
            value.st_mtime_ns,
            value.st_ctime_ns,
        )
        if (
            len(raw) != before.st_size
            or identity(before) != identity(after)
            or identity(after) != identity(current)
        ):
            raise MeshWorkerError("invalid_request")
        return raw
    except MeshWorkerError:
        raise
    except OSError:
        raise MeshWorkerError("invalid_request") from None


def _private_text(path: Path, maximum: int) -> str:
    raw = _private_bytes(path, maximum)
    if raw.endswith(b"\n") and raw.count(b"\n") > 1:
        raise MeshWorkerError("invalid_request")
    try:
        value = raw.decode("utf-8").removesuffix("\n")
    except UnicodeError:
        raise MeshWorkerError("invalid_request") from None
    if not value:
        raise MeshWorkerError("invalid_request")
    return value


def _pairs(values):
    result = {}
    for key, value in values:
        if key in result:
            raise ValueError
        result[key] = value
    return result


def config_from_file(path, socket_path, *, core_uid, socket_gid) -> MeshWorkerConfig:
    try:
        socket_path = Path(socket_path)
        value = json.loads(
            _private_bytes(Path(path), 64 * 1024),
            object_pairs_hook=_pairs,
            parse_constant=lambda _item: (_ for _ in ()).throw(ValueError()),
        )
        if (
            not isinstance(value, dict)
            or set(value) != {"schemaVersion", "broker"}
            or type(value["schemaVersion"]) is not int
            or value["schemaVersion"] != 1
            or not isinstance(value["broker"], dict)
            or set(value["broker"])
            != {
                "url",
                "baseTopic",
                "allowedAddresses",
                "usernameFile",
                "passwordFile",
            }
            or not isinstance(value["broker"]["allowedAddresses"], list)
            or any(
                not isinstance(item, str)
                for item in value["broker"]["allowedAddresses"]
            )
            or (value["broker"]["usernameFile"] is None)
            != (value["broker"]["passwordFile"] is None)
            or type(core_uid) is not int
            or type(socket_gid) is not int
            or not 0 <= core_uid < 2**31
            or not 0 <= socket_gid < 2**31
            or not socket_path.is_absolute()
            or ".." in socket_path.parts
            or len(os.fsencode(socket_path)) > 100
        ):
            raise ValueError
        username = password = None
        if value["broker"]["usernameFile"] is not None:
            if not isinstance(
                value["broker"]["usernameFile"], str
            ) or not isinstance(value["broker"]["passwordFile"], str):
                raise ValueError
            username = _private_text(Path(value["broker"]["usernameFile"]), 2_048)
            password = _private_text(Path(value["broker"]["passwordFile"]), 2_048)
        broker = MqttBrokerConfig.parse(
            value["broker"]["url"],
            base_topic=value["broker"]["baseTopic"],
            allowed_addresses=tuple(value["broker"]["allowedAddresses"]),
            username=username,
            password=password,
        )
        return MeshWorkerConfig(socket_path, core_uid, socket_gid, broker)
    except (
        ValueError,
        TypeError,
        KeyError,
        UnicodeError,
        json.JSONDecodeError,
        MqttObservationError,
    ):
        raise MeshWorkerError("invalid_request") from None


def config_from_environment(environ=None) -> MeshWorkerConfig:
    """Compatibility parser for explicitly supervised test deployments."""
    values = os.environ if environ is None else environ
    try:
        socket_path = Path(values["LARENOR_MESH_WORKER_SOCKET"])
        core_uid = int(values.get("LARENOR_MESH_CORE_UID", str(os.geteuid())))
        socket_gid = int(values.get("LARENOR_MESH_SOCKET_GID", str(os.getegid())))
        addresses = tuple(
            item.strip()
            for item in values["LARENOR_MESH_MQTT_ALLOWED_ADDRESSES"].split(",")
        )
        username_file = values.get("LARENOR_MESH_MQTT_USERNAME_FILE")
        password_file = values.get("LARENOR_MESH_MQTT_PASSWORD_FILE")
        if (
            not socket_path.is_absolute()
            or ".." in socket_path.parts
            or not 0 <= core_uid < 2**31
            or not 0 <= socket_gid < 2**31
            or bool(username_file) != bool(password_file)
        ):
            raise ValueError
        username = password = None
        if username_file:
            username = _private_text(Path(username_file), 2_048)
            password = _private_text(Path(password_file), 2_048)
        broker = MqttBrokerConfig.parse(
            values["LARENOR_MESH_MQTT_URL"],
            base_topic=values.get("LARENOR_MESH_MQTT_BASE_TOPIC", "zigbee2mqtt"),
            allowed_addresses=addresses,
            username=username,
            password=password,
        )
        return MeshWorkerConfig(socket_path, core_uid, socket_gid, broker)
    except (KeyError, ValueError, TypeError, MqttObservationError, MeshWorkerError):
        raise MeshWorkerError("invalid_request") from None


def build_server(config: MeshWorkerConfig):
    if not isinstance(config, MeshWorkerConfig):
        raise MeshWorkerError("invalid_request")
    return Zigbee2MqttWorkerServer(
        config.socket_path,
        MqttRetainedObserver(config.broker),
        managed_ota=Zigbee2MqttManagedOtaTransport(config.broker),
        owner_uid=os.geteuid(),
        peer_uid=config.core_uid,
        socket_gid=config.socket_gid,
    )


class _Parser(argparse.ArgumentParser):
    def error(self, _message):
        raise MeshWorkerError("invalid_request")


def main(argv=None):
    parser = _Parser(description=__doc__)
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--socket", required=True, type=Path)
    parser.add_argument("--core-uid", required=True, type=int)
    parser.add_argument("--socket-gid", required=True, type=int)
    parser.add_argument("--check-config", action="store_true")
    try:
        args = parser.parse_args(argv)
        server = build_server(
            config_from_file(
                args.config,
                args.socket,
                core_uid=args.core_uid,
                socket_gid=args.socket_gid,
            )
        )
        if args.check_config:
            return 0
        stopped = threading.Event()
        previous = {}
        for number in (signal.SIGTERM, signal.SIGINT):
            previous[number] = signal.signal(number, lambda *_args: stopped.set())
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            while not stopped.wait(0.2):
                if not thread.is_alive():
                    raise MeshWorkerError()
        finally:
            server.close()
            thread.join(timeout=3)
            for number, handler in previous.items():
                signal.signal(number, handler)
        return 0
    except MeshWorkerError as error:
        print(error.code, file=__import__("sys").stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
