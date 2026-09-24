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
from .component_isolated_capture import AuthorityBoundIsolatedCapture
from .component_snapshot_provider import (
    ComponentVolumeSource,
    ManagedComponentSnapshotProvider,
)


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

    def __init__(
        self,
        endpoint,
        authority,
        *,
        peer_uid=None,
        effect_seconds=2.0,
        capture_engine=None,
    ):
        if (
            type(authority) is not DurableComponentInstallationAuthority
            or type(effect_seconds) not in (int, float)
            or type(effect_seconds) is bool
            or not math.isfinite(effect_seconds)
            or not 0.01 <= effect_seconds <= 10
        ):
            raise ComponentDockerAdapterError()
        try:
            self._http = VerifiedEngineHttp(endpoint, peer_uid=peer_uid)
        except Exception:
            raise ComponentDockerAdapterError() from None
        self._endpoint = endpoint
        self._authority = authority
        self._peer_uid = peer_uid
        self._effect_seconds = effect_seconds
        try:
            self._isolated_capture = (
                None
                if capture_engine is None
                else AuthorityBoundIsolatedCapture(capture_engine)
            )
        except Exception:
            raise ComponentDockerAdapterError() from None
        self._receipts = None
        self._sources = None
        self._pause_attempted = set()
        self._unpause_attempted = set()
        self._paused_owned = set()

    def provider(self, deadline):
        """Construct the production boundary only with an isolated engine."""
        if self._isolated_capture is None:
            raise ComponentDockerAdapterError()
        try:
            return ManagedComponentSnapshotProvider(
                self.sources(deadline),
                self,
                self._authority,
                isolated_capture=self._isolated_capture,
            )
        except ComponentDockerAdapterError:
            raise
        except Exception:
            raise ComponentDockerAdapterError() from None

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

    @staticmethod
    def _mounts(observed):
        try:
            result = {
                (item["Name"], item["Destination"]): item
                for item in observed["Mounts"]
            }
            if len(result) != len(observed["Mounts"]):
                raise ValueError()
            return result
        except (KeyError, TypeError, ValueError):
            raise ComponentDockerAdapterError() from None

    @staticmethod
    def _source(receipt, volume, mount):
        try:
            if mount is None or mount.get("RW") is not True:
                raise ValueError()
            path = _path(mount.get("Source"))
            info = path.lstat()
            if not stat.S_ISDIR(info.st_mode):
                raise ValueError()
            return ComponentVolumeSource(
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
        except ComponentDockerAdapterError:
            raise
        except Exception:
            raise ComponentDockerAdapterError() from None

    def _authority_current(self, deadline):
        if self._sources is None:
            return False
        try:
            _remaining(deadline)
            for source in self._sources:
                info = source.path.lstat()
                if (
                    not stat.S_ISDIR(info.st_mode)
                    or (info.st_dev, info.st_ino)
                    != (source.device, source.inode)
                ):
                    return False
            return self._authority.revalidate(self._sources, deadline) is True
        except Exception:
            return False

    def _receipt(self, container_id):
        if type(container_id) is not str or self._receipts is None:
            raise ComponentDockerAdapterError()
        selected = tuple(
            item for item in self._receipts if item.container_id == container_id
        )
        if len(selected) != 1:
            raise ComponentDockerAdapterError()
        return selected[0]

    def _live_state(self, receipt, deadline):
        observed = self._container(receipt, deadline)
        state = observed.get("State")
        if _state(state, False):
            paused = False
        elif _state(state, True):
            paused = True
        else:
            raise ComponentDockerAdapterError()
        mounts = self._mounts(observed)
        expected = {
            (source.service_id, source.volume_id): source
            for source in self._sources
        }
        identities = set()
        for volume in receipt.volumes:
            _remaining(deadline)
            self._volume(volume, deadline)
            resource = volume.intent.binding.resource
            current = self._source(
                receipt,
                volume,
                mounts.get((resource.name, volume.target)),
            )
            source = expected.get((receipt.service_id, volume.volume_id))
            if current != source or (current.device, current.inode) in identities:
                raise ComponentDockerAdapterError()
            identities.add((current.device, current.inode))
        return paused

    def _preflight(self, receipt, paused, deadline):
        if not self._authority_current(deadline):
            raise ComponentDockerAdapterError()
        if self._live_state(receipt, deadline) is not paused:
            raise ComponentDockerAdapterError()
        if not self._authority_current(deadline):
            raise ComponentDockerAdapterError()

    def _dispatch(self, receipt, action, deadline):
        dispatched = {"value": False}
        attempted = (
            self._pause_attempted
            if action == "pause"
            else self._unpause_attempted
        )

        def gate():
            if not self._authority_current(deadline):
                return False
            attempted.add(receipt.container_id)
            dispatched["value"] = True
            return True

        remaining = _remaining(deadline)
        budget = min(float(self._effect_seconds), remaining / 2)
        if budget < 0.01:
            raise ComponentDockerAdapterError()
        try:
            self._http.exchange(
                EngineHttpRequest(
                    "POST",
                    f"/v1.47/containers/{receipt.container_id}/{action}",
                ),
                lambda status, headers, chunks: True,
                platform=receipt.installed.binding.platform,
                limits=EngineHttpLimits(budget, min(budget, 1.0), 1, 1),
                before_dispatch=gate,
            )
        except Exception:
            if not dispatched["value"]:
                raise ComponentDockerAdapterError() from None
        return dispatched["value"]

    def _load_sources(self, deadline, *, allow_paused):
        try:
            receipts = self._authority.snapshot()
            selected = []
            paused = []
            paths = set()
            identities = set()
            for receipt in receipts:
                _remaining(deadline)
                observed = self._container(receipt, deadline)
                state = observed.get("State")
                if _state(state, False):
                    is_paused = False
                elif allow_paused and _state(state, True):
                    is_paused = True
                else:
                    raise ComponentDockerAdapterError()
                if is_paused:
                    paused.append(receipt.container_id)
                mounts = self._mounts(observed)
                for volume in receipt.volumes:
                    _remaining(deadline)
                    self._volume(volume, deadline)
                    resource = volume.intent.binding.resource
                    source = self._source(
                        receipt,
                        volume,
                        mounts.get((resource.name, volume.target)),
                    )
                    identity = (source.device, source.inode)
                    if (
                        source.path in paths
                        or identity in identities
                    ):
                        raise ComponentDockerAdapterError()
                    paths.add(source.path)
                    identities.add(identity)
                    selected.append(source)
            result = tuple(
                sorted(selected, key=lambda item: (item.service_id, item.volume_id))
            )
            if self._authority.revalidate(result, deadline) is not True:
                raise ComponentDockerAdapterError()
            if self._sources is not None and result != self._sources:
                raise ComponentDockerAdapterError()
            self._receipts = receipts
            self._sources = result
            return result, tuple(sorted(paused))
        except ComponentDockerAdapterError:
            raise
        except Exception:
            raise ComponentDockerAdapterError() from None

    def sources(self, deadline):
        result, paused = self._load_sources(deadline, allow_paused=False)
        if paused:
            raise ComponentDockerAdapterError()
        return result

    def restore_sources(self, deadline):
        """Read exact running/paused sources for authenticated recovery."""
        return self._load_sources(deadline, allow_paused=True)

    def adopt_restore_pauses(self, container_ids, deadline):
        """Adopt only exact paused effects after a durable journal was verified."""
        try:
            if (
                type(container_ids) is not tuple
                or container_ids != tuple(sorted(set(container_ids)))
                or self._receipts is None
                or self._sources is None
            ):
                raise ComponentDockerAdapterError()
            known = {item.container_id for item in self._receipts}
            if not set(container_ids).issubset(known):
                raise ComponentDockerAdapterError()
            for container_id in container_ids:
                receipt = self._receipt(container_id)
                self._preflight(receipt, True, deadline)
            for container_id in container_ids:
                self._pause_attempted.add(container_id)
                self._paused_owned.add(container_id)
            return True
        except ComponentDockerAdapterError:
            raise
        except Exception:
            raise ComponentDockerAdapterError() from None

    def revalidate_restore_sources(self, sources, deadline):
        try:
            return (
                type(sources) is tuple
                and sources == self._sources
                and self._authority_current(deadline)
            )
        except Exception:
            return False

    def pause(self, container_id, deadline):
        try:
            receipt = self._receipt(container_id)
            if container_id in self._unpause_attempted:
                raise ComponentDockerAdapterError()
            if container_id in self._pause_attempted:
                if not self._authority_current(deadline):
                    raise ComponentDockerAdapterError()
                paused = self._live_state(receipt, deadline)
                if not self._authority_current(deadline) or paused is not True:
                    raise ComponentDockerAdapterError()
                self._paused_owned.add(container_id)
                return True
            self._preflight(receipt, False, deadline)
            if not self._dispatch(receipt, "pause", deadline):
                raise ComponentDockerAdapterError()
            if self._live_state(receipt, deadline) is not True:
                raise ComponentDockerAdapterError()
            self._paused_owned.add(container_id)
            if not self._authority_current(deadline):
                raise ComponentDockerAdapterError()
            return True
        except ComponentDockerAdapterError:
            raise
        except Exception:
            raise ComponentDockerAdapterError() from None

    def unpause(self, container_id, deadline):
        try:
            receipt = self._receipt(container_id)
            if container_id not in self._pause_attempted:
                raise ComponentDockerAdapterError()
            if not self._authority_current(deadline):
                raise ComponentDockerAdapterError()
            paused = self._live_state(receipt, deadline)
            if not self._authority_current(deadline):
                raise ComponentDockerAdapterError()
            if container_id in self._unpause_attempted:
                if paused is not False:
                    raise ComponentDockerAdapterError()
                self._paused_owned.discard(container_id)
                self._pause_attempted.discard(container_id)
                self._unpause_attempted.discard(container_id)
                return True
            if paused is False:
                if container_id not in self._paused_owned:
                    # A dispatched pause that was never observed may still land;
                    # do not clear its uncertain ownership while the daemon is
                    # merely reporting the original running state.
                    raise ComponentDockerAdapterError()
                self._paused_owned.discard(container_id)
                self._pause_attempted.discard(container_id)
                return True
            if container_id not in self._paused_owned:
                # The same process dispatched pause but did not yet observe it;
                # the fresh paused state makes that uncertain effect ours to undo.
                self._paused_owned.add(container_id)
            if not self._dispatch(receipt, "unpause", deadline):
                raise ComponentDockerAdapterError()
            if self._live_state(receipt, deadline) is not False:
                raise ComponentDockerAdapterError()
            if not self._authority_current(deadline):
                raise ComponentDockerAdapterError()
            self._paused_owned.discard(container_id)
            self._pause_attempted.discard(container_id)
            self._unpause_attempted.discard(container_id)
            return True
        except ComponentDockerAdapterError:
            raise
        except Exception:
            raise ComponentDockerAdapterError() from None
