"""Strict public contracts for Music Assistant party DJ rooms."""

import re
from typing import Literal

from pydantic import Field, field_validator, model_validator

from ..admin.models import ObjectId, Revision
from ..models import StrictModel
from ..plugins.music_playback_models import PlayerCapability


def _exact_version(value):
    if type(value) is not int:
        raise ValueError("invalid_schema")
    return value


def _safe_media_uri(value: str) -> str:
    match = (re.fullmatch(r"([a-z][a-z0-9_]{0,63})://[^\s]+", value)
             if type(value) is str and 0 < len(value) <= 2048 else None)
    if (match is None or match.group(1) in {
            "content", "data", "file", "ftp", "http", "https", "javascript"
            } or any(char in value for char in ("?", "#", "@"))
            or any(ord(char) < 33 or ord(char) == 127 for char in value)):
        raise ValueError("invalid_party_dj_media")
    return value


def _safe_text(value: str) -> str:
    if value != value.strip() or any(
            ord(char) < 32 or ord(char) == 127 for char in value):
        raise ValueError("invalid_party_dj_text")
    return value


class Versioned(StrictModel):
    schemaVersion: Literal[1] = 1

    _version = field_validator("schemaVersion", mode="before")(_exact_version)


class MusicTarget(StrictModel):
    targetId: str = Field(min_length=1, max_length=128,
                          pattern=r"^[A-Za-z0-9][A-Za-z0-9_.:\-]{0,127}$")
    expectedProvider: str = Field(min_length=1, max_length=128,
                                  pattern=r"^[A-Za-z0-9][A-Za-z0-9_.:\-]{0,127}$")
    expectedTargetKind: Literal[
        "homepod", "airplay", "airplay_group", "cast", "cast_group",
        "group", "other"]
    expectedQueueId: str | None = Field(
        default=None, max_length=128,
        pattern=r"^[A-Za-z0-9][A-Za-z0-9_.:\-]{0,127}$")
    expectedGroupMembers: list[str] = Field(max_length=64)

    @model_validator(mode="after")
    def coherent(self):
        if (len(set(self.expectedGroupMembers)) != len(self.expectedGroupMembers)
                or any(re.fullmatch(
                    r"[A-Za-z0-9][A-Za-z0-9_.:\-]{0,127}", value) is None
                       for value in self.expectedGroupMembers)):
            raise ValueError("invalid_party_dj_target")
        return self


class CreatePartyDjRoomRequest(Versioned, MusicTarget):
    requestId: ObjectId
    installationId: ObjectId
    expectedInstallationRevision: Revision
    expectedCoreRevision: Revision
    expectedManagerRevision: Revision
    expectedPlayerRevision: Revision
    expiresAt: int = Field(ge=1, le=253402300799)
    proposalLimitPerUser: int = Field(default=3, ge=1, le=3)
    skipQuorumPercent: int = Field(default=60, ge=50, le=100)


class JoinPartyDjRoomRequest(Versioned):
    requestId: ObjectId
    inviteCode: ObjectId = Field(repr=False)
    expectedRoomRevision: Revision


class HeartbeatPartyDjRequest(Versioned):
    requestId: ObjectId
    expectedRoomRevision: Revision
    expectedParticipantRevision: Revision


class LeavePartyDjRequest(HeartbeatPartyDjRequest):
    pass


class ProposePartyDjTrackRequest(Versioned):
    requestId: ObjectId
    catalogRequestId: ObjectId
    expectedRoomRevision: Revision
    catalogQuery: str = Field(min_length=1, max_length=160)
    mediaUri: str = Field(min_length=1, max_length=2048)
    name: str = Field(min_length=1, max_length=512)
    providerSetupId: ObjectId
    expectedProviderRevision: Revision
    providerDomain: Literal["spotify", "apple_music", "ytmusic"]
    providerInstanceId: str = Field(
        min_length=1, max_length=128,
        pattern=r"^[A-Za-z0-9][A-Za-z0-9_.:\-]{0,127}$")

    _uri = field_validator("mediaUri")(_safe_media_uri)
    _name = field_validator("name", "catalogQuery")(_safe_text)


class VotePartyDjProposalRequest(Versioned):
    requestId: ObjectId
    expectedRoomRevision: Revision
    expectedProposalRevision: Revision
    vote: Literal["up", "remove"]


