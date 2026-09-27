from typing import Annotated, Literal

from pydantic import Field, field_validator, model_validator

from ..home_resources.models import FrozenModel, HomeScope, Identity, Revision


EvidenceState = Literal["reported", "verified", "unknown"]
PlaybackMethod = Literal["direct_play", "remux", "transcode", "unknown"]
HdrType = Literal["sdr", "hdr10", "hdr10_plus", "dolby_vision", "hlg", "unknown"]
Transport = Literal["wifi", "ethernet", "cellular", "vpn", "other", "offline"]
TranscodeReason = Literal[
    "container",
    "video_codec",
    "audio_codec",
    "subtitle",
    "bitrate",
    "resolution",
    "hdr",
    "network",
    "receiver",
    "unknown",
]
GapCode = Literal[
    "source_telemetry_missing",
    "codec_telemetry_missing",
    "bitrate_telemetry_missing",
    "network_telemetry_missing",
    "receiver_telemetry_missing",
    "hdr_telemetry_missing",
]
ReasonCode = Literal[
    "server_direct_play",
    "server_remux",
    "server_transcode",
    "server_decision_missing",
    "container_conversion",
    "video_codec_mismatch",
    "audio_codec_mismatch",
    "subtitle_requires_conversion",
    "bitrate_limit",
    "resolution_limit",
    "hdr_limit",
    "network_limit",
    "receiver_limit",
    "unspecified_transcode_reason",
]
RecommendationCode = Literal[
    "keep_original",
    "lower_bitrate",
    "prefer_compatible_audio",
    "prefer_external_subtitle",
    "inspect_receiver",
    "measure_network",
    "verify_hdr_on_device",
]
ProcessingLoad = Literal["low", "medium", "high", "unknown"]

