import asyncio
from dataclasses import replace
import hashlib
import json
import os
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from starlette.requests import ClientDisconnect, Request

from conftest import Clock, auth, bootstrap_password, login, ready
from larenor_server.app import create_app
from larenor_server.config import Settings
from larenor_server.errors import ApiError, StartupError
from larenor_server.releases import ReleaseSettings, ReleaseService, build_release_router
from larenor_server.releases.models import validate_manifest

TOKEN = 'lpub_' + 'P' * 43
PIN = 'a' * 64
APK = b'bounded synthetic APK content, never executable'
PREFIX = '/api/v1/client/releases'
HEADERS = {'Authorization': 'Bearer ' + TOKEN}


def manifest(version=20, content=APK, **changes):
    result = dict(schemaVersion=1, applicationId='com.ersingundem.larenor', versionCode=version,
                  versionName='2.0', certificateSha256=PIN, apkSha256=hashlib.sha256(content).hexdigest(),
                  sizeBytes=len(content), minSdk=26, commit='b' * 40,
                  downloadPath=f'{PREFIX}/{version}/apk', publishedAt='2026-09-05T12:00:00Z', releaseNotes='Fixture release')
    result.update(changes)
    return result


class Verifier:
    def __init__(self):
        self.calls = 0
        self.overrides = {}
        self.error = None
        self.after = lambda: None
        self.version = 20

    def verify(self, path):
        self.calls += 1
        assert path.read_bytes() == APK
        self.after()
        if self.error:
            raise self.error
        return dict(schemaVersion=1, verified=True, applicationId='com.ersingundem.larenor',
                    versionCode=self.version, versionName='2.0', minSdk=26,
                    certificateSha256=PIN, debuggable=False) | self.overrides


@pytest.fixture
def release_server(tmp_path):
    root = tmp_path.resolve()
    clock = Clock()
    verifier = Verifier()
    release_settings = ReleaseSettings(root / 'releases', signer_sha256=PIN, publisher_token=TOKEN, clock=clock)
    service = ReleaseService(release_settings, verifier=verifier)
    settings = Settings(root / 'data', root / 'secrets/vault.key', clock=clock,
                        login_ip_limit=100, login_account_limit=100, login_global_limit=100)
    app = create_app(settings, routers=(build_release_router(service),))
    with TestClient(app) as client:
        yield app, client, settings, clock, service, verifier


def prepared(fixture, version=20):
    _, client, _, _, _, verifier = fixture
    verifier.version = version
    response = client.put(f'{PREFIX}/{version}', headers=HEADERS, json=manifest(version))
    assert response.status_code == 201, response.text
    identifier = response.json()['uploadId']
    response = client.put(f'{PREFIX}/{version}/uploads/{identifier}/apk', headers=HEADERS | {'Content-Type': 'application/octet-stream'}, content=APK)
    assert response.status_code == 200, response.text
    return identifier


def published(fixture, version=20):
    identifier = prepared(fixture, version)
    response = fixture[1].post(f'{PREFIX}/{version}/uploads/{identifier}/finalize', headers=HEADERS)
    assert response.status_code == 200, response.text
    return response.json()


def test_three_phases_require_independent_publisher_and_ready_read_account(release_server):
    app, client, settings, clock, service, verifier = release_server
    initial = login(client, 'admin', bootstrap_password(settings)).json()
    assert client.get(f'{PREFIX}/latest').status_code == 401
    assert client.get(f'{PREFIX}/latest', headers=HEADERS).status_code == 401
    assert client.get(f'{PREFIX}/latest', headers=auth(initial)).status_code == 403
    pair = ready((app, client, settings, clock))
    assert client.get(f'{PREFIX}/latest', headers=auth(pair)).status_code == 204
    assert client.put(f'{PREFIX}/20', headers=auth(pair), json=manifest()).status_code == 401
    assert client.put(f'{PREFIX}/20', json=manifest()).status_code == 401
    body = published(release_server)
    response = client.get(f'{PREFIX}/latest?platform=android&channel=stable', headers=auth(pair))
    assert response.json() == body == manifest()
    assert response.headers['cache-control'] == 'no-store'
    assert verifier.calls == 1
    assert client.get(f'{PREFIX}/latest?platform=ios', headers=auth(pair)).status_code == 400
    assert client.get(body['downloadPath']).status_code == 401
    apk = client.get(body['downloadPath'], headers=auth(pair))
    assert apk.content == APK
    assert apk.headers['content-length'] == str(len(APK))
    assert apk.headers['content-type'] == 'application/vnd.android.package-archive'
    for directory in (service.root, service.staging, service.versions, service.versions / '20'):
        assert directory.stat().st_mode & 0o777 == 0o700
    assert all(path.stat().st_mode & 0o777 == 0o600 for path in service.versions.rglob('*') if path.is_file())