class DecidePartyDjProposalRequest(Versioned):
    requestId: ObjectId
    expectedRoomRevision: Revision
    expectedProposalRevision: Revision
    decision: Literal["approve", "reject"]
    expectedPlayerRevision: Revision | None = None

    @model_validator(mode="after")
    def coherent(self):
        if (self.decision == "approve") != (self.expectedPlayerRevision is not None):
            raise ValueError("invalid_party_dj_decision")
        return self


class VotePartyDjSkipRequest(Versioned):
    requestId: ObjectId
    expectedRoomRevision: Revision
    expectedParticipantRevision: Revision
    expectedPlayerRevision: Revision


class DismissPartyDjProposalRequest(Versioned):
    requestId: ObjectId
    expectedRoomRevision: Revision
    expectedProposalRevision: Revision


class DismissPartyDjSkipRequest(Versioned):
    requestId: ObjectId
    expectedRoomRevision: Revision
    expectedParticipantRevision: Revision


class PartyDjAuthority(Versioned):
    coreId: ObjectId
    homeId: ObjectId
    roomId: ObjectId
    installationId: ObjectId
    installationRevision: Revision
    coreRevision: Revision
    managerRevision: Revision
    playerRevision: Revision
    targetId: str = Field(min_length=1, max_length=128)
    provider: str = Field(min_length=1, max_length=128)
    targetKind: Literal[
        "homepod", "airplay", "airplay_group", "cast", "cast_group",
        "group", "other"]
    queueId: str | None = Field(default=None, max_length=128)
    groupMembers: list[str] = Field(max_length=64)


class PartyDjParticipant(Versioned):
    accountId: ObjectId
    revision: Revision
    isHost: bool
    connected: bool
    lastSeenAt: int = Field(ge=0, le=253402300799)
    ownedByCurrentSession: bool


class PartyDjProposal(Versioned):
    proposalId: ObjectId
    revision: Revision
    accountId: ObjectId
    mediaUri: str = Field(min_length=1, max_length=2048)
    name: str = Field(min_length=1, max_length=512)
    providerSetupId: ObjectId
    providerRevision: Revision
    providerDomain: Literal["spotify", "apple_music", "ytmusic"]
    providerInstanceId: str = Field(min_length=1, max_length=128)
    managerRevision: Revision
    status: Literal[
        "pending", "approving", "approved", "rejected", "needs_attention"]
    upVotes: int = Field(ge=0, le=16)
    submittedByCurrentUser: bool
    votedByCurrentUser: bool
    createdAt: int = Field(ge=0, le=253402300799)


class PartyDjRoom(Versioned):
    authority: PartyDjAuthority
    revision: Revision
    state: Literal["active", "closed"]
    hostAccountId: ObjectId
    expiresAt: int = Field(ge=1, le=253402300799)
    proposalLimitPerUser: int = Field(ge=1, le=3)
    skipQuorumPercent: int = Field(ge=50, le=100)
    skipVotes: int = Field(ge=0, le=16)
    skipVotesRequired: int = Field(ge=1, le=16)
    skipNeedsAttention: bool
    participants: list[PartyDjParticipant] = Field(min_length=1, max_length=16)
    proposals: list[PartyDjProposal] = Field(max_length=64)
    currentParticipantRevision: Revision

    @model_validator(mode="after")
    def coherent(self):
        hosts = [item for item in self.participants if item.isHost]
        if (len(hosts) != 1 or hosts[0].accountId != self.hostAccountId
                or len({item.accountId for item in self.participants})
                != len(self.participants)):
            raise ValueError("invalid_party_dj_room")
        return self


class CreatePartyDjRoomResponse(StrictModel):
    room: PartyDjRoom
    inviteCode: ObjectId = Field(repr=False)


class PartyDjRoomResponse(StrictModel):
    room: PartyDjRoom


class LeavePartyDjResponse(Versioned):
    state: Literal["active", "closed"]
    roomRevision: Revision
    nextHostAccountId: ObjectId | None


PARTY_DJ_REQUIRED_CAPABILITIES: frozenset[PlayerCapability] = frozenset({
    "queue", "next_previous"
})