SourceId = Annotated[
    str,
    Field(min_length=1, max_length=128, pattern=r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$"),
]
CodecToken = Annotated[
    str,
    Field(min_length=1, max_length=64, pattern=r"^[A-Za-z0-9][A-Za-z0-9._,+-]{0,63}$"),
]
PositiveRate = Annotated[int, Field(ge=1, le=1_000_000_000)]
Dimension = Annotated[int, Field(ge=1, le=32768)]


def _unique(values, code):
    if len(set(values)) != len(values):
        raise ValueError(code)
    return values


class PlaybackMediaEvidence(FrozenModel):
    state: EvidenceState
    sourceId: SourceId
    container: CodecToken | None
    videoCodec: CodecToken | None
    audioCodec: CodecToken | None
    subtitleCodec: CodecToken | None
    bitrateBps: PositiveRate | None
    width: Dimension | None
    height: Dimension | None
    hdr: HdrType | None
    serverDecision: PlaybackMethod
    transcodeReasons: Annotated[list[TranscodeReason], Field(max_length=10)]

    @field_validator("bitrateBps", "width", "height", mode="before")
    @classmethod
    def exact_integer(cls, value):
        if value is not None and type(value) is not int:
            raise ValueError("invalid_integer")
        return value

    @field_validator("transcodeReasons")
    @classmethod
    def unique_reasons(cls, value):
        return _unique(value, "duplicate_transcode_reason")

    @model_validator(mode="after")
    def coherent_evidence(self):
        if (self.width is None) != (self.height is None):
            raise ValueError("incomplete_dimensions")
        details = (
            self.container,
            self.videoCodec,
            self.audioCodec,
            self.subtitleCodec,
            self.bitrateBps,
            self.width,
            self.height,
            self.hdr,
        )
        if self.state == "unknown":
            if any(value is not None for value in details):
                raise ValueError("unknown_media_has_evidence")
            if self.serverDecision != "unknown" or self.transcodeReasons:
                raise ValueError("unknown_media_has_decision")
        elif not any(value is not None for value in details) and self.serverDecision == "unknown":
            raise ValueError("empty_media_evidence")
        if self.serverDecision in ("direct_play", "unknown") and self.transcodeReasons:
            raise ValueError("unexpected_transcode_reasons")
        return self


class PlaybackReceiverEvidence(FrozenModel):
    state: EvidenceState
    videoCodecs: Annotated[list[CodecToken], Field(max_length=32)]
    audioCodecs: Annotated[list[CodecToken], Field(max_length=32)]
    subtitleFormats: Annotated[list[CodecToken], Field(max_length=32)]
    maxWidth: Dimension | None
    maxHeight: Dimension | None
    hdrTypes: Annotated[list[HdrType], Field(max_length=6)]

    @field_validator("maxWidth", "maxHeight", mode="before")
    @classmethod
    def exact_integer(cls, value):
        if value is not None and type(value) is not int:
            raise ValueError("invalid_integer")
        return value

    @field_validator("videoCodecs", "audioCodecs", "subtitleFormats", "hdrTypes")
    @classmethod
    def unique_values(cls, value):
        return _unique(value, "duplicate_receiver_evidence")

    @model_validator(mode="after")
    def coherent_evidence(self):
        if (self.maxWidth is None) != (self.maxHeight is None):
            raise ValueError("incomplete_receiver_dimensions")
        values = (
            self.videoCodecs,
            self.audioCodecs,
            self.subtitleFormats,
            self.hdrTypes,
        )
        if self.state == "unknown":
            if any(values) or self.maxWidth is not None or self.maxHeight is not None:
                raise ValueError("unknown_receiver_has_evidence")
        elif not any(values) and self.maxWidth is None:
            raise ValueError("empty_receiver_evidence")
        return self


class PlaybackNetworkEvidence(FrozenModel):
    state: EvidenceState
    transport: Transport | None
    downstreamKbps: Annotated[int, Field(ge=1, le=10_000_000)] | None
    metered: bool | None

    @field_validator("downstreamKbps", mode="before")
    @classmethod
    def exact_integer(cls, value):
        if value is not None and type(value) is not int:
            raise ValueError("invalid_integer")
        return value

    @model_validator(mode="after")
    def coherent_evidence(self):
        values = (self.transport, self.downstreamKbps, self.metered)
        if self.state == "unknown" and any(value is not None for value in values):
            raise ValueError("unknown_network_has_evidence")
        if self.state != "unknown" and all(value is None for value in values):
            raise ValueError("empty_network_evidence")
        return self


class PlaybackQualityAdviceRequest(FrozenModel):
    schemaVersion: Literal[1]
    requestId: Identity
    media: PlaybackMediaEvidence
    receiver: PlaybackReceiverEvidence
    network: PlaybackNetworkEvidence

    @field_validator("schemaVersion", mode="before")
    @classmethod
    def exact_version(cls, value):
        if type(value) is not int:
            raise ValueError("invalid_schema")
        return value


class PlaybackQualityAuthority(HomeScope):
    schemaVersion: Literal[1]
    accountId: Identity
    accountRevision: Revision
    sessionFamilyId: Identity


class PlaybackQualityEvidenceStates(FrozenModel):
    schemaVersion: Literal[1]
    codec: EvidenceState
    bitrate: EvidenceState
    network: EvidenceState
    receiver: EvidenceState
    hdr: EvidenceState


class PlaybackQualityRecommendation(FrozenModel):
    schemaVersion: Literal[1]
    code: RecommendationCode
    maxBitrateBps: PositiveRate | None
    processingLoad: ProcessingLoad

    @field_validator("maxBitrateBps", mode="before")
    @classmethod
    def exact_integer(cls, value):
        if value is not None and type(value) is not int:
            raise ValueError("invalid_integer")
        return value

    @model_validator(mode="after")
    def bitrate_only_for_bitrate_advice(self):
        if self.code != "lower_bitrate" and self.maxBitrateBps is not None:
            raise ValueError("unexpected_bitrate_limit")
        return self


class PlaybackQualityAdviceResponse(FrozenModel):
    schemaVersion: Literal[1]
    authority: PlaybackQualityAuthority
    requestId: Identity
    advisoryOnly: Literal[True]
    physicalAcceptance: Literal["manual"]
    method: PlaybackMethod
    confidence: EvidenceState
    evidence: PlaybackQualityEvidenceStates
    gaps: Annotated[list[GapCode], Field(max_length=6)]
    reasons: Annotated[list[ReasonCode], Field(max_length=12)]
    recommendations: Annotated[list[PlaybackQualityRecommendation], Field(max_length=7)]
