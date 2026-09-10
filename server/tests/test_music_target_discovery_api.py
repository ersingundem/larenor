"""Member-readable, exact-revision Music Assistant target discovery."""

from conftest import auth
from test_admin import activate, create
from test_music_playback import discovered
from test_music_target_authority import inventory_request


BASE = '/api/v1/media/music-assistant/target-discovery'


def test_ready_member_reads_exact_secret_free_target_discovery(server):
    _app, client, _, _ = server
    admin, setup, readiness, worker, playback = discovered(server)
    create(client, admin, 'music-listener')
    member = activate(client, 'music-listener')
    response = client.post(
        BASE, headers=auth(member),
        json=inventory_request(server, admin, setup, readiness, playback))
    assert response.status_code == 200, response.text
    discovery = response.json()['inventory']
    target = discovery['targets'][0]
    assert target['providerDomain'] == 'airplay'
    assert target['providerInstanceId'] == 'airplay--main'
    assert target['queue']['id'] == target['queueId']
    assert discovery['playerRevision'] == playback['revision']
    encoded = response.text.lower()
    assert 'token' not in encoded and 'cookie' not in encoded
    assert 'http://' not in encoded and 'https://' not in encoded
    assert worker.calls == []


def test_member_discovery_rejects_stale_revision_and_mutation_stays_admin_only(server):
    _app, client, _, _ = server
    admin, setup, readiness, worker, playback = discovered(server)
    create(client, admin, 'music-readonly')
    member = activate(client, 'music-readonly')
    exact = inventory_request(server, admin, setup, readiness, playback)
    stale = client.post(
        BASE, headers=auth(member),
        json=exact | {'expectedPlayerRevision': playback['revision'] + 1})
    assert stale.status_code == 409
    mutation = client.post(
        '/api/v1/admin/media/music-assistant/target-authority/previews',
        headers=auth(member), json={})
    assert mutation.status_code == 403
    assert worker.calls == []
