"""Strict, secret-free contracts for the media archive health projection."""

import re
import unicodedata
from typing import Literal

from pydantic import Field, field_validator, model_validator

from ..admin.models import ObjectId, Revision
from ..models import StrictModel


ArchiveService = Literal['jellyfin', 'sonarr', 'radarr', 'qbittorrent']
ArchiveSourceState = Literal['verified', 'unavailable', 'unsupported']
MediaKind = Literal['movie', 'episode']
_MEDIA_KEY = re.compile(
    r'(?:movie:tmdb:[1-9][0-9]{0,11}|episode:tvdb:[1-9][0-9]{0,11}:'
    r'[0-9]{1,4}:[0-9]{1,5})\Z'
)


def _safe_text(value: str) -> str:
    if value != value.strip() or any(
            unicodedata.category(character)[0] == 'C' for character in value):
        raise ValueError('invalid_media_archive_observation')
    return value


class ArchiveSourceBinding(StrictModel):
    serviceId: ArchiveService
    serviceRecordId: ObjectId
    serviceRevision: Revision
    snapshotRevision: Revision
    installationId: ObjectId
    installationRevision: Revision
    state: ArchiveSourceState
    observedAt: int = Field(ge=1, le=253402300799)


class MediaArchiveTranscodeEvidence(StrictModel):
    sourceCodec: Literal['h264', 'mpeg2', 'vc1']
    targetCodec: Literal['hevc', 'av1']
    sourceBitrate: int = Field(gt=0, le=1_000_000_000)
    targetBitrate: int = Field(gt=0, le=1_000_000_000)
    durationSeconds: int = Field(gt=0, le=604_800)
    targetPlaybackVerified: Literal[True]

    @model_validator(mode='after')
    def coherent(self):
        if self.targetBitrate >= self.sourceBitrate:
            raise ValueError('invalid_media_archive_observation')
        return self


class MediaArchiveQualityEvidence(StrictModel):
    width: int = Field(gt=0, le=16384)
    height: int = Field(gt=0, le=16384)
    videoBitrate: int = Field(gt=0, le=1_000_000_000)


class JellyfinArchiveItem(StrictModel):
    itemId: ObjectId
    mediaKey: str = Field(min_length=1, max_length=96)
    title: str = Field(min_length=1, max_length=240)
    mediaKind: MediaKind
    sizeBytes: int = Field(ge=0, le=2**63 - 1)
    integrity: Literal['playable', 'missing_file', 'corrupt', 'unplayable']
    transcode: 'MediaArchiveTranscodeEvidence | None' = None
    contentHash: str | None = Field(
        default=None, pattern=r'^[0-9a-f]{64}$')
    runtimeSeconds: int | None = Field(default=None, gt=0, le=604_800)
    quality: MediaArchiveQualityEvidence | None = None

    _key = field_validator('mediaKey')(
        lambda value: value if _MEDIA_KEY.fullmatch(value) else
        (_ for _ in ()).throw(ValueError('invalid_media_archive_observation')))
    _title = field_validator('title')(_safe_text)

    @model_validator(mode='after')
    def quality_has_runtime(self):
        if self.quality is not None and self.runtimeSeconds is None:
            raise ValueError('invalid_media_archive_observation')
        return self


class JellyfinArchiveSnapshot(ArchiveSourceBinding):
    serviceId: Literal['jellyfin']
    items: list[JellyfinArchiveItem] = Field(max_length=4096)
    transcodeEvidence: Literal['verified', 'unsupported'] = 'unsupported'

    @model_validator(mode='after')
    def coherent(self):
        if (self.state != 'verified' and self.items
                or len({item.itemId for item in self.items}) != len(self.items)
                or self.transcodeEvidence != 'verified'
                and any(item.transcode is not None for item in self.items)):
            raise ValueError('invalid_media_archive_observation')
        return self


class ArrArchiveItem(StrictModel):
    mediaKey: str = Field(min_length=1, max_length=96)
    title: str = Field(min_length=1, max_length=240)
    mediaKind: MediaKind
    monitored: bool
    state: Literal['available', 'missing', 'queued', 'downloading', 'failed']

    _key = field_validator('mediaKey')(
        lambda value: value if _MEDIA_KEY.fullmatch(value) else
        (_ for _ in ()).throw(ValueError('invalid_media_archive_observation')))
    _title = field_validator('title')(_safe_text)