def test_immutable_idempotency_rejects_conflict_and_downgrade(release_server):
    client = release_server[1]
    original = published(release_server)
    retry = client.put(f'{PREFIX}/20', headers=HEADERS, json=manifest(releaseNotes='cannot rewrite published notes'))
    assert retry.status_code == 200
    assert retry.json() == {'state': 'published', 'release': original}
    assert client.put(f'{PREFIX}/20', headers=HEADERS, json=manifest(content=b'other')).status_code == 409
    assert client.put(f'{PREFIX}/19', headers=HEADERS, json=manifest(19)).status_code == 409
    assert release_server[5].calls == 1


def test_pending_rerun_resumes_only_matching_uploaded_stage(release_server):
    client = release_server[1]
    response = client.put(f'{PREFIX}/20', headers=HEADERS, json=manifest())
    identifier = response.json()['uploadId']
    again = client.put(f'{PREFIX}/20', headers=HEADERS, json=manifest()).json()
    assert again['uploadId'] == identifier and again['state'] == 'awaitingUpload'
    assert client.put(f'{PREFIX}/21', headers=HEADERS, json=manifest(21)).status_code == 409
    assert client.put(f'{PREFIX}/20', headers=HEADERS, json=manifest(content=b'wrong')).status_code == 409
    assert client.post(f'{PREFIX}/20/uploads/{identifier}/finalize', headers=HEADERS).status_code == 409
    assert client.put(f'{PREFIX}/20/uploads/{identifier}/apk', headers=HEADERS | {'Content-Type': 'application/octet-stream'}, content=APK).status_code == 200
    assert client.put(f'{PREFIX}/20', headers=HEADERS, json=manifest()).json()['state'] == 'uploaded'
    assert client.put(f'{PREFIX}/20/uploads/{identifier}/apk', headers=HEADERS | {'Content-Type': 'application/octet-stream'}, content=APK).status_code == 409


@pytest.mark.parametrize('changes', [dict(schemaVersion=True), dict(versionCode=True), dict(versionCode=2147483648),
    dict(sizeBytes=536870913), dict(sizeBytes=True), dict(minSdk=25), dict(applicationId='other.app'),
    dict(downloadPath='https://trap.invalid/app.apk'), dict(downloadPath='/api/v1/client/releases/20/%2e%2e/apk'),
    dict(publishedAt='2026-09-05T12:00:00'), dict(commit='z' * 40), dict(releaseNotes='x' * 12001),
    dict(releaseNotes='\ud800'), dict(versionName='\udfff'), dict(extra=1)])
def test_manifest_is_strict(changes):
    with pytest.raises(ApiError):
        validate_manifest(manifest(**changes))


@pytest.mark.parametrize('changes', [dict(certificateSha256='c' * 64), dict(applicationId='other.app'),
    dict(versionCode=19), dict(versionName='different'), dict(minSdk=25), dict(debuggable=True), dict(verified=False)])
def test_real_verification_identity_rejection_cleans_upload(release_server, changes):
    identifier = prepared(release_server)
    service, verifier = release_server[4:]
    verifier.overrides = changes
    response = release_server[1].post(f'{PREFIX}/20/uploads/{identifier}/finalize', headers=HEADERS)
    assert response.status_code == 422
    assert response.json()['error']['code'] == 'release_verification_failed'
    assert service.latest() is None
    assert list(service.staging.iterdir()) == []
    assert list(service.versions.iterdir()) == []


