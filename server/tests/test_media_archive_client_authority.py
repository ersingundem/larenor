from conftest import auth
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
