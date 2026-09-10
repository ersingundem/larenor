from typing import Literal

from pydantic import Field, model_validator

from ..home_resources.models import FrozenModel, HomeScope, Identity, Revision


Command = Literal["start", "shutdown", "stop", "reboot", "reset", "suspend", "resume"]


class DiscoveredTarget(FrozenModel):
    schemaVersion: Literal[1] = 1
    targetId: Identity
    installationId: Identity
    node: str = Field(
        min_length=1,
        max_length=64,
        pattern=r"^[A-Za-z0-9](?:[A-Za-z0-9._-]{0,62}[A-Za-z0-9])?$",
    )
    guestKind: Literal["qemu", "lxc"]
    guestId: int = Field(ge=1, le=999_999_999)
    currentState: Literal["running", "stopped", "suspended", "unavailable"]
    statusRevision: Revision
    allowedCommands: list[Command] = Field(max_length=7)
    capabilityReady: bool

    @model_validator(mode="after")
    def exact_capability(self):
        policy = {
            "running": ["shutdown", "stop", "reboot", "reset", "suspend"],
            "stopped": ["start"],
            "suspended": ["resume"],
            "unavailable": [],
        }
        expected = policy[self.currentState] if self.capabilityReady else []
        if self.allowedCommands != expected:
            raise ValueError("invalid_capability")
        return self


class TargetDiscoveryPage(FrozenModel):
    schemaVersion: Literal[1] = 1
    scope: HomeScope
    resourceId: Identity
    userRevision: Revision
    resourceRevision: Revision
    aclRevision: Revision
    bindingId: Identity
    bindingRevision: Revision
    serviceId: Identity
    serviceRevision: Revision
    snapshot: str = Field(min_length=64, max_length=64, pattern=r"^[0-9a-f]{64}$")
    targets: list[DiscoveredTarget] = Field(max_length=100)
    nextAfter: Identity | None

    @model_validator(mode="after")
    def ordered_page(self):
        identities = [target.targetId for target in self.targets]
        if identities != sorted(identities) or len(identities) != len(set(identities)):
            raise ValueError("invalid_page")
        if self.nextAfter is not None and (
            not identities or self.nextAfter != identities[-1]
        ):
            raise ValueError("invalid_page")
        return self