def test_missing_verifier_and_postverification_expiry_fail_closed(release_server):
    _, client, _, clock, service, verifier = release_server
    service.verifier = None
    assert client.put(f'{PREFIX}/20', headers=HEADERS, json=manifest()).status_code == 503
    service.verifier = verifier
    identifier = prepared(release_server)
    verifier.error = ApiError('release_verifier_unavailable', 503)
    assert client.post(f'{PREFIX}/20/uploads/{identifier}/finalize', headers=HEADERS).status_code == 503
    assert (service.staging / identifier / 'client.apk').exists()
    verifier.error = None
    verifier.after = lambda: setattr(clock, 'now', clock.now + 901)
    assert client.post(f'{PREFIX}/20/uploads/{identifier}/finalize', headers=HEADERS).status_code == 409
    assert service.latest() is None
    assert not list(service.staging.iterdir())


def stream_request(messages, *, headers=()):
    async def receive():
        if not messages:
            return {'type': 'http.disconnect'}
        value = messages.pop(0)
        if isinstance(value, float):
            await asyncio.sleep(value)
            return {'type': 'http.request', 'body': APK, 'more_body': False}
        return value
    return Request({'type': 'http', 'method': 'PUT', 'path': '/', 'headers': list(headers)}, receive)


@pytest.mark.parametrize('mode', ['hash', 'short', 'overflow', 'disconnect', 'timeout'])
def test_stream_failures_leave_no_partial_or_published_file(release_server, mode):
    service = release_server[4]
    service.settings = replace(service.settings, upload_timeout_seconds=.01)
    _, stage = service.initialize(20, manifest())
    if mode == 'timeout':
        messages = [.1]
    elif mode == 'disconnect':
        messages = [{'type': 'http.request', 'body': APK[:3], 'more_body': True}, {'type': 'http.disconnect'}]
    else:
        content = dict(hash=b'x' * len(APK), short=APK[:-1], overflow=APK + b'x')[mode]
        messages = [{'type': 'http.request', 'body': content, 'more_body': False}]
    request = stream_request(messages, headers=[(b'content-type', b'application/octet-stream')])
    with pytest.raises((ApiError, ClientDisconnect)):
        asyncio.run(service.receive_upload(20, stage['uploadId'], request))
    assert not list(service.staging.iterdir())
    assert not list(service.versions.iterdir())
    assert service.latest() is None


def test_upload_auth_does_not_read_any_body(release_server):
    app = release_server[0]
    async def run():
        calls = 0
        sent = []
        async def receive():
            nonlocal calls
            calls += 1
            raise AssertionError('Unauthenticated APK body must never be read')
        async def send(message):
            sent.append(message)
        scope = {'type': 'http', 'asgi': {'version': '3.0'}, 'http_version': '1.1', 'method': 'PUT',
                 'scheme': 'http', 'path': f'{PREFIX}/20/uploads/8a4baaad-04de-4a3a-a72e-a8078ce2a144/apk',
                 'raw_path': b'/', 'root_path': '', 'query_string': b'',
                 'headers': [(b'host', b'testserver'), (b'content-type', b'application/octet-stream')],
                 'client': ('127.0.0.1', 1), 'server': ('testserver', 80)}
        await app(scope, receive, send)
        assert calls == 0
        assert next(item['status'] for item in sent if item['type'] == 'http.response.start') == 401
    asyncio.run(run())


def test_boundary_no_near_route_bypass_or_duplicate_json(release_server):
    client = release_server[1]
    assert client.put(f'{PREFIX}/20/uploads/not-a-uuid/apk', content=b'x' * 8193, headers=HEADERS).status_code == 413
    assert client.put(f'{PREFIX}/20', content='{"a":1,"a":2}', headers=HEADERS | {'Content-Type': 'application/json'}).status_code == 400
    response = client.put(f'{PREFIX}/20/uploads/8a4baaad-04de-4a3a-a72e-a8078ce2a144/apk', content=b'',
                          headers=[('Content-Length', '0'), ('Content-Length', '0')])
    assert response.status_code == 400


def test_retention_keeps_open_reader_and_crash_pointer_recovers(release_server):
    service = release_server[4]
    published(release_server, 20)
    _, opened = service.open_apk(20)
    try:
        for version in (21, 22, 23):
            published(release_server, version)
        assert sorted(path.name for path in service.versions.iterdir()) == ['21', '22', '23']
        assert opened.read() == APK
    finally:
        opened.close()
    service.index.unlink()
    recovered = ReleaseService(service.settings, verifier=release_server[5])
    assert recovered.latest()['versionCode'] == 23


