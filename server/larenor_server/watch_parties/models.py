"""Strict public contracts for synchronized household playback."""

from typing import Literal

from pydantic import Field, field_validator, model_validator

from ..admin.models import ObjectId, Revision
from ..models import StrictModel
from ..plugins.media_playback_models import PrepareMediaPlaybackIntentRequest


def _exact_version(value):
    if type(value) is not int:
        raise ValueError("invalid_schema")
    return value


class Versioned(StrictModel):
    schemaVersion: Literal[1] = 1

    _version = field_validator("schemaVersion", mode="before")(_exact_version)


class CreateWatchPartyRequest(PrepareMediaPlaybackIntentRequest):
    schemaVersion: Literal[1] = 1
    expiresAt: int = Field(ge=1, le=253402300799)
    toleranceMs: int = Field(default=1500, ge=250, le=5000)

    _version = field_validator("schemaVersion", mode="before")(_exact_version)


class JoinWatchPartyRequest(Versioned):
    requestId: ObjectId
    inviteCode: ObjectId = Field(repr=False)
    expectedRoomRevision: Revision


class WatchPartyTarget(Versioned):
    targetId: str = Field(min_length=1, max_length=128,
                          pattern=r"^[A-Za-z0-9][A-Za-z0-9_.:\-]{0,127}$")
    targetRevision: Revision
    canSeek: bool
    canPause: bool


class WatchPartyPlayback(Versioned):
    state: Literal["playing", "paused", "buffering"]
    positionMs: int = Field(ge=0, le=8_640_000_000)
    measuredRoundTripMs: int = Field(ge=0, le=10_000)


class ReportWatchPartyRequest(Versioned):
    requestId: ObjectId
    expectedRoomRevision: Revision
    expectedParticipantRevision: Revision
    target: WatchPartyTarget
    playback: WatchPartyPlayback


class CommandWatchPartyRequest(Versioned):
    requestId: ObjectId
    expectedRoomRevision: Revision
    expectedLeaderRevision: Revision
    action: Literal["play", "pause", "seek"]
    positionMs: int = Field(ge=0, le=8_640_000_000)


class TransferWatchPartyLeaderRequest(Versioned):
    requestId: ObjectId
    expectedRoomRevision: Revision
    expectedLeaderRevision: Revision
    nextLeaderAccountId: ObjectId
    expectedNextLeaderRevision: Revision


class LeaveWatchPartyRequest(Versioned):
    requestId: ObjectId
    expectedRoomRevision: Revision
    expectedParticipantRevision: Revision


class WatchPartyAuthority(Versioned):
    coreId: ObjectId
    homeId: ObjectId
    roomId: ObjectId
    installationId: ObjectId
    installationRevision: Revision
    snapshotRevision: Revision
    jellyfinServiceRevision: Revision
    itemId: ObjectId
    mediaKey: str = Field(min_length=1, max_length=96)


class WatchPartyMember(Versioned):
    accountId: ObjectId
    revision: Revision
    isLeader: bool
    connected: bool
    target: WatchPartyTarget | None
    playback: WatchPartyPlayback | None
    lastSeenAt: int = Field(ge=0, le=253402300799)


class WatchPartyCommand(Versioned):
    revision: Revision
    action: Literal["play", "pause"]
    positionMs: int = Field(ge=0, le=8_640_000_000)
    issuedAtMs: int = Field(ge=0, le=253402300799000)


class WatchPartyDirective(Versioned):
    commandRevision: Revision
    action: Literal["none", "play", "pause", "seek_and_play", "unsupported"]
    positionMs: int = Field(ge=0, le=8_640_000_000)
    skewMs: int = Field(ge=-8_640_000_000, le=8_640_000_000)
    toleranceMs: int = Field(ge=250, le=5000)


class WatchPartySnapshot(Versioned):
    authority: WatchPartyAuthority
    revision: Revision
    state: Literal["active", "closed"]
    leaderAccountId: ObjectId
    expiresAt: int = Field(ge=1, le=253402300799)
    toleranceMs: int = Field(ge=250, le=5000)
    command: WatchPartyCommand
    participants: list[WatchPartyMember] = Field(min_length=1, max_length=16)
    directive: WatchPartyDirective | None

    @model_validator(mode="after")
    def coherent(self):
        leaders = [member for member in self.participants if member.isLeader]
        if (len(leaders) != 1
                or leaders[0].accountId != self.leaderAccountId
                or len({member.accountId for member in self.participants})
                != len(self.participants)):
            raise ValueError("invalid_watch_party")
        return self


class CreateWatchPartyResponse(StrictModel):
    snapshot: WatchPartySnapshot
    inviteCode: ObjectId = Field(repr=False)


class WatchPartySnapshotResponse(StrictModel):
    snapshot: WatchPartySnapshot


class LeaveWatchPartyResponse(Versioned):
    state: Literal["active", "closed"]
    roomRevision: Revision
    nextLeaderAccountId: ObjectId | None
