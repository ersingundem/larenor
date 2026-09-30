import base64
import hashlib

from conftest import auth, login
from larenor_server.plugins.media_playback_models import (
    OfflineMediaChunkReadback,
)
from test_media_archive_core_read import configured


BASE = '/api/v1/media/offline'
CONTENT = b'eightbyt'
DIGEST = hashlib.sha256(CONTENT).hexdigest()


class ChunkWorker:
    def __init__(self, change=None):
        self.change = change
        self.calls = []

    def read_offline_media_chunk(
            self, authority, *, request_id, offset, length, deadline, gate):
        assert deadline > 0 and gate() is True
        self.calls.append((authority, request_id, offset, length))
        if self.change is not None:
            self.change()
        # Return a partial first read to exercise durable resume.
        size = min(length, 4)
        return OfflineMediaChunkReadback(
            itemId=authority.itemId,
            offset=offset,
            contentLength=len(CONTENT),
            contentType='video/mp4',
            dataBase64=base64.b64encode(CONTENT[offset:offset + size]).decode(),
        )


def setup(server, worker=None):
    app, _client, _, _clock = server
    pair, installation, current, _reader, archive, _body = configured(server)
    jellyfin = archive.result.jellyfin
    item = jellyfin.items[0].model_copy(update={
        'sizeBytes': len(CONTENT),
        'contentHash': DIGEST,
    })
    archive.result = archive.result.model_copy(update={
        'jellyfin': jellyfin.model_copy(update={'items': [item]}),
    })
    worker = worker or ChunkWorker()
    app.state.core.media_playback.backend = worker
    return pair, installation, current, worker


def create_body(installation, current, request_id='a' * 32):
    jellyfin = next(
        source for source in current.sources if source.serviceId == 'jellyfin')
    return {
        'schemaVersion': 1,
        'requestId': request_id,
        'installationId': installation['id'],
        'expectedInstallationRevision': installation['revision'],
        'expectedSnapshotRevision': current.snapshotRevision,
        'expectedJellyfinServiceRevision': jellyfin.serviceRevision,
        'itemId': 'b' * 32,
        'mediaKey': 'movie:tmdb:603',
        'expiresAt': 1788613200,
        'storageQuotaBytes': 64 * 1024 * 1024,
        'storageAvailableBytes': 64 * 1024 * 1024,
    }


def test_create_resume_complete_revoke_crosses_http_core_and_worker(server):
    pair, installation, current, worker = setup(server)
    client = server[1]
    body = create_body(installation, current)

    created = client.post(BASE + '/grants', headers=auth(pair), json=body)
    replay = client.post(BASE + '/grants', headers=auth(pair), json=body)
    assert created.status_code == 201, created.text
    assert replay.status_code == 201 and replay.json() == created.json()
    manifest = created.json()['manifest']
    assert manifest['grantId'] == 'a' * 32
    assert manifest['revision'] == 1
    assert manifest['contentLength'] == len(CONTENT)
    assert manifest['contentSha256'] == DIGEST
    assert manifest['chunkBytes'] == 32 * 1024
    assert manifest['downloadedBytes'] == 0
    assert manifest['state'] == 'granted'

    first = client.post(
        BASE + f"/grants/{manifest['grantId']}/chunk",
        headers=auth(pair),
        json={'schemaVersion': 1, 'requestId': 'b' * 32,
              'expectedRevision': 1, 'offset': 0},
    )
    assert first.status_code == 200 and first.content == CONTENT[:4]
    assert first.headers['x-larenor-content-sha256'] == DIGEST
    progress = client.post(
        BASE + f"/grants/{manifest['grantId']}/progress",
        headers=auth(pair),
        json={'schemaVersion': 1, 'requestId': 'c' * 32,
              'expectedRevision': 1, 'downloadedBytes': 4,
              'contentSha256': None},
    )
    assert progress.status_code == 200, progress.text
    assert progress.json()['manifest']['revision'] == 2
    assert progress.json()['manifest']['state'] == 'transferring'

    resumed = client.get(
        BASE + f"/grants/{manifest['grantId']}", headers=auth(pair))
    assert resumed.status_code == 200
    assert resumed.json()['manifest']['downloadedBytes'] == 4
    second = client.post(
        BASE + f"/grants/{manifest['grantId']}/chunk",
        headers=auth(pair),
        json={'schemaVersion': 1, 'requestId': 'd' * 32,
              'expectedRevision': 2, 'offset': 4},
    )
    assert second.status_code == 200 and second.content == CONTENT[4:]
    complete = client.post(
        BASE + f"/grants/{manifest['grantId']}/progress",
        headers=auth(pair),
        json={'schemaVersion': 1, 'requestId': 'e' * 32,
              'expectedRevision': 2, 'downloadedBytes': len(CONTENT),
              'contentSha256': DIGEST},
    )
    assert complete.status_code == 200, complete.text
    assert complete.json()['manifest']['state'] == 'complete'
    assert complete.json()['manifest']['revision'] == 3

    revoked = client.post(
        BASE + f"/grants/{manifest['grantId']}/revoke",
        headers=auth(pair),
        json={'schemaVersion': 1, 'requestId': 'f' * 32,
              'expectedRevision': 3},
    )
    assert revoked.status_code == 200
    assert revoked.json()['manifest']['state'] == 'revoked'
    assert [(call[2], call[3]) for call in worker.calls] == [(0, 8), (4, 4)]


def test_quota_family_expiry_and_late_worker_result_fail_closed(server):
    app, client, _, clock = server
    pair, installation, current, worker = setup(server)
    body = {
        **create_body(installation, current),
        'expiresAt': 1788609900,
    }

    quota = client.post(
        BASE + '/grants', headers=auth(pair),
        json={**body, 'requestId': '9' * 32, 'storageAvailableBytes': 4},
    )
    assert quota.status_code == 409
    assert quota.json()['error']['code'] == 'offline_media_unavailable'
    created = client.post(BASE + '/grants', headers=auth(pair), json=body)
    assert created.status_code == 201
    grant = created.json()['manifest']['grantId']
    retained_body = {
        **body,
        'requestId': '7' * 32,
        'expiresAt': 1788610200,
    }
    retained = client.post(
        BASE + '/grants', headers=auth(pair), json=retained_body)
    assert retained.status_code == 201
    retained_grant = retained.json()['manifest']['grantId']

    other_family = login(
        client, 'admin', 'Synthetic new password 2026',
        device='Other travel tablet').json()
    hidden = client.get(BASE + f'/grants/{grant}', headers=auth(other_family))
    assert hidden.status_code == 404

    clock.now = 1788609900
    expired = client.get(BASE + f'/grants/{grant}', headers=auth(pair))
    assert expired.status_code == 409
    assert expired.json()['error']['code'] == 'offline_media_authority_changed'

    def change_actor_revision():
        with app.state.core.db.transaction() as connection:
            connection.execute(
                'UPDATE users SET revision=revision+1 WHERE id=?',
                (pair['user']['id'],),
            )

    worker.change = change_actor_revision
    late = client.post(
        BASE + f'/grants/{retained_grant}/chunk', headers=auth(pair),
        json={'schemaVersion': 1, 'requestId': '8' * 32,
              'expectedRevision': 1, 'offset': 0},
    )
    assert late.status_code == 503
    assert late.json()['error']['code'] == 'media_playback_worker_unavailable'
    assert len(worker.calls) == 1