def test_tampered_file_before_finalize_rejected_and_cleaned(release_server):
    identifier = prepared(release_server)
    service = release_server[4]
    (service.staging / identifier / 'client.apk').write_bytes(b'x' * len(APK))
    assert release_server[1].post(f'{PREFIX}/20/uploads/{identifier}/finalize', headers=HEADERS).status_code == 422
    assert not list(service.staging.iterdir())
    assert release_server[5].calls == 0


def test_private_credential_permissions_and_symlink_rejected(release_server, tmp_path):
    service = release_server[4]
    token = tmp_path.resolve() / 'publish-token'
    token.write_text(TOKEN + '\n')
    token.chmod(0o600)
    service.settings = replace(service.settings, publisher_token=None, publisher_token_file=token)
    service.authorize_publish(TOKEN)
    token.chmod(0o644)
    with pytest.raises(ApiError, match='server_unavailable'):
        service.authorize_publish(TOKEN)
    token.chmod(0o600)
    link = token.with_name('link')
    link.symlink_to(token)
    service.settings = replace(service.settings, publisher_token_file=link)
    with pytest.raises(ApiError, match='server_unavailable'):
        service.authorize_publish(TOKEN)


def test_expired_upload_removed_before_new_reservation(release_server):
    _, client, _, clock, service, _ = release_server
    old = client.put(f'{PREFIX}/20', json=manifest(), headers=HEADERS).json()
    clock.now += 901
    new = client.put(f'{PREFIX}/20', json=manifest(), headers=HEADERS)
    assert new.status_code == 201 and new.json()['uploadId'] != old['uploadId']
    assert not (service.staging / old['uploadId']).exists()


def test_concurrent_upload_is_single_flight_and_later_version_wins(release_server):
    service, verifier = release_server[4:]
    service.settings = replace(service.settings, max_active=2)
    older = prepared(release_server, 20)
    with service._upload_lock(service.staging / older):
        with pytest.raises(ApiError, match='release_conflict'):
            service.finalize(20, older)
    published(release_server, 21)
    verifier.version = 20
    with pytest.raises(ApiError, match='release_conflict'):
        service.finalize(20, older)
    assert service.latest()['versionCode'] == 21
    assert not list(service.staging.iterdir())


def test_process_interruption_after_verified_rename_recovers_pointer(release_server, monkeypatch):
    import larenor_server.releases.store as store
    service = release_server[4]
    identifier = prepared(release_server)
    original_write = store._json_write
    def interrupted(path, value):
        if path == service.index:
            raise OSError('synthetic interrupted fsync')
        original_write(path, value)
    monkeypatch.setattr(store, '_json_write', interrupted)
    with pytest.raises(OSError):
        service.finalize(20, identifier)
    assert (service.versions / '20' / 'client.apk').exists()
    assert not list(service.staging.iterdir())
    monkeypatch.setattr(store, '_json_write', original_write)
    recovered = ReleaseService(service.settings, verifier=release_server[5])
    assert recovered.latest() == manifest()
    assert release_server[5].calls == 1


def test_explicit_rerun_repairs_committed_version_without_restart(release_server, monkeypatch):
    import larenor_server.releases.store as store
    service = release_server[4]
    identifier = prepared(release_server)
    original_write = store._json_write
    def interrupted(path, value):
        if path == service.index:
            raise OSError('synthetic interrupted latest update')
        original_write(path, value)
    monkeypatch.setattr(store, '_json_write', interrupted)
    with pytest.raises(OSError):
        service.finalize(20, identifier)
    monkeypatch.setattr(store, '_json_write', original_write)
    status, response = service.initialize(20, manifest())
    assert status == 200 and response['state'] == 'published'
    assert service.latest() == manifest()
    assert release_server[5].calls == 1


def test_disk_reservation_checks_actual_retained_plus_declared_upload(release_server, monkeypatch):
    service = release_server[4]
    class Full:
        f_bavail = 1
        f_frsize = 4096
    monkeypatch.setattr(os, 'statvfs', lambda _: Full())
    with pytest.raises(ApiError, match='release_capacity'):
        service.initialize(20, manifest())
    assert not list(service.staging.iterdir())


