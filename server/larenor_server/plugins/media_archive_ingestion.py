"""Fail-closed adapters from authenticated service facts to F30 observations.

The adapter performs no network or filesystem access. Credentials remain in
the private authenticated-readback objects and are never copied, formatted or
returned. Item input is already a bounded worker projection, not a raw service
response.
"""

import re

from pydantic import ValidationError

from .arr_authenticated_readback import ArrAuthenticatedReadbackResult
from .jellyfin_authenticated_readback import JellyfinAuthenticatedReadbackResult
from .media_archive_health_models import (
    ArchiveSourceBinding,
    ArrArchiveItem,
    ArrArchiveSnapshot,
    JellyfinArchiveItem,
    JellyfinArchiveSnapshot,
    MediaArchiveObservation,
    QbittorrentArchiveItem,
    QbittorrentArchiveSnapshot,
)
from .qbittorrent_authenticated_readback import (
    QbittorrentAuthenticatedReadbackResult,
)
from .qbittorrent_readback import QbittorrentReadback


_MAX_AGE_SECONDS = 300
_ID = re.compile(r'[0-9a-f]{32}\Z')
_VERSION = re.compile(
    r'[0-9]{1,4}(?:\.[0-9]{1,4}){2,3}(?:[-+][0-9A-Za-z.-]{1,64})?\Z')
_ARR = {
    'sonarr': ('Sonarr', '4.0.19.2979'),
    'radarr': ('Radarr', '6.3.0.10514'),
}
_JELLYFIN_STEPS = {
    ('authenticated', 'keys_observed', 'key_verified', 'system_verified',
     'libraries_verified', 'session_closed'),
    ('authenticated', 'keys_observed', 'key_created', 'key_verified',
     'system_verified', 'libraries_verified', 'session_closed'),
}
_QBITTORRENT_STEPS = (
    'version_verified', 'preferences_verified', 'categories_verified')


class MediaArchiveIngestionError(ValueError):
    """A stable error code that never includes upstream data or secrets."""

    _CODES = frozenset({
        'archive_source_drift', 'archive_source_stale',
        'archive_projection_invalid', 'archive_authority_changed',
    })

    def __init__(self, code):
        self.code = code if code in self._CODES else 'archive_projection_invalid'
        super().__init__(self.code)

    def __repr__(self):
        return f'MediaArchiveIngestionError({self.code!r})'


def _binding(value, service, now):
    if (type(value) is not ArchiveSourceBinding or type(now) is not int
            or type(now) is bool):
        raise MediaArchiveIngestionError('archive_source_drift')
    try:
        current = ArchiveSourceBinding.model_validate(value.model_dump())
    except (ValidationError, ValueError, TypeError, AttributeError):
        raise MediaArchiveIngestionError('archive_source_drift') from None
    if current.serviceId != service or current.state != 'verified':
        raise MediaArchiveIngestionError('archive_source_drift')
    if current.observedAt > now or now - current.observedAt > _MAX_AGE_SECONDS:
        raise MediaArchiveIngestionError('archive_source_stale')
    return current.model_dump(mode='python')


def _records(values, model):
    if type(values) is not list or len(values) > 4096:
        raise MediaArchiveIngestionError('archive_projection_invalid')
    try:
        return [model.model_validate(value) for value in values]
    except (ValidationError, ValueError, TypeError, AttributeError,
            RecursionError, OverflowError):
        raise MediaArchiveIngestionError('archive_projection_invalid') from None


def _jellyfin_proof(value, expected_server_id):
    if (type(value) is not JellyfinAuthenticatedReadbackResult
            or type(expected_server_id) is not str
            or _ID.fullmatch(expected_server_id) is None
            or value.state != 'verified'
            or value.server_id != expected_server_id
            or _VERSION.fullmatch(value.version) is None
            or value.completed_steps not in _JELLYFIN_STEPS
            or type(value.libraries) is not tuple
            or len(value.libraries) > 256):
        raise MediaArchiveIngestionError('archive_source_drift')
    library_ids = []
    for library in value.libraries:
        if (type(library) is not tuple or len(library) != 4
                or type(library[2]) is not str
                or _ID.fullmatch(library[2]) is None
                or type(library[3]) is not tuple):
            raise MediaArchiveIngestionError('archive_source_drift')
        library_ids.append(library[2])
    if len(set(library_ids)) != len(library_ids):
        raise MediaArchiveIngestionError('archive_source_drift')


