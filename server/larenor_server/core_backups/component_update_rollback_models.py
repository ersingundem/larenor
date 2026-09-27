"""Dependency-free authenticated metadata for update rollback archives."""

from dataclasses import dataclass
import re

from .models import MAX_COMPONENT_VOLUME_BYTES


_DIGEST = re.compile(r"[0-9a-f]{64}\Z")
_VOLUME_ID = re.compile(r"[a-z][a-z0-9-]{0,31}\Z")


class ComponentUpdateRollbackError(RuntimeError):
    def __init__(self):
        super().__init__("component_update_rollback_unavailable")


@dataclass(frozen=True, repr=False)
class ComponentUpdateRollbackReceipt:
    volume_id: str
    byte_length: int
    sha256: str

    def __post_init__(self):
        if (
            type(self.volume_id) is not str
            or _VOLUME_ID.fullmatch(self.volume_id) is None
            or type(self.byte_length) is not int
            or not 1 <= self.byte_length <= MAX_COMPONENT_VOLUME_BYTES
            or type(self.sha256) is not str
            or _DIGEST.fullmatch(self.sha256) is None
        ):
            raise ComponentUpdateRollbackError()

    def __repr__(self):
        return "ComponentUpdateRollbackReceipt(<private>)"