def test_cancelled_upload_releases_lock_and_removes_partial(release_server):
    service = release_server[4]
    _, stage = service.initialize(20, manifest())
    async def exercise():
        started = asyncio.Event()
        async def receive():
            started.set()
            await asyncio.sleep(10)
            return {'type': 'http.disconnect'}
        request = Request({'type': 'http', 'method': 'PUT', 'path': '/',
                           'headers': [(b'content-type', b'application/octet-stream')]}, receive)
        task = asyncio.create_task(service.receive_upload(20, stage['uploadId'], request))
        await started.wait()
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task
    asyncio.run(exercise())
    assert not list(service.staging.iterdir())
    assert service.initialize(20, manifest())[0] == 201


def test_unicode_notes_roundtrip_within_metadata_storage_bound(release_server):
    service = release_server[4]
    expected = manifest(releaseNotes='🎵' * 12000)
    _, stage = service.initialize(20, expected)
    assert (service.staging / stage['uploadId'] / 'request.json').stat().st_size < 65536
    request = stream_request([{'type': 'http.request', 'body': APK, 'more_body': False}],
                             headers=[(b'content-type', b'application/octet-stream')])
    asyncio.run(service.receive_upload(20, stage['uploadId'], request))
    assert service.finalize(20, stage['uploadId']) == expected
    assert service.latest() == expected


def test_interrupted_cleanup_and_initialization_recover_only_managed_trash(release_server, monkeypatch):
    service = release_server[4]
    published(release_server)
    _, pending = service.initialize(21, manifest(21))
    original_unlink = Path.unlink
    def fail_cleanup(path, *args, **kwargs):
        if service.trash in path.parents:
            raise OSError('synthetic crash during unlink')
        original_unlink(path, *args, **kwargs)
    monkeypatch.setattr(Path, 'unlink', fail_cleanup)
    with pytest.raises(OSError):
        service._remove_directory(service.staging / pending['uploadId'])
    assert not list(service.staging.iterdir())
    assert list(service.trash.iterdir())
    monkeypatch.setattr(Path, 'unlink', original_unlink)
    partial = service.staging / '8a4baaad-04de-4a3a-a72e-a8078ce2a144'
    partial.mkdir(mode=0o700)
    (partial / '.lock').touch(mode=0o600)
    unrelated = service.root / 'operator-document.txt'
    unrelated.write_text('preserve')
    recovered = ReleaseService(service.settings, verifier=release_server[5])
    assert recovered.latest()['versionCode'] == 20
    assert not list(service.trash.iterdir())
    assert not list(service.staging.iterdir())
    assert unrelated.read_text() == 'preserve'


@pytest.mark.parametrize('filename', ['client.part', 'client.apk'])
def test_interrupted_binary_stage_reclaimed_on_explicit_rerun(release_server, filename):
    service = release_server[4]
    _, pending = service.initialize(20, manifest())
    directory = service.staging / pending['uploadId']
    (directory / filename).write_bytes(APK[:3])
    (directory / filename).chmod(0o600)
    status, resumed = service.initialize(20, manifest())
    assert status == 201 and resumed['uploadId'] != pending['uploadId']
    assert not directory.exists()
    assert not list(service.trash.iterdir())


def test_worker_recovery_preserves_a_live_upload_and_completed_stage(release_server):
    service = release_server[4]
    _, pending = service.initialize(20, manifest())
    directory = service.staging / pending['uploadId']
    with service._upload_lock(directory):
        partial = directory / 'client.part'
        partial.write_bytes(APK[:3])
        partial.chmod(0o600)
        recovered = ReleaseService(service.settings, verifier=release_server[5])
        assert partial.read_bytes() == APK[:3]
        assert recovered.initialize(20, manifest())[1]['uploadId'] == pending['uploadId']
        partial.unlink()
    request = stream_request([{'type': 'http.request', 'body': APK, 'more_body': False}],
                             headers=[(b'content-type', b'application/octet-stream')])
    asyncio.run(service.receive_upload(20, pending['uploadId'], request))
    recovered = ReleaseService(service.settings, verifier=release_server[5])
    status, resumed = recovered.initialize(20, manifest())
    assert status == 200 and resumed['state'] == 'uploaded'
    assert resumed['uploadId'] == pending['uploadId']
