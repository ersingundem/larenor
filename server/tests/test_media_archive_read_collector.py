import json
import time

import pytest

from larenor_server.plugins.media_archive_read_collector import (
    MediaArchiveReadCollector,
    MediaArchiveReadCollectorError,
)
from test_media_archive_core_read import NOW, authority
from test_media_archive_worker_ipc import private


class Transport:
    def __init__(self, values):
        self.values = values
        self.calls = []

    def get(self, service, port, path, api_key, *, deadline, gate, text=False):
        assert time.monotonic() < deadline and gate() is True
        assert api_key not in repr(self.calls)
        self.calls.append((service, port, path, text))
        for expected_service, prefix, value in self.values:
            if service == expected_service and path.startswith(prefix):
                return value
        raise AssertionError((service, path))


def preferences():
    return {
        'save_path': '/data/downloads', 'temp_path_enabled': True,
        'temp_path': '/data/incomplete', 'listen_port': 6881, 'upnp': False,
        'web_ui_address': '*', 'web_ui_port': 8080, 'web_ui_upnp': False,
        'use_https': False, 'web_ui_username': 'larenor-system',
        'bypass_local_auth': False,
        'bypass_auth_subnet_whitelist_enabled': False,
        'web_ui_domain_list': 'qbittorrent',
        'web_ui_clickjacking_protection_enabled': True,
        'web_ui_csrf_protection_enabled': True,
        'web_ui_secure_cookie_enabled': True,
        'web_ui_host_header_validation_enabled': True,
    }


def routes(*, qbit_state='stoppedUP', jelly_total=2, jelly_path=None):
    movie_hash = 'a' * 40
    episode_hash = 'b' * 40
    return [
        ('jellyfin', '/System/Info', {
            'Id': '2' * 32, 'StartupWizardCompleted': True,
            'ProductName': 'Jellyfin Server', 'ServerName': 'Home',
            'Version': '10.11.11',
        }),
        ('jellyfin', '/Library/VirtualFolders', [
            {'Name': 'Movies', 'Locations': ['/media/movies'],
             'CollectionType': 'movies', 'ItemId': '3' * 32},
            {'Name': 'TV', 'Locations': ['/media/tv'],
             'CollectionType': 'tvshows', 'ItemId': '4' * 32},
        ]),
        ('jellyfin', '/Items?', {
            'Items': [
                {'Id': '5' * 32, 'Type': 'Movie', 'Name': 'Film',
                 'Path': jelly_path or '/media/movies/Film/Film.mkv',
                 'RunTimeTicks': 7_200_000_000,
                 'MediaSources': [{'Size': 8000, 'SupportsDirectPlay': True,
                                   'SupportsDirectStream': True}],
                 'MediaStreams': [{'Type': 'Video', 'Codec': 'h264',
                                   'BitRate': 8_000_000}]},
                {'Id': '6' * 32, 'Type': 'Episode', 'Name': 'Pilot',
                 'Path': '/media/tv/Show/Season 01/Pilot.mkv',
                 'RunTimeTicks': 3_600_000_000,
                 'MediaSources': [{'Size': 4000, 'SupportsDirectPlay': True,
                                   'SupportsDirectStream': False}],
                 'MediaStreams': [{'Type': 'Video', 'Codec': 'hevc',
                                   'BitRate': 4_000_000}]},
            ], 'TotalRecordCount': jelly_total, 'StartIndex': 0,
        }),
        ('sonarr', '/api/v3/system/status', {
            'appName': 'Sonarr', 'version': '4.0.19.2979'}),
        ('sonarr', '/api/v3/series', [
            {'id': 10, 'tvdbId': 101, 'path': '/data/tv/Show'}]),
        ('sonarr', '/api/v3/queue?', {
            'records': [], 'totalRecords': 0}),
        ('sonarr', '/api/v3/episode?', [
            {'id': 11, 'seriesId': 10, 'seasonNumber': 1,
             'episodeNumber': 1, 'title': 'Pilot', 'monitored': True,
             'hasFile': True, 'episodeFile': {
                 'path': '/data/tv/Show/Season 01/Pilot.mkv'}}]),
        ('sonarr', '/api/v3/history?', {
            'records': [{'eventType': 'downloadFolderImported',
                         'downloadId': episode_hash, 'episodeId': 11}],
            'totalRecords': 1}),
        ('radarr', '/api/v3/system/status', {
            'appName': 'Radarr', 'version': '6.3.0.10514'}),
        ('radarr', '/api/v3/movie', [
            {'id': 20, 'tmdbId': 603, 'title': 'Film', 'monitored': True,
             'hasFile': True, 'path': '/data/movies/Film',
             'movieFile': {'path': '/data/movies/Film/Film.mkv'}}]),
        ('radarr', '/api/v3/queue?', {
            'records': [], 'totalRecords': 0}),
        ('radarr', '/api/v3/history?', {
            'records': [{'eventType': 'downloadFolderImported',
                         'downloadId': movie_hash, 'movieId': 20}],
            'totalRecords': 1}),
        ('qbittorrent', '/api/v2/app/version', 'v5.2.3'),
        ('qbittorrent', '/api/v2/app/preferences', preferences()),
        ('qbittorrent', '/api/v2/torrents/categories', {
            'movies': {'name': 'movies', 'savePath': '/data/downloads/movies',
                       'download_path': None},
            'tv': {'name': 'tv', 'savePath': '/data/downloads/tv',
                   'download_path': None},
        }),
        ('qbittorrent', '/api/v2/torrents/info', [
            {'hash': movie_hash, 'name': 'Film download', 'category': 'movies',
             'content_path': '/data/downloads/movies/Film',
             'total_size': 8000, 'state': qbit_state, 'ratio': 2.1,
             'max_ratio': 2.0, 'seeding_time': 200, 'max_seeding_time': -1},
            {'hash': episode_hash, 'name': 'Pilot download', 'category': 'tv',
             'content_path': '/data/downloads/tv/Show',
             'total_size': 4000, 'state': 'uploading', 'ratio': 0.2,
             'max_ratio': 2.0, 'seeding_time': 20, 'max_seeding_time': 3600},
        ]),
    ]


