"""Bounded, read-only collection from the four managed media services.

All destinations come from a re-derived packaged stack plan and are reached on
numeric loopback.  The collector never follows redirects, retries, mutates a
service, or returns credentials and service paths in its observation.
"""

from __future__ import annotations

from dataclasses import dataclass
import json
import re
import socket
import time
from urllib.parse import urlencode

from pydantic import ValidationError

from ..services.transport import _Deadline, _remaining, _request_bytes
from ..media_archive_actions.source_resolver import (
    AuthenticatedArchiveSourceRecord,
)
from ..media_archive_actions.cleanup_catalog import (
    AuthenticatedArchiveCleanupItem, AuthenticatedArchiveTorrent,
)
from .arr_authenticated_readback import ArrAuthenticatedReadbackResult
from .catalog import load_catalog
from .jellyfin_authenticated_readback import (
    JellyfinAuthenticatedReadbackResult,
    _libraries,
    _system,
)
from .jellyfin_startup import _ConnectionLost, _StartupReader, _response
from .media_archive_core_models import PrivateMediaArchiveWorkerCollection
from .media_archive_ingestion import MediaArchiveIngestion
from .qbittorrent_authenticated_readback import (
    QbittorrentAuthenticatedReadbackResult,
)
from .qbittorrent_readback import validate_qbittorrent_readback
from .stack_plan import MediaStackPlanError, verify_media_stack_plan


_SERVICES = ('jellyfin', 'sonarr', 'radarr', 'qbittorrent')
_EXPECTED = {
    'jellyfin': ('Jellyfin Server', '10.11.11'),
    'sonarr': ('Sonarr', '4.0.19.2979'),
    'radarr': ('Radarr', '6.3.0.10514'),
    'qbittorrent': ('qBittorrent', 'v5.2.3'),
}
_MAX_ITEMS = 4096
_MAX_RESPONSE = 2 * 1024 * 1024
_SAFE_PATH = re.compile(r'/[\x20-\x7e]{1,1023}\Z')


class MediaArchiveReadCollectorError(RuntimeError):
    """Stable, secret-free failure for one all-or-nothing collection."""

    _CODES = frozenset({
        'invalid_media_archive_collection', 'media_archive_deadline_exceeded',
        'media_archive_source_unavailable', 'media_archive_authentication_failed',
        'media_archive_source_drift', 'media_archive_projection_invalid',
    })

    def __init__(self, code='media_archive_source_unavailable'):
        self.code = code if code in self._CODES else 'media_archive_source_unavailable'
        super().__init__(self.code)

    def __repr__(self):
        return f'MediaArchiveReadCollectorError({self.code!r})'


