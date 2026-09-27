"""Fail-closed provider boundary for tuner/IPTV recording effects."""

from dataclasses import dataclass
from typing import Literal, Protocol


@dataclass(frozen=True)
class LiveTvProviderCapability:
    provider_id: str
    provider_kind: Literal["tuner", "iptv"]
    provider_revision: int
    parallel_tuners: int
    quota_bytes: int


@dataclass(frozen=True)
class LiveTvRecordingCommand:
    request_id: str
    action: Literal["schedule", "cancel", "restart"]
    recording_id: str
    provider_recording_id: str | None
    recording_revision: int
    provider_id: str
    provider_revision: int
    guide_revision: int
    account_id: str
    session_family_id: str
    programme: dict


@dataclass(frozen=True)
class LiveTvRecordingReadback:
    provider_recording_id: str
    provider_revision: int
    readback_revision: int
    state: Literal[
        "scheduled", "recording", "interrupted", "completed", "cancelled",
        "partial", "uncertain",
    ]
    bytes_written: int
    observed_at: int


@dataclass(frozen=True)
class LiveTvRecordingReceipt:
    request_id: str
    action: Literal["schedule", "cancel", "restart"]
    recording_id: str
    provider_recording_id: str
    provider_revision: int
    readback: LiveTvRecordingReadback


class LiveTvSourceProvider(Protocol):
    def capability(self) -> LiveTvProviderCapability: ...


class LiveTvRecorder(Protocol):
    def apply(self, command: LiveTvRecordingCommand) -> LiveTvRecordingReceipt: ...
    def readback(self, provider_recording_id: str) -> LiveTvRecordingReadback: ...
