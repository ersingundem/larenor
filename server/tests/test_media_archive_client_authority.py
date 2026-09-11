from conftest import auth
from test_admin import activate, create as create_user
from test_media_archive_core_read import BASE, configured


def test_admin_can_discover_exact_secret_free_authority_before_explicit_read(server):
    pair, installation, _current, reader, worker, _body = configured(server)
    response = server[1].post(
        BASE.rsplit('/', 1)[0] + '/authority', headers=auth(pair), json={
            'requestId': 'f' * 32,
            'installationId': installation['id'],
            'expectedInstallationRevision': installation['revision'],
        })
    assert response.status_code == 200, response.text
    assert response.json() == {
        'requestId': 'f' * 32,
        'installationId': installation['id'],
        'installationRevision': installation['revision'],
        'snapshotRevision': 4,
    }
    assert reader.calls == 1 and worker.calls == []
    assert all(secret not in response.text.lower()
               for secret in ('token', 'password', 'cookie', 'endpoint'))


def test_authority_discovery_rechecks_admin_revision_and_stale_binding(server):
    pair, installation, current, reader, worker, _body = configured(server)
    url = BASE.rsplit('/', 1)[0] + '/authority'
    body = {
        'requestId': 'f' * 32,
        'installationId': installation['id'],
        'expectedInstallationRevision': installation['revision'],
    }
    changed = server[1].post(url, headers=auth(pair), json={
        **body,
        'expectedInstallationRevision': installation['revision'] + 1,
    })
    assert changed.status_code == 409
    assert changed.json()['error']['code'] == 'media_installation_changed'
    create_user(server[1], pair)
    member = activate(server[1], 'member')
    assert server[1].post(url, headers=auth(member), json=body).status_code == 403
    reader.values = [current.model_copy(update={
        'sources': [item.model_copy(update={'observedAt': 1788609309})
                    for item in current.sources],
    })]
    stale = server[1].post(url, headers=auth(pair), json=body)
    assert stale.status_code == 409
    assert stale.json()['error']['code'] == 'media_archive_snapshot_stale'
    assert worker.calls == []