def _unique(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError()
        value[key] = item
    return value


def _json(raw):
    try:
        return json.loads(
            raw.decode('utf-8'), object_pairs_hook=_unique,
            parse_constant=lambda _value: (_ for _ in ()).throw(ValueError()))
    except (UnicodeError, json.JSONDecodeError, ValueError, TypeError):
        raise MediaArchiveReadCollectorError(
            'media_archive_projection_invalid') from None


def _gate(deadline, gate):
    try:
        allowed = gate()
    except Exception:
        allowed = False
    if allowed is not True or time.monotonic() >= deadline:
        raise MediaArchiveReadCollectorError('media_archive_deadline_exceeded')


class _LoopbackTransport:
    """One GET per new socket; no DNS, redirects, retry, cookies, or proxy."""

    def get(self, service, port, path, api_key, *, deadline, gate, text=False):
        if (service not in _SERVICES or type(port) is not int
                or not 1024 <= port <= 65535 or type(path) is not str
                or not path.startswith('/') or '\r' in path or '\n' in path):
            raise MediaArchiveReadCollectorError(
                'invalid_media_archive_collection')
        _gate(deadline, gate)
        headers = {'Accept': 'text/plain' if text else 'application/json'}
        if service == 'jellyfin':
            headers['Authorization'] = (
                'MediaBrowser Client="Larenor Core", Device="Larenor Core", '
                'DeviceId="archive-read", Version="0.1.0", Token="' + api_key + '"')
        elif service in {'sonarr', 'radarr'}:
            headers['X-Api-Key'] = api_key
        else:
            headers['Authorization'] = 'Bearer ' + api_key
        connection = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        scope = _Deadline(deadline)
        try:
            scope.attach(connection)
            connection.settimeout(_remaining(deadline))
            connection.connect(('127.0.0.1', port))
            connection.settimeout(_remaining(deadline))
            connection.sendall(_request_bytes(
                'GET', path, service, headers, None))
            status, raw, _closes = _response(
                _StartupReader(connection, deadline), _MAX_RESPONSE,
                content_type='text/plain' if text else 'application/json',
                error_content_type='text/plain')
            if status in {401, 403}:
                raise MediaArchiveReadCollectorError(
                    'media_archive_authentication_failed')
            if status != 200:
                raise MediaArchiveReadCollectorError(
                    'media_archive_source_unavailable')
            _gate(deadline, gate)
            return raw.decode('ascii') if text else _json(raw)
        except MediaArchiveReadCollectorError:
            raise
        except (socket.timeout, TimeoutError):
            raise MediaArchiveReadCollectorError(
                'media_archive_deadline_exceeded') from None
        except (_ConnectionLost, OSError, RuntimeError, ValueError,
                UnicodeError, AttributeError):
            raise MediaArchiveReadCollectorError(
                'media_archive_source_unavailable') from None
        finally:
            scope.finish()


def _port(component):
    candidates = [item.hostPort for item in component.plan.ports
                  if item.protocol == 'tcp'
                  and item.hostPort == component.plan.health.port]
    if len(candidates) != 1:
        raise MediaArchiveReadCollectorError('media_archive_source_drift')
    return candidates[0]


def _path(value, prefix):
    if (type(value) is not str or _SAFE_PATH.fullmatch(value) is None
            or not value.startswith(prefix + '/') or value.endswith('/')
            or '//' in value
            or any(part in {'', '.', '..'} for part in value.split('/')[2:])):
        raise MediaArchiveReadCollectorError('media_archive_projection_invalid')
    return value[len(prefix):]


def _name(value):
    if (type(value) is not str or value != value.strip()
            or not 1 <= len(value) <= 240
            or any(ord(char) < 32 for char in value)):
        raise MediaArchiveReadCollectorError('media_archive_projection_invalid')
    return value


def _integer(value, minimum=0, maximum=2**63 - 1):
    if type(value) is not int or type(value) is bool or not minimum <= value <= maximum:
        raise MediaArchiveReadCollectorError('media_archive_projection_invalid')
    return value


def _list(value):
    if type(value) is not list or len(value) > _MAX_ITEMS:
        raise MediaArchiveReadCollectorError('media_archive_projection_invalid')
    return value


def _page(value):
    if (type(value) is not dict or type(value.get('records')) is not list
            or type(value.get('totalRecords')) is not int
            or value['totalRecords'] != len(value['records'])
            or len(value['records']) > _MAX_ITEMS):
        raise MediaArchiveReadCollectorError('media_archive_projection_invalid')
    return value['records']


def _query(path, **values):
    return path + '?' + urlencode(values)


@dataclass(frozen=True)
class _ArrFile:
    media_key: str
    service: str
    file_id: int
    path: str


@dataclass(frozen=True)
class _ArrProjection:
    records: list[dict]
    path_keys: dict[str, _ArrFile]
    imports: dict[str, str]


class MediaArchiveReadCollector:
    """Collect four coherent service snapshots through bounded read-only APIs."""

    def __init__(self, transport=None, *, clock=None, private_source_sink=None,
                 private_cleanup_sink=None, credential_sink=None):
        self.transport = transport or _LoopbackTransport()
        self.clock = clock or time.time
        self.private_source_sink = private_source_sink
        self.private_cleanup_sink = private_cleanup_sink
        self.credential_sink = credential_sink
        if (not callable(getattr(self.transport, 'get', None))
                or not callable(self.clock)
                or private_source_sink is not None
                and not callable(getattr(
                    private_source_sink,
                    'replace_collection_authenticated', None))):
            raise MediaArchiveReadCollectorError('invalid_media_archive_collection')
        if (private_cleanup_sink is not None and not callable(getattr(
                private_cleanup_sink, 'replace_collection_authenticated', None))
                or credential_sink is not None and not callable(getattr(
                    credential_sink, 'refresh_authenticated', None))):
            raise MediaArchiveReadCollectorError('invalid_media_archive_collection')

    def collect(self, private, *, deadline, gate):
        if (type(private) is not PrivateMediaArchiveWorkerCollection
                or type(deadline) not in (int, float) or type(deadline) is bool
                or not callable(gate)):
            raise MediaArchiveReadCollectorError('invalid_media_archive_collection')
        try:
            selected = PrivateMediaArchiveWorkerCollection.model_validate(
                private.model_dump(mode='python'))
            plan = verify_media_stack_plan(selected.plan, load_catalog())
        except (ValidationError, ValueError, TypeError, AttributeError,
                MediaStackPlanError):
            raise MediaArchiveReadCollectorError(
                'invalid_media_archive_collection') from None
        _gate(deadline, gate)
        sources = {item.serviceId: item for item in selected.sources}
        components = {item.serviceId: item for item in plan.components}
        ports = {service: _port(components[service]) for service in _SERVICES}
        bindings = {item.serviceId: item for item in selected.authority.sources}

        jelly_proof, jelly_raw = self._jellyfin(
            sources['jellyfin'], ports['jellyfin'], deadline, gate)
        sonarr_proof, sonarr = self._sonarr(
            sources['sonarr'], ports['sonarr'], deadline, gate)
        radarr_proof, radarr = self._radarr(
            sources['radarr'], ports['radarr'], deadline, gate)
        qbit_proof, qbit, private_torrents = self._qbittorrent(
            sources['qbittorrent'], ports['qbittorrent'],
            components['qbittorrent'], deadline, gate,
            {**sonarr.imports, **radarr.imports})
        jellyfin, private_sources, private_cleanup = self._jellyfin_records(
            jelly_raw, {**sonarr.path_keys, **radarr.path_keys})
        now = int(self.clock())
        adapter = MediaArchiveIngestion()
        _gate(deadline, gate)
        try:
            observation = adapter.assemble(
                jellyfin=adapter.jellyfin(
                    bindings['jellyfin'], jelly_proof, jellyfin,
                    expected_server_id=sources['jellyfin'].serverId, now=now),
                sonarr=adapter.arr(
                    bindings['sonarr'], sonarr_proof, sonarr.records, now=now),
                radarr=adapter.arr(
                    bindings['radarr'], radarr_proof, radarr.records, now=now),
                qbittorrent=adapter.qbittorrent(
                    bindings['qbittorrent'], qbit_proof, qbit, now=now),
            )
        except Exception:
            raise MediaArchiveReadCollectorError(
                'media_archive_projection_invalid') from None
        _gate(deadline, gate)
        if self.private_source_sink is not None:
            try:
                self.private_source_sink.replace_collection_authenticated(
                    selected.authority, private_sources,
                    deadline=deadline, gate=gate)
            except Exception:
                raise MediaArchiveReadCollectorError(
                    'media_archive_source_unavailable') from None
        if self.private_cleanup_sink is not None:
            try:
                self.private_cleanup_sink.replace_collection_authenticated(
                    selected.authority, private_cleanup, private_torrents,
                    deadline=deadline, gate=gate)
            except Exception:
                raise MediaArchiveReadCollectorError(
                    'media_archive_source_unavailable') from None
        if self.credential_sink is not None:
            try:
                self.credential_sink.refresh_authenticated(
                    selected, ports, deadline=deadline, gate=gate)
            except Exception:
                raise MediaArchiveReadCollectorError(
                    'media_archive_source_unavailable') from None
        _gate(deadline, gate)
        return observation

    def _get(self, service, port, path, source, deadline, gate, *, text=False):
        return self.transport.get(
            service, port, path, source.apiKey, deadline=deadline,
            gate=gate, text=text)

    def _jellyfin(self, source, port, deadline, gate):
        system = self._get('jellyfin', port, '/System/Info', source, deadline, gate)
        try:
            server_name, version = _system(system, source.serverId)
        except (ValueError, TypeError, AttributeError):
            raise MediaArchiveReadCollectorError('media_archive_source_drift') from None
        if version != _EXPECTED['jellyfin'][1]:
            raise MediaArchiveReadCollectorError('media_archive_source_drift')
        libraries_raw = self._get(
            'jellyfin', port, '/Library/VirtualFolders', source, deadline, gate)
        try:
            libraries = _libraries(libraries_raw)
        except (ValueError, TypeError, AttributeError):
            raise MediaArchiveReadCollectorError('media_archive_source_drift') from None
        if not libraries or any(
                collection not in {'movies', 'tvshows'} or not paths
                for _name_, collection, _identifier, paths in libraries):
            raise MediaArchiveReadCollectorError('media_archive_source_drift')
        raw = self._get('jellyfin', port, _query(
            '/Items', IncludeItemTypes='Movie,Episode', Recursive='true',
            Fields='Path,ProviderIds,MediaSources,MediaStreams,RunTimeTicks',
            StartIndex=0, Limit=_MAX_ITEMS), source, deadline, gate)
        proof = JellyfinAuthenticatedReadbackResult(
            state='verified', server_id=source.serverId, server_name=server_name,
            version=version, user_id='0' * 32, api_key=source.apiKey,
            libraries=libraries,
            completed_steps=('api_key_verified', 'system_verified',
                             'libraries_verified'))
        return proof, raw

    def _arr_identity(self, service, source, port, deadline, gate):
        value = self._get(
            service, port, '/api/v3/system/status', source, deadline, gate)
        expected_name, expected_version = _EXPECTED[service]
        if (type(value) is not dict or value.get('appName') != expected_name
                or value.get('version') != expected_version):
            raise MediaArchiveReadCollectorError('media_archive_source_drift')
        return ArrAuthenticatedReadbackResult(
            'verified', service, expected_name, expected_version)

    def _queues(self, service, source, port, deadline, gate):
        suffix = 'Series' if service == 'sonarr' else 'Movie'
        records = _page(self._get(service, port, _query(
            '/api/v3/queue', page=1, pageSize=_MAX_ITEMS,
            **{f'includeUnknown{suffix}Items': 'false'}),
            source, deadline, gate))
        field = 'episodeId' if service == 'sonarr' else 'movieId'
        result = {}
        for item in records:
            if type(item) is not dict:
                raise MediaArchiveReadCollectorError('media_archive_projection_invalid')
            identifier = _integer(item.get(field), 1, 2**31 - 1)
            status = item.get('status')
            tracked = item.get('trackedDownloadStatus', 'ok')
            if tracked in {'warning', 'error'}:
                state = 'failed'
            elif status == 'downloading':
                state = 'downloading'
            elif status in {'queued', 'paused', 'delay'}:
                state = 'queued'
            elif status == 'completed':
                state = 'queued'
            else:
                raise MediaArchiveReadCollectorError('media_archive_projection_invalid')
            if identifier in result and result[identifier] != state:
                raise MediaArchiveReadCollectorError('media_archive_projection_invalid')
            result[identifier] = state
        return result

    def _history(self, service, source, port, deadline, gate, id_keys):
        records = _page(self._get(service, port, _query(
            '/api/v3/history', page=1, pageSize=_MAX_ITEMS, sortKey='date',
            sortDirection='descending', eventType='downloadFolderImported'),
            source, deadline, gate))
        field = 'episodeId' if service == 'sonarr' else 'movieId'
        result = {}
        for item in records:
            if type(item) is not dict or item.get('eventType') != 'downloadFolderImported':
                raise MediaArchiveReadCollectorError('media_archive_projection_invalid')
            download = item.get('downloadId')
            identifier = item.get(field)
            if (type(download) is not str
                    or re.fullmatch(r'(?:[0-9A-Fa-f]{40}|[0-9A-Fa-f]{64})', download) is None
                    or type(identifier) is not int or identifier not in id_keys):
                raise MediaArchiveReadCollectorError('media_archive_projection_invalid')
            key = id_keys[identifier]
            download = download.lower()
            if download in result and result[download] != key:
                raise MediaArchiveReadCollectorError('media_archive_projection_invalid')
            result[download] = key
        return result

    def _sonarr(self, source, port, deadline, gate):
        proof = self._arr_identity('sonarr', source, port, deadline, gate)
        series = _list(self._get(
            'sonarr', port, '/api/v3/series', source, deadline, gate))
        series_by_id = {}
        for item in series:
            if (type(item) is not dict or type(item.get('id')) is not int
                    or type(item.get('tvdbId')) is not int
                    or item['id'] <= 0 or item['tvdbId'] <= 0):
                raise MediaArchiveReadCollectorError('media_archive_projection_invalid')
            series_by_id[item['id']] = (
                item['tvdbId'], _path(item.get('path'), '/data'))
        queue = self._queues('sonarr', source, port, deadline, gate)
        records, paths, keys = [], {}, {}
        for series_id, (tvdb, series_path) in series_by_id.items():
            episodes = _list(self._get('sonarr', port, _query(
                '/api/v3/episode', seriesId=series_id,
                includeEpisodeFile='true'), source, deadline, gate))
            if len(records) + len(episodes) > _MAX_ITEMS:
                raise MediaArchiveReadCollectorError('media_archive_projection_invalid')
            for item in episodes:
                if type(item) is not dict or item.get('seriesId') != series_id:
                    raise MediaArchiveReadCollectorError('media_archive_projection_invalid')
                identifier = _integer(item.get('id'), 1, 2**31 - 1)
                season = _integer(item.get('seasonNumber'), 0, 9999)
                number = _integer(item.get('episodeNumber'), 0, 99999)
                key = f'episode:tvdb:{tvdb}:{season}:{number}'
                has_file = item.get('hasFile')
                monitored = item.get('monitored')
                if type(has_file) is not bool or type(monitored) is not bool:
                    raise MediaArchiveReadCollectorError('media_archive_projection_invalid')
                records.append({
                    'mediaKey': key, 'title': _name(item.get('title')),
                    'mediaKind': 'episode', 'monitored': monitored,
                    'state': queue.get(identifier, 'available' if has_file else 'missing'),
                })
                keys[identifier] = key
                if has_file:
                    episode_file = item.get('episodeFile')
                    if type(episode_file) is not dict:
                        raise MediaArchiveReadCollectorError('media_archive_projection_invalid')
                    path = episode_file.get('path')
                    if path is None:
                        relative = episode_file.get('relativePath')
                        if type(relative) is not str:
                            raise MediaArchiveReadCollectorError('media_archive_projection_invalid')
                        path = '/data' + series_path + '/' + relative
                    normalized = _path(path, '/data')
                    if (normalized in paths
                            and paths[normalized].media_key != key):
                        raise MediaArchiveReadCollectorError('media_archive_projection_invalid')
                    file_id = _integer(episode_file.get('id'), 1, 2**31 - 1)
                    paths[normalized] = _ArrFile(
                        key, 'sonarr', file_id, path)
        imports = self._history(
            'sonarr', source, port, deadline, gate, keys)
        return proof, _ArrProjection(records, paths, imports)

    def _radarr(self, source, port, deadline, gate):
        proof = self._arr_identity('radarr', source, port, deadline, gate)
        movies = _list(self._get(
            'radarr', port, '/api/v3/movie', source, deadline, gate))
        queue = self._queues('radarr', source, port, deadline, gate)
        records, paths, keys = [], {}, {}
        for item in movies:
            if type(item) is not dict:
                raise MediaArchiveReadCollectorError('media_archive_projection_invalid')
            identifier = _integer(item.get('id'), 1, 2**31 - 1)
            tmdb = _integer(item.get('tmdbId'), 1, 999999999999)
            key = f'movie:tmdb:{tmdb}'
            monitored, has_file = item.get('monitored'), item.get('hasFile')
            if type(monitored) is not bool or type(has_file) is not bool:
                raise MediaArchiveReadCollectorError('media_archive_projection_invalid')
            records.append({
                'mediaKey': key, 'title': _name(item.get('title')),
                'mediaKind': 'movie', 'monitored': monitored,
                'state': queue.get(identifier, 'available' if has_file else 'missing'),
            })
            keys[identifier] = key
            if has_file:
                root = _path(item.get('path'), '/data')
                movie_file = item.get('movieFile')
                if type(movie_file) is not dict:
                    raise MediaArchiveReadCollectorError('media_archive_projection_invalid')
                path = movie_file.get('path')
                if path is None:
                    relative = movie_file.get('relativePath')
                    if type(relative) is not str:
                        raise MediaArchiveReadCollectorError('media_archive_projection_invalid')
                    path = '/data' + root + '/' + relative
                normalized = _path(path, '/data')
                if (normalized in paths
                        and paths[normalized].media_key != key):
                    raise MediaArchiveReadCollectorError('media_archive_projection_invalid')
                file_id = _integer(movie_file.get('id'), 1, 2**31 - 1)
                paths[normalized] = _ArrFile(
                    key, 'radarr', file_id, path)
        imports = self._history(
            'radarr', source, port, deadline, gate, keys)
        return proof, _ArrProjection(records, paths, imports)

    def _qbittorrent(self, source, port, component, deadline, gate, imports):
        version = self._get(
            'qbittorrent', port, '/api/v2/app/version', source,
            deadline, gate, text=True)
        if version != _EXPECTED['qbittorrent'][1]:
            raise MediaArchiveReadCollectorError('media_archive_source_drift')
        preferences = self._get(
            'qbittorrent', port, '/api/v2/app/preferences', source,
            deadline, gate)
        categories = self._get(
            'qbittorrent', port, '/api/v2/torrents/categories', source,
            deadline, gate)
        torrent_ports = [item.hostPort for item in component.plan.ports
                         if item.hostPort != port]
        if not torrent_ports or len(set(torrent_ports)) != 1:
            raise MediaArchiveReadCollectorError('media_archive_source_drift')
        try:
            settings = validate_qbittorrent_readback(
                preferences, categories, web_port=port,
                torrent_port=torrent_ports[0])
        except Exception:
            raise MediaArchiveReadCollectorError('media_archive_source_drift') from None
        proof = QbittorrentAuthenticatedReadbackResult(
            'verified', version, settings,
            ('version_verified', 'preferences_verified', 'categories_verified'))
        torrents = _list(self._get(
            'qbittorrent', port, '/api/v2/torrents/info', source,
            deadline, gate))
        records, private_records = [], []
        for item in torrents:
            if type(item) is not dict:
                raise MediaArchiveReadCollectorError('media_archive_projection_invalid')
            identifier = item.get('hash')
            if (type(identifier) is not str
                    or re.fullmatch(r'(?:[0-9A-Fa-f]{40}|[0-9A-Fa-f]{64})', identifier) is None):
                raise MediaArchiveReadCollectorError('media_archive_projection_invalid')
            identifier = identifier.lower()
            category = item.get('category')
            if category not in {'movies', 'tv'}:
                raise MediaArchiveReadCollectorError('media_archive_projection_invalid')
            _path(item.get('content_path'), f'/data/downloads/{category}')
            raw_state = item.get('state')
            if raw_state in {'downloading', 'metaDL', 'forcedDL', 'stalledDL',
                             'queuedDL', 'checkingDL', 'allocating'}:
                state = 'downloading'
            elif raw_state in {'uploading', 'forcedUP', 'stalledUP', 'queuedUP',
                               'checkingUP'}:
                state = 'seeding'
            elif raw_state == 'pausedUP':
                state = 'paused'
            elif raw_state in {'stoppedUP', 'completed'}:
                state = 'complete'
            elif raw_state in {'error', 'missingFiles'}:
                state = 'error'
            else:
                raise MediaArchiveReadCollectorError('media_archive_projection_invalid')
            size = _integer(item.get('total_size'))
            ratio = item.get('ratio')
            max_ratio = item.get('max_ratio')
            seeding = item.get('seeding_time')
            max_seeding = item.get('max_seeding_time')
            if (type(ratio) not in (int, float) or type(ratio) is bool
                    or type(max_ratio) not in (int, float) or type(max_ratio) is bool
                    or type(seeding) is not int or type(seeding) is bool
                    or type(max_seeding) is not int or type(max_seeding) is bool):
                raise MediaArchiveReadCollectorError('media_archive_projection_invalid')
            media_key = imports.get(identifier)
            imported = media_key is not None
            retention = bool(
                state == 'complete' and imported and (
                    max_ratio >= 0 and ratio >= max_ratio
                    or max_seeding >= 0 and seeding >= max_seeding))
            records.append({
                'torrentId': identifier, 'mediaKey': media_key,
                'title': _name(item.get('name')), 'contentBytes': size,
                'state': state, 'importedConfirmed': imported,
                'retentionPolicySatisfied': retention,
            })
            private_records.append(AuthenticatedArchiveTorrent(
                torrentId=identifier, importedMediaKey=media_key,
                contentPath=item['content_path'], contentBytes=size,
                state=state, importedConfirmed=imported,
                retentionPolicySatisfied=retention))
        return proof, records, private_records

    def _jellyfin_records(self, value, path_keys):
        if (type(value) is not dict or set(value) < {
                'Items', 'TotalRecordCount', 'StartIndex'}
                or value.get('StartIndex') != 0
                or type(value.get('Items')) is not list
                or value.get('TotalRecordCount') != len(value['Items'])
                or len(value['Items']) > _MAX_ITEMS):
            raise MediaArchiveReadCollectorError('media_archive_projection_invalid')
        records, private_records, cleanup_records = [], [], []
        for item in value['Items']:
            if type(item) is not dict or item.get('Type') not in {'Movie', 'Episode'}:
                raise MediaArchiveReadCollectorError('media_archive_projection_invalid')
            item_id = item.get('Id')
            if type(item_id) is not str or re.fullmatch(r'[0-9a-f]{32}', item_id) is None:
                raise MediaArchiveReadCollectorError('media_archive_projection_invalid')
            relative_path = _path(item.get('Path'), '/media')
            arr = path_keys.get(relative_path)
            if arr is None:
                raise MediaArchiveReadCollectorError('media_archive_projection_invalid')
            key = arr.media_key
            sources = item.get('MediaSources')
            if type(sources) is not list or len(sources) != 1 or type(sources[0]) is not dict:
                raise MediaArchiveReadCollectorError('media_archive_projection_invalid')
            media = sources[0]
            size = _integer(media.get('Size'))
            direct = media.get('SupportsDirectPlay') is True or media.get('SupportsDirectStream') is True
            runtime = item.get('RunTimeTicks')
            runtime_seconds = None
            if runtime is not None:
                runtime_seconds = _integer(runtime, 1) // 10_000_000
                if runtime_seconds < 1:
                    raise MediaArchiveReadCollectorError('media_archive_projection_invalid')
            streams = item.get('MediaStreams')
            if type(streams) is not list or len(streams) > 64:
                raise MediaArchiveReadCollectorError('media_archive_projection_invalid')
            video = [stream for stream in streams
                     if type(stream) is dict and stream.get('Type') == 'Video']
            if len(video) != 1:
                raise MediaArchiveReadCollectorError('media_archive_projection_invalid')
            codec, bitrate = video[0].get('Codec'), video[0].get('BitRate')
            codec = {'mpeg2video': 'mpeg2'}.get(codec, codec)
            if (codec not in {'h264', 'mpeg2', 'vc1', 'hevc', 'av1'}
                    or runtime_seconds is None):
                raise MediaArchiveReadCollectorError('media_archive_projection_invalid')
            bitrate = _integer(bitrate, 1, 1_000_000_000)
            records.append({
                'itemId': item_id, 'mediaKey': key,
                'title': _name(item.get('Name')),
                'mediaKind': 'movie' if item['Type'] == 'Movie' else 'episode',
                'sizeBytes': size,
                'integrity': 'playable' if direct else 'unplayable',
                'runtimeSeconds': runtime_seconds,
            })
            cleanup_records.append(AuthenticatedArchiveCleanupItem(
                itemId=item_id, mediaKey=key, sourcePath=item['Path'],
                sourceSizeBytes=size, service=arr.service,
                serviceFileId=arr.file_id, servicePath=arr.path))
            if codec in {'h264', 'mpeg2', 'vc1'}:
                private_records.append(AuthenticatedArchiveSourceRecord(
                    sourceItemId=item_id,
                    mediaKey=key,
                    sourcePath=item['Path'],
                    sourceSizeBytes=size,
                    sourceCodec=codec,
                    sourceBitrate=bitrate,
                    durationSeconds=runtime_seconds,
                ))
        return records, private_records, cleanup_records
