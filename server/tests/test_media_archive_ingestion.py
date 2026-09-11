import json

import pytest

from larenor_server.plugins.arr_authenticated_readback import (
    ArrAuthenticatedReadbackResult,
)
from larenor_server.plugins.jellyfin_authenticated_readback import (
    JellyfinAuthenticatedReadbackResult,
)
from larenor_server.plugins.media_archive_health import build_media_archive_health
from larenor_server.plugins.media_archive_health_models import ArchiveSourceBinding
from larenor_server.plugins.media_archive_ingestion import (
    MediaArchiveIngestion,
    MediaArchiveIngestionError,
)
from larenor_server.plugins.qbittorrent_authenticated_readback import (
    QbittorrentAuthenticatedReadbackResult,
)
from larenor_server.plugins.qbittorrent_readback import QbittorrentReadback


NOW = 1_788_609_610
INSTALLATION = '1' * 32
SERVER_ID = '2' * 32


def binding(service, *, observed=NOW - 10, snapshot=4):
    return ArchiveSourceBinding(
        serviceId=service,
        serviceRecordId={
            'jellyfin': '6', 'sonarr': '7', 'radarr': '8', 'qbittorrent': '9',
        }[service] * 32,
        serviceRevision={'jellyfin': 8, 'sonarr': 9, 'radarr': 10,
                         'qbittorrent': 11}[service],
        snapshotRevision=snapshot,
        installationId=INSTALLATION,
        installationRevision=12,
        state='verified', observedAt=observed,
    )


def jellyfin(secret='jellyfin-private-api-key'):
    return JellyfinAuthenticatedReadbackResult(
        state='verified', server_id=SERVER_ID, server_name='Larenor Jellyfin',
        version='10.11.11', api_key=secret,
        libraries=(('Movies', 'movies', 'a' * 32, ('/media/movies',)),),
        completed_steps=('authenticated', 'keys_observed', 'key_verified',
                         'system_verified', 'libraries_verified',
                         'session_closed'),
    )


def arr(service):
    return ArrAuthenticatedReadbackResult(
        state='verified', service_id=service,
        app_name='Sonarr' if service == 'sonarr' else 'Radarr',
        version='4.0.19.2979' if service == 'sonarr' else '6.3.0.10514',
    )


def qbittorrent():
    return QbittorrentAuthenticatedReadbackResult(
        state='verified', version='v5.2.3',
        settings=QbittorrentReadback(
            state='verified', username='larenor-system', web_port=8080,
            torrent_port=6881, download_path='/data/downloads',
            incomplete_path='/data/incomplete',
            categories=(('movies', '/data/downloads/movies'),
                        ('tv', '/data/downloads/tv')),
        ),
        completed_steps=('version_verified', 'preferences_verified',
                         'categories_verified'),
    )


def projections():
    return {
        'jellyfin': [{
            'itemId': 'b' * 32, 'mediaKey': 'movie:tmdb:603',
            'title': 'The Matrix', 'mediaKind': 'movie', 'sizeBytes': 8_000,
            'integrity': 'playable',
        }],
        'sonarr': [{
            'mediaKey': 'episode:tvdb:101:1:3', 'title': 'Third episode',
            'mediaKind': 'episode', 'monitored': True, 'state': 'missing',
        }],
        'radarr': [{
            'mediaKey': 'movie:tmdb:603', 'title': 'The Matrix',
            'mediaKind': 'movie', 'monitored': True, 'state': 'available',
        }],
        'qbittorrent': [{
            'torrentId': 'c' * 40, 'mediaKey': 'movie:tmdb:603',
            'title': 'The Matrix download', 'contentBytes': 4_000,
            'state': 'complete', 'importedConfirmed': True,
            'retentionPolicySatisfied': True,
        }],
    }


def ingested():
    values = projections()
    adapter = MediaArchiveIngestion()
    return adapter.assemble(
        jellyfin=adapter.jellyfin(
            binding('jellyfin'), jellyfin(), values['jellyfin'],
            expected_server_id=SERVER_ID, now=NOW),
        sonarr=adapter.arr(
            binding('sonarr'), arr('sonarr'), values['sonarr'], now=NOW),
        radarr=adapter.arr(
            binding('radarr'), arr('radarr'), values['radarr'], now=NOW),
        qbittorrent=adapter.qbittorrent(
            binding('qbittorrent'), qbittorrent(), values['qbittorrent'],
            now=NOW),
    )