class ArrArchiveSnapshot(ArchiveSourceBinding):
    serviceId: Literal['sonarr', 'radarr']
    items: list[ArrArchiveItem] = Field(max_length=4096)

    @model_validator(mode='after')
    def coherent(self):
        if (self.state != 'verified' and self.items
                or len({item.mediaKey for item in self.items}) != len(self.items)
                or any(self.serviceId == 'sonarr' and item.mediaKind != 'episode'
                       for item in self.items)
                or any(self.serviceId == 'radarr' and item.mediaKind != 'movie'
                       for item in self.items)):
            raise ValueError('invalid_media_archive_observation')
        return self


class QbittorrentArchiveItem(StrictModel):
    torrentId: str = Field(min_length=40, max_length=64)
    mediaKey: str | None = Field(default=None, max_length=96)
    title: str = Field(min_length=1, max_length=240)
    contentBytes: int = Field(ge=0, le=2**63 - 1)
    state: Literal['downloading', 'seeding', 'complete', 'paused', 'error']
    importedConfirmed: bool
    retentionPolicySatisfied: bool

    @field_validator('torrentId')
    @classmethod
    def torrent_id(cls, value):
        if re.fullmatch(r'(?:[0-9a-f]{40}|[0-9a-f]{64})', value) is None:
            raise ValueError('invalid_media_archive_observation')
        return value

    @field_validator('mediaKey')
    @classmethod
    def media_key(cls, value):
        if value is not None and _MEDIA_KEY.fullmatch(value) is None:
            raise ValueError('invalid_media_archive_observation')
        return value

    _title = field_validator('title')(_safe_text)

    @model_validator(mode='after')
    def coherent(self):
        if (self.importedConfirmed and self.mediaKey is None
                or self.retentionPolicySatisfied and (
                    not self.importedConfirmed or self.state != 'complete')):
            raise ValueError('invalid_media_archive_observation')
        return self


class QbittorrentArchiveSnapshot(ArchiveSourceBinding):
    serviceId: Literal['qbittorrent']
    items: list[QbittorrentArchiveItem] = Field(max_length=4096)

    @model_validator(mode='after')
    def coherent(self):
        if (self.state != 'verified' and self.items
                or len({item.torrentId for item in self.items}) != len(self.items)):
            raise ValueError('invalid_media_archive_observation')
        return self


class MediaArchiveCapacityEvidence(StrictModel):
    """Path-free storage capacity readback from one verified archive source."""

    source: ArchiveService
    serviceRevision: Revision
    snapshotRevision: Revision
    state: Literal['verified', 'unavailable', 'unsupported']
    totalBytes: int | None = Field(default=None, gt=0, le=2**63 - 1)
    freeBytes: int | None = Field(default=None, ge=0, le=2**63 - 1)

    @model_validator(mode='after')
    def coherent(self):
        has_values = self.totalBytes is not None and self.freeBytes is not None
        if ((self.state == 'verified') != has_values
                or has_values and self.freeBytes > self.totalBytes):
            raise ValueError('invalid_media_archive_capacity')
        return self


class MediaArchiveObservation(StrictModel):
    jellyfin: JellyfinArchiveSnapshot
    sonarr: ArrArchiveSnapshot
    radarr: ArrArchiveSnapshot
    qbittorrent: QbittorrentArchiveSnapshot
    capacity: MediaArchiveCapacityEvidence | None = None

    @model_validator(mode='after')
    def exact_sources(self):
        sources = {
            item.serviceId: item for item in (
                self.jellyfin, self.sonarr, self.radarr, self.qbittorrent)
        }
        if self.sonarr.serviceId != 'sonarr' or self.radarr.serviceId != 'radarr':
            raise ValueError('invalid_media_archive_observation')
        if self.capacity is not None:
            source = sources[self.capacity.source]
            if (source.serviceRevision != self.capacity.serviceRevision
                    or source.snapshotRevision != self.capacity.snapshotRevision
                    or self.capacity.state == 'verified'
                    and source.state != 'verified'):
                raise ValueError('invalid_media_archive_capacity')
        return self


class MediaArchiveIssue(StrictModel):
    code: Literal['missing_media', 'missing_file', 'corrupt_media',
                  'unplayable_media', 'download_error']
    severity: Literal['warning', 'critical']
    source: ArchiveService
    sourceItemId: str = Field(min_length=1, max_length=96)
    mediaKey: str | None
    title: str
    observedBytes: int = Field(ge=0, le=2**63 - 1)


class MediaArchiveSavingSuggestion(StrictModel):
    code: Literal['review_retained_download']
    torrentId: str
    mediaKey: str
    title: str
    potentialBytes: int = Field(gt=0, le=2**63 - 1)
    evidence: list[Literal['download_complete', 'import_verified',
                           'retention_policy_satisfied']] = Field(
                               min_length=3, max_length=3)
    cleanupAvailable: Literal[False] = False


