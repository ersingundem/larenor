"""Process entry point for the read-only Zigbee2MQTT observation worker."""

from __future__ import annotations

from dataclasses import dataclass
import os
from pathlib import Path
import stat

from .mqtt_transport import MqttBrokerConfig, MqttObservationError, MqttRetainedObserver
from .managed_ota_transport import Zigbee2MqttManagedOtaTransport
from .worker_ipc import MeshWorkerError, Zigbee2MqttWorkerServer


@dataclass(frozen=True)
class MeshWorkerConfig:
    socket_path: Path
    core_uid: int
    broker: MqttBrokerConfig


def _private_text(path: Path, maximum: int) -> str:
    if not path.is_absolute() or ".." in path.parts:
        raise MeshWorkerError("invalid_request")
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
        try:
            info = os.fstat(descriptor)
            if (
                not stat.S_ISREG(info.st_mode)
                or info.st_uid != os.geteuid()
                or info.st_mode & 0o077
                or not 1 <= info.st_size <= maximum
            ):
                raise MeshWorkerError("invalid_request")
            raw = os.read(descriptor, maximum + 1)
        finally:
            os.close(descriptor)
    except MeshWorkerError:
        raise
    except OSError:
        raise MeshWorkerError("invalid_request") from None
    if len(raw) > maximum or raw.endswith(b"\n") and raw.count(b"\n") > 1:
        raise MeshWorkerError("invalid_request")
    try:
        value = raw.decode("utf-8").removesuffix("\n")
    except UnicodeError:
        raise MeshWorkerError("invalid_request") from None
    if not value:
        raise MeshWorkerError("invalid_request")
    return value


def config_from_environment(environ=None) -> MeshWorkerConfig:
    values = os.environ if environ is None else environ
    try:
        socket_path = Path(values["LARENOR_MESH_WORKER_SOCKET"])
        core_uid = int(values.get("LARENOR_MESH_CORE_UID", "0"))
        addresses = tuple(
            item.strip()
            for item in values["LARENOR_MESH_MQTT_ALLOWED_ADDRESSES"].split(",")
        )
        username_file = values.get("LARENOR_MESH_MQTT_USERNAME_FILE")
        password_file = values.get("LARENOR_MESH_MQTT_PASSWORD_FILE")
        if (
            not socket_path.is_absolute()
            or ".." in socket_path.parts
            or type(core_uid) is not int
            or not 0 <= core_uid < 2**31
            or core_uid != os.geteuid()
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
        return MeshWorkerConfig(socket_path, core_uid, broker)
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
    )


def main():
    server = build_server(config_from_environment())
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.close()


if __name__ == "__main__":
    main()
