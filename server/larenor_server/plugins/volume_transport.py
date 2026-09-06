"""Compiling, fail-closed transport boundary for runtime RED tests."""
from dataclasses import dataclass


class VolumeTransportError(Exception):
    def __init__(self, code='volume_engine_unavailable'):
        self.code = 'volume_engine_unavailable'
        super().__init__(self.code)


@dataclass(frozen=True)
class VolumeReadLimits:
    total_seconds: float = 10.0
    idle_seconds: float = 2.0
    max_chunks: int = 4096


class UnixVolumeReader:
    def __init__(self, endpoint, *, limits=None, peer_uid=None):
        pass

    def inspect(self, binding, *, cancelled=None):
        raise VolumeTransportError()