def test_verified_readbacks_ingest_into_common_health_without_secrets_or_paths():
    result = build_media_archive_health(ingested(), now=NOW)
    assert result.state == 'attention'
    assert result.counts.missing == 1
    assert result.counts.potentialSavingBytes == 4_000
    wire = json.dumps(result.model_dump(mode='json'))
    assert 'jellyfin-private-api-key' not in wire
    assert '/data/' not in wire and '/media/' not in wire


@pytest.mark.parametrize(('service', 'readback'), [
    ('jellyfin', jellyfin()),
    ('sonarr', arr('radarr')),
    ('radarr', arr('sonarr')),
    ('qbittorrent', qbittorrent()),
])
def test_service_identity_drift_fails_closed(service, readback):
    adapter = MediaArchiveIngestion()
    selected = binding(service)
    if service == 'jellyfin':
        selected = selected.model_copy(update={'serviceId': 'sonarr'})
        call = lambda: adapter.jellyfin(
            selected, readback, [], expected_server_id=SERVER_ID, now=NOW)
    elif service in {'sonarr', 'radarr'}:
        call = lambda: adapter.arr(selected, readback, [], now=NOW)
    else:
        selected = selected.model_copy(update={'serviceId': 'radarr'})
        call = lambda: adapter.qbittorrent(selected, readback, [], now=NOW)
    with pytest.raises(MediaArchiveIngestionError, match='archive_source_drift'):
        call()


def test_jellyfin_server_identity_and_authenticated_completion_are_exact():
    adapter = MediaArchiveIngestion()
    with pytest.raises(MediaArchiveIngestionError, match='archive_source_drift'):
        adapter.jellyfin(
            binding('jellyfin'), jellyfin(), [],
            expected_server_id='f' * 32, now=NOW)
    partial = jellyfin()
    object.__setattr__(partial, 'completed_steps', ('authenticated',))
    with pytest.raises(MediaArchiveIngestionError, match='archive_source_drift'):
        adapter.jellyfin(
            binding('jellyfin'), partial, [],
            expected_server_id=SERVER_ID, now=NOW)


def test_qbittorrent_config_drift_never_reaches_archive_projection():
    adapter = MediaArchiveIngestion()
    readback = qbittorrent()
    object.__setattr__(readback.settings, 'categories',
                      (('movies', '/foreign/path'),))
    with pytest.raises(MediaArchiveIngestionError, match='archive_source_drift'):
        adapter.qbittorrent(
            binding('qbittorrent'), readback, [], now=NOW)


@pytest.mark.parametrize('record', [
    {'itemId': 'b' * 32, 'mediaKey': 'movie:tmdb:603', 'title': 'Movie',
     'mediaKind': 'movie', 'sizeBytes': 1, 'integrity': 'playable',
     'token': 'secret'},
    {'itemId': 'b' * 32, 'mediaKey': 'movie:tmdb:603', 'title': 'Movie',
     'mediaKind': 'movie', 'sizeBytes': 1},
])
def test_projection_schema_drift_or_missing_field_is_secret_free(record):
    adapter = MediaArchiveIngestion()
    with pytest.raises(MediaArchiveIngestionError) as raised:
        adapter.jellyfin(
            binding('jellyfin'), jellyfin(), [record],
            expected_server_id=SERVER_ID, now=NOW)
    assert str(raised.value) == 'archive_projection_invalid'
    assert 'secret' not in repr(raised.value)


def test_duplicate_stale_and_cross_snapshot_data_fail_before_aggregation():
    adapter = MediaArchiveIngestion()
    item = projections()['jellyfin'][0]
    with pytest.raises(MediaArchiveIngestionError, match='archive_projection_invalid'):
        adapter.jellyfin(
            binding('jellyfin'), jellyfin(), [item, item],
            expected_server_id=SERVER_ID, now=NOW)
    with pytest.raises(MediaArchiveIngestionError, match='archive_source_stale'):
        adapter.jellyfin(
            binding('jellyfin', observed=NOW - 301), jellyfin(), [],
            expected_server_id=SERVER_ID, now=NOW)

    observation = ingested()
    with pytest.raises(MediaArchiveIngestionError,
                       match='archive_authority_changed'):
        adapter.assemble(
            jellyfin=observation.jellyfin,
            sonarr=observation.sonarr.model_copy(
                update={'snapshotRevision': 5}),
            radarr=observation.radarr,
            qbittorrent=observation.qbittorrent,
        )
