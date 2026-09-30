from conftest import auth
from test_admin import activate, create
from test_music_manager_api import MANAGER, ready_manager, search_body


def member(server, admin):
    create(server[1], admin, 'music-reader')
    return activate(server[1], 'music-reader')


def test_ready_member_discovers_refreshes_and_searches_without_admin_setup(server):
    admin, setup, readiness, worker, manager = ready_manager(server)
    user = member(server, admin)
    client = server[1]
    response = client.get(MANAGER + '/available', headers=auth(user))
    assert response.status_code == 200, response.text
    assert response.json()['state'] == 'ready'
    assert response.json()['installations'][0]['installationId'] == setup['installationId']
    assert client.get('/api/v1/admin/media/music-assistant/retained',
                      headers=auth(user)).status_code == 403
    refreshed = client.post(MANAGER + '/refresh', headers=auth(user), json={
        'requestId': '5' * 32, 'installationId': setup['installationId'],
        'expectedInstallationRevision': setup['installationRevision'],
        'expectedCoreRevision': readiness['revision'],
    })
    assert refreshed.status_code == 200, refreshed.text
    searched = client.post(MANAGER + '/catalog/search', headers=auth(user),
        json=search_body(setup, readiness, refreshed.json()['manager']))
    assert searched.status_code == 200, searched.text
    assert len(worker.searches) == 1
    assert 'private-mass-token' not in response.text + searched.text


def test_session_revoked_during_member_refresh_never_publishes_readback(server):
    app, client, _, _ = server
    admin, setup, readiness, worker, manager = ready_manager(server)
    user = member(server, admin)
    original = worker.read_music_players
    observed = []

    def revoked(authority, *, deadline, gate):
        value = original(authority, deadline=deadline, gate=gate)
        assert client.post('/api/v1/auth/logout', headers=auth(user)).status_code == 204
        observed.append(gate())
        return value

    worker.read_music_players = revoked
    response = client.post(MANAGER + '/refresh', headers=auth(user), json={
        'requestId': '6' * 32, 'installationId': setup['installationId'],
        'expectedInstallationRevision': setup['installationRevision'],
        'expectedCoreRevision': readiness['revision'],
    })
    assert response.status_code == 503
    assert observed == [False]
    principal = app.state.core.auth.authenticate(admin['accessToken'])
    assert app.state.core.music_playback.manager(principal,
        setup['installationId'])['manager']['revision'] == manager['revision']