SavingKind = Literal['duplicate', 'transcode', 'retention']
SavingLaneState = Literal[
    'verified', 'partial', 'unsupported', 'unavailable', 'stale']
SavingEvidence = Literal[
    'same_media_identity', 'content_hash_match',
    'name_size_runtime_match', 'quality_profile_comparison',
    'best_quality_excluded', 'multiple_playable_files',
    'largest_copy_excluded', 'source_profile_verified',
    'target_playback_verified', 'bounded_size_estimate',
    'download_complete', 'import_verified', 'retention_policy_satisfied']
SavingConfidence = Literal['high', 'medium']
SavingComparisonBasis = Literal[
    'keep_largest_copy', 'bounded_transcode_estimate',
    'review_retained_copy', 'keep_best_quality_copy']
SavingGroupReason = Literal[
    'exact_content_hash', 'probable_name_size_runtime',
    'lower_quality_variant', 'not_applicable']


class MediaArchiveSavingsComparison(StrictModel):
    basis: SavingComparisonBasis
    observedBytes: int = Field(gt=0, le=2**63 - 1)
    estimatedRetainedBytes: int = Field(ge=0, le=2**63 - 1)
    estimatedSavingBytes: int = Field(gt=0, le=2**63 - 1)

    @model_validator(mode='after')
    def coherent(self):
        if (self.estimatedRetainedBytes >= self.observedBytes
                or self.observedBytes - self.estimatedRetainedBytes
                != self.estimatedSavingBytes):
            raise ValueError('invalid_media_archive_savings_plan')
        return self


class MediaArchiveSavingsDataGap(StrictModel):
    lane: SavingKind
    reason: Literal[
        'partial', 'unsupported', 'unavailable', 'stale', 'truncated']


class MediaArchiveSavingsCandidate(StrictModel):
    kind: SavingKind
    source: Literal['jellyfin', 'qbittorrent']
    title: str = Field(min_length=1, max_length=240)
    potentialBytes: int = Field(gt=0, le=2**63 - 1)
    groupReason: SavingGroupReason
    confidence: SavingConfidence
    comparison: MediaArchiveSavingsComparison
    evidence: list[SavingEvidence] = Field(min_length=3, max_length=3)
    actionAvailable: Literal[False] = False

    _title = field_validator('title')(_safe_text)

    @model_validator(mode='after')
    def coherent(self):
        if self.kind == 'duplicate':
            confidence, basis, evidence = {
                'exact_content_hash': ('high', 'keep_largest_copy', [
                    'content_hash_match', 'multiple_playable_files',
                    'largest_copy_excluded']),
                'probable_name_size_runtime': (
                    'medium', 'keep_largest_copy', [
                        'name_size_runtime_match', 'multiple_playable_files',
                        'largest_copy_excluded']),
                'lower_quality_variant': (
                    'medium', 'keep_best_quality_copy', [
                        'same_media_identity', 'quality_profile_comparison',
                        'best_quality_excluded']),
            }.get(self.groupReason, (None, None, None))
            source = 'jellyfin'
        else:
            source, confidence, basis, evidence = {
                'transcode': ('jellyfin', 'medium',
                          'bounded_transcode_estimate', [
                'source_profile_verified', 'target_playback_verified',
                'bounded_size_estimate']),
                'retention': ('qbittorrent', 'medium',
                              'review_retained_copy', [
                'download_complete', 'import_verified',
                'retention_policy_satisfied']),
            }[self.kind]
        if (self.source != source or self.confidence != confidence
                or (self.kind != 'duplicate'
                    and self.groupReason != 'not_applicable')
                or self.comparison.basis != basis
                or self.comparison.estimatedSavingBytes != self.potentialBytes
                or self.evidence != evidence):
            raise ValueError('invalid_media_archive_savings_plan')
        return self