def collect(values):
    transport = Transport(values)
    current = authority(observed=NOW - 1)
    result = MediaArchiveReadCollector(
        transport, clock=lambda: NOW).collect(
            private(current=current), deadline=time.monotonic() + 3,
            gate=lambda: True)
    return result, transport


def test_collects_exact_identities_paths_imports_and_seeding_without_leaking_paths():
    result, transport = collect(routes())

    assert [item.mediaKey for item in result.jellyfin.items] == [
        'movie:tmdb:603', 'episode:tvdb:101:1:1']
    assert result.sonarr.items[0].state == 'available'
    assert result.radarr.items[0].state == 'available'
    assert [(item.state, item.importedConfirmed,
             item.retentionPolicySatisfied) for item in result.qbittorrent.items] == [
        ('complete', True, True), ('seeding', True, False)]
    assert {(service, port) for service, port, _path, _text in transport.calls} == {
        ('jellyfin', 8096), ('sonarr', 8989), ('radarr', 7878),
        ('qbittorrent', 8080)}
    encoded = json.dumps(result.model_dump(mode='json'))
    assert '/data/' not in encoded and '/media/' not in encoded
    assert 'qbt_' not in encoded
    assert all(call[2].startswith('/') for call in transport.calls)


@pytest.mark.parametrize(('values', 'code'), [
    (routes(jelly_total=3), 'media_archive_projection_invalid'),
    (routes(jelly_path='/media/foreign/Film.mkv'),
     'media_archive_projection_invalid'),
    (routes(qbit_state='unknownFutureState'),
     'media_archive_projection_invalid'),
])
def test_partial_unknown_or_unmapped_source_fails_closed(values, code):
    with pytest.raises(MediaArchiveReadCollectorError, match=code) as raised:
        collect(values)
    assert '/data/' not in repr(raised.value)
    assert '/media/' not in repr(raised.value)


def test_identity_drift_and_expired_gate_fail_before_observation():
    values = routes()
    values[0] = values[0][0], values[0][1], values[0][2] | {'Id': 'f' * 32}
    with pytest.raises(MediaArchiveReadCollectorError,
                       match='media_archive_source_drift'):
        collect(values)

    transport = Transport(routes())
    with pytest.raises(MediaArchiveReadCollectorError,
                       match='media_archive_deadline_exceeded'):
        MediaArchiveReadCollector(transport, clock=lambda: NOW).collect(
            private(current=authority(observed=NOW - 1)),
            deadline=time.monotonic() + 3, gate=lambda: False)
    assert transport.calls == []
