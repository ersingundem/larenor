"""Fail-closed Docker Engine adapter for durable component backup receipts."""

import json
import math
from pathlib import Path
import stat
import time

from ..files import checked_path
from ..plugins.engine_http import (
    EngineHttpLimits,
    EngineHttpRequest,
    VerifiedEngineHttp,
)
from ..plugins.managed_container import managed_container_matches
from ..plugins.volume_transport import UnixVolumeReader, VolumeReadLimits
from .component_installation_authority import (
    DurableComponentInstallationAuthority,
)
from .component_snapshot_provider import ComponentVolumeSource


class ComponentDockerAdapterError(RuntimeError):
    """Static failure that never includes daemon data or host paths."""

    def __init__(self):
        super().__init__("component_engine_unavailable")


def _remaining(deadline):
    if (
        type(deadline) not in (int, float)
        or type(deadline) is bool
        or not math.isfinite(deadline)
    ):
        raise ComponentDockerAdapterError()
    value = deadline - time.monotonic()
    if value <= 0:
        raise ComponentDockerAdapterError()
    return value


def _path(value):
    try:
        if (
            type(value) is not str
            or not 1 <= len(value.encode("utf-8", "strict")) <= 4096
            or "\\" in value
            or any(ord(char) < 32 or ord(char) == 127 for char in value)
        ):
            raise ValueError()
        selected = Path(value)
        if selected.as_posix() != value:
            raise ValueError()
        return checked_path(selected)
    except Exception:
        raise ComponentDockerAdapterError() from None


def _state(value, paused):
    return (
        type(value) is dict
        and value.get("Status") == ("paused" if paused else "running")
        and value.get("Running") is True
        and value.get("Paused") is paused
        and value.get("Restarting") is False
        and value.get("Dead") is False
    )


class UnixDockerComponentSnapshotAdapter:
    """Join installed journals to exact live Docker and filesystem identities."""

    def __init__(self, endpoint, authority, *, peer_uid=None):
        if type(authority) is not DurableComponentInstallationAuthority:
            raise ComponentDockerAdapterError()
        try:
            self._http = VerifiedEngineHttp(endpoint, peer_uid=peer_uid)
        except Exception:
            raise ComponentDockerAdapterError() from None
        self._endpoint = endpoint
        self._authority = authority
        self._peer_uid = peer_uid
        self._receipts = None
        self._sources = None

    def _container(self, receipt, deadline):
        remaining = _remaining(deadline)

        def consume(status, _headers, chunks):
            if status != 200:
                raise ComponentDockerAdapterError()
            raw = b"".join(chunks)
            if len(raw) > 1024 * 1024:
                raise ComponentDockerAdapterError()
            try:
                value = json.loads(raw)
            except (UnicodeError, ValueError, TypeError):
                raise ComponentDockerAdapterError() from None
            if (
                value.get("Id") != receipt.container_id
                or not managed_container_matches(value, receipt.installed.binding)
            ):
                raise ComponentDockerAdapterError()
            return value

        return self._http.exchange(
            EngineHttpRequest(
                "GET", f"/v1.47/containers/{receipt.container_id}/json"
            ),
            consume,
            platform=receipt.installed.binding.platform,
            limits=EngineHttpLimits(
                min(10.0, remaining), min(2.0, remaining), 1024 * 1024, 4096
            ),
        )

    def _volume(self, receipt, deadline):
        remaining = _remaining(deadline)
        reader = UnixVolumeReader(
            self._endpoint,
            peer_uid=self._peer_uid,
            limits=VolumeReadLimits(
                min(10.0, remaining), min(2.0, remaining), 4096
            ),
        )
        return reader.inspect(receipt.intent.binding)

    def sources(self, deadline):
        try:
            receipts = self._authority.snapshot()
            selected = []
            paths = set()
            identities = set()
            for receipt in receipts:
                _remaining(deadline)
                observed = self._container(receipt, deadline)
                if not _state(observed.get("State"), False):
                    raise ComponentDockerAdapterError()
                mounts = {
                    (item["Name"], item["Destination"]): item
                    for item in observed["Mounts"]
                }
                if len(mounts) != len(observed["Mounts"]):
                    raise ComponentDockerAdapterError()
                for volume in receipt.volumes:
                    _remaining(deadline)
                    self._volume(volume, deadline)
                    resource = volume.intent.binding.resource
                    mount = mounts.get((resource.name, volume.target))
                    if mount is None or mount.get("RW") is not True:
                        raise ComponentDockerAdapterError()
                    path = _path(mount.get("Source"))
                    info = path.lstat()
                    identity = (info.st_dev, info.st_ino)
                    if (
                        not stat.S_ISDIR(info.st_mode)
                        or path in paths
                        or identity in identities
                    ):
                        raise ComponentDockerAdapterError()
                    paths.add(path)
                    identities.add(identity)
                    selected.append(
                        ComponentVolumeSource(
                            receipt.service_id,
                            receipt.container_id,
                            volume.volume_id,
                            path,
                            receipt.service_version,
                            receipt.config_schema_version,
                            receipt.data_schema_version,
                            volume.intent.receipt.revision,
                            info.st_dev,
                            info.st_ino,
                        )
                    )
            result = tuple(
                sorted(selected, key=lambda item: (item.service_id, item.volume_id))
            )
            if self._authority.revalidate(result, deadline) is not True:
                raise ComponentDockerAdapterError()
            if self._sources is not None and result != self._sources:
                raise ComponentDockerAdapterError()
            self._receipts = receipts
            self._sources = result
            return result
        except ComponentDockerAdapterError:
            raise
        except Exception:
            raise ComponentDockerAdapterError() from None