class MediaArchiveSavingsPlan(StrictModel):
    state: Literal['ready', 'partial']
    laneStates: dict[SavingKind, SavingLaneState]
    candidates: list[MediaArchiveSavingsCandidate] = Field(max_length=768)
    candidateCounts: dict[SavingKind, int]
    totalPotentialBytes: int = Field(ge=0, le=2**63 - 1)
    dataGaps: list[MediaArchiveSavingsDataGap] = Field(max_length=3)
    truncated: bool
    actionAvailable: Literal[False] = False

    @model_validator(mode='after')
    def coherent(self):
        lanes = {'duplicate', 'transcode', 'retention'}
        gap_pairs = [(gap.lane, gap.reason) for gap in self.dataGaps]
        expected_non_verified = {
            (kind, state) for kind, state in self.laneStates.items()
            if state != 'verified'
        }
        actual_non_verified = {
            pair for pair in gap_pairs if pair[1] != 'truncated'
        }
        truncated_lanes = {
            lane for lane, reason in gap_pairs if reason == 'truncated'
        }
        lane_order = {'duplicate': 0, 'transcode': 1, 'retention': 2}
        if (set(self.laneStates) != lanes or set(self.candidateCounts) != lanes
                or any(type(value) is not int or value < 0 or value > 256
                       for value in self.candidateCounts.values())
                or len(gap_pairs) != len(set(gap_pairs))
                or gap_pairs != sorted(
                    gap_pairs, key=lambda pair: (lane_order[pair[0]], pair[1]))
                or actual_non_verified != expected_non_verified
                or any(self.laneStates[lane] != 'verified'
                       for lane in truncated_lanes)
                or self.truncated != bool(truncated_lanes)
                or self.candidateCounts != {
                    kind: sum(item.kind == kind for item in self.candidates)
                    for kind in lanes}
                or self.totalPotentialBytes != sum(
                    item.potentialBytes for item in self.candidates)
                or any(self.laneStates[item.kind] != 'verified'
                       for item in self.candidates)
                or (self.state == 'ready') != (not self.dataGaps)):
            raise ValueError('invalid_media_archive_savings_plan')
        return self


class MediaArchiveCounts(StrictModel):
    missing: int = Field(ge=0, le=8192)
    broken: int = Field(ge=0, le=8192)
    failedDownloads: int = Field(ge=0, le=4096)
    savingCandidates: int = Field(ge=0, le=4096)
    potentialSavingBytes: int = Field(ge=0, le=2**63 - 1)


class MediaArchiveWeeklyTrendPoint(StrictModel):
    weekStart: int = Field(ge=1, le=253402300799)
    capturedAt: int = Field(ge=1, le=253402300799)
    snapshotRevision: Revision
    totalBytes: int = Field(gt=0, le=2**63 - 1)
    freeBytes: int = Field(ge=0, le=2**63 - 1)
    reclaimableBytes: int = Field(ge=0, le=2**63 - 1)
    duplicateCandidates: int = Field(ge=0, le=256)
    lowQualityCandidates: int = Field(ge=0, le=256)

    @model_validator(mode='after')
    def coherent(self):
        days = self.weekStart // 86400
        if (self.freeBytes > self.totalBytes
                or self.weekStart % 86400 != 0 or (days + 3) % 7 != 0
                or not self.weekStart <= self.capturedAt < self.weekStart + 604800):
            raise ValueError('invalid_media_archive_trend')
        return self


class MediaArchiveWeeklyTrend(StrictModel):
    state: Literal['ready', 'stale', 'unavailable']
    points: list[MediaArchiveWeeklyTrendPoint] = Field(max_length=12)
    actionAvailable: Literal[False] = False

    @model_validator(mode='after')
    def coherent(self):
        if ((self.state == 'unavailable') != (not self.points)
                or any(left.weekStart >= right.weekStart
                       or left.capturedAt >= right.capturedAt
                       or left.snapshotRevision >= right.snapshotRevision
                       for left, right in zip(self.points, self.points[1:]))):
            raise ValueError('invalid_media_archive_trend')
        return self


class MediaArchiveHealth(StrictModel):
    installationId: ObjectId
    installationRevision: Revision
    snapshotRevision: Revision
    state: Literal['healthy', 'attention', 'incomplete']
    sourceStates: dict[ArchiveService, Literal[
        'verified', 'unavailable', 'unsupported', 'stale']]
    sourceRevisions: dict[ArchiveService, Revision]
    counts: MediaArchiveCounts
    issues: list[MediaArchiveIssue] = Field(max_length=12288)
    suggestions: list[MediaArchiveSavingSuggestion] = Field(max_length=4096)
    savingsPlan: MediaArchiveSavingsPlan
    weeklyTrend: MediaArchiveWeeklyTrend = Field(default_factory=lambda:
        MediaArchiveWeeklyTrend(
            state='unavailable', points=[], actionAvailable=False))
    cleanupAvailable: Literal[False] = False
    generatedAt: int = Field(ge=1, le=253402300799)

    @model_validator(mode='after')
    def exact_sources(self):
        expected = {'jellyfin', 'sonarr', 'radarr', 'qbittorrent'}
        if set(self.sourceStates) != expected or set(self.sourceRevisions) != expected:
            raise ValueError('invalid_media_archive_health')
        return self