def _arr_proof(value, service):
    expected = _ARR[service]
    if (type(value) is not ArrAuthenticatedReadbackResult
            or value.state != 'verified' or value.service_id != service
            or (value.app_name, value.version) != expected):
        raise MediaArchiveIngestionError('archive_source_drift')


def _qbittorrent_proof(value):
    if (type(value) is not QbittorrentAuthenticatedReadbackResult
            or value.state != 'verified' or value.version != 'v5.2.3'
            or value.completed_steps != _QBITTORRENT_STEPS
            or type(value.settings) is not QbittorrentReadback):
        raise MediaArchiveIngestionError('archive_source_drift')
    settings = value.settings
    if (settings.state != 'verified' or settings.username != 'larenor-system'
            or settings.web_port != 8080 or settings.torrent_port != 6881
            or settings.download_path != '/data/downloads'
            or settings.incomplete_path != '/data/incomplete'
            or settings.categories != (
                ('movies', '/data/downloads/movies'),
                ('tv', '/data/downloads/tv'))):
        raise MediaArchiveIngestionError('archive_source_drift')


class MediaArchiveIngestion:
    """One-shot, read-only conversion of four independently verified sources."""

    def jellyfin(self, binding, readback, records, *, expected_server_id, now):
        source = _binding(binding, 'jellyfin', now)
        _jellyfin_proof(readback, expected_server_id)
        try:
            items = _records(records, JellyfinArchiveItem)
            return JellyfinArchiveSnapshot(
                **source, items=items,
                transcodeEvidence=(
                    'verified' if any(item.transcode is not None
                                      for item in items) else 'unsupported'))
        except (ValidationError, ValueError, TypeError):
            raise MediaArchiveIngestionError(
                'archive_projection_invalid') from None

    def arr(self, binding, readback, records, *, now):
        service = binding.serviceId if type(binding) is ArchiveSourceBinding else None
        if service not in _ARR:
            raise MediaArchiveIngestionError('archive_source_drift')
        source = _binding(binding, service, now)
        _arr_proof(readback, service)
        try:
            return ArrArchiveSnapshot(
                **source, items=_records(records, ArrArchiveItem))
        except (ValidationError, ValueError, TypeError):
            raise MediaArchiveIngestionError(
                'archive_projection_invalid') from None

    def qbittorrent(self, binding, readback, records, *, now):
        source = _binding(binding, 'qbittorrent', now)
        _qbittorrent_proof(readback)
        try:
            return QbittorrentArchiveSnapshot(
                **source, items=_records(records, QbittorrentArchiveItem))
        except (ValidationError, ValueError, TypeError):
            raise MediaArchiveIngestionError(
                'archive_projection_invalid') from None

    def assemble(self, *, jellyfin, sonarr, radarr, qbittorrent):
        values = (jellyfin, sonarr, radarr, qbittorrent)
        expected = (JellyfinArchiveSnapshot, ArrArchiveSnapshot,
                    ArrArchiveSnapshot, QbittorrentArchiveSnapshot)
        if any(type(value) is not kind
               for value, kind in zip(values, expected, strict=True)):
            raise MediaArchiveIngestionError('archive_source_drift')
        authority = {(value.installationId, value.installationRevision,
                      value.snapshotRevision) for value in values}
        if len(authority) != 1:
            raise MediaArchiveIngestionError('archive_authority_changed')
        try:
            return MediaArchiveObservation(
                jellyfin=jellyfin, sonarr=sonarr,
                radarr=radarr, qbittorrent=qbittorrent)
        except (ValidationError, ValueError, TypeError):
            raise MediaArchiveIngestionError('archive_source_drift') from None
