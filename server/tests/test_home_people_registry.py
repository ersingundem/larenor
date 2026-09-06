"""Real Core HTTP/auth/SQLite household profiles, without upstream operations."""
import json

import pytest
from fastapi.testclient import TestClient

from conftest import auth, bootstrap_password, login, ready
from test_admin import activate, create as create_user
from larenor_server.app import create_app
from larenor_server.errors import StartupError


def paths(app):
    scope = app.state.core.context
    suffix = f'/home-people/{scope.coreId}/{scope.homeId}'
    return '/api/v1' + suffix, '/api/v1/admin' + suffix


def create(client, pair, base, **changes):
    response = client.post(base, headers=auth(pair), json={'label': 'Deniz', 'order': 0, **changes})
    assert response.status_code == 201, response.text
    return response.json()['person']


def grant(client, pair, base, person, subject, *, revision=1, read=True, write=False):
    response = client.put(f"{base}/{person['ref']['id']}/grants/{subject}", headers=auth(pair),
        json={'expectedAclRevision': revision, 'permissions': {'read': read, 'write': write}})
    assert response.status_code == 200, response.text
    return response.json()['grant']


def test_profile_lifecycle_is_private_encrypted_and_preserves_accounts_and_old_resources(server):
    app, client, settings, _ = server
    admin = ready(server); public, base = paths(app)
    create_user(client, admin); member = activate(client, 'member')
    context = app.state.core.context
    old = f'/api/v1/home-resources/{context.coreId}/{context.homeId}'
    room = client.post('/api/v1/admin' + old.removeprefix('/api/v1'), headers=auth(admin),
        json={'kind': 'room', 'label': 'Salon', 'order': 0}).json()['record']
    before_users = client.get('/api/v1/admin/users', headers=auth(admin)).json()
    person = create(client, admin, base)
    identity = person['ref']['id']
    assert person['ref']['kind'] == 'person'
    assert identity not in [admin['user']['id'], member['user']['id'], room['ref']['id']]
    assert person['revision'] == person['aclRevision'] == 1
    assert client.get(public, headers=auth(member)).json()['entries'] == []
    hidden = client.get(public + '/' + identity, headers=auth(member))
    missing = client.get(public + '/' + 'f' * 32, headers=auth(member))
    assert hidden.status_code == missing.status_code == 404
    assert hidden.json() == missing.json()
    assert grant(client, admin, base, person, member['user']['id'])['aclRevision'] == 2
    visible = client.get(public + '/' + identity, headers=auth(member)).json()['person']
    assert visible['permissions'] == {'read': True, 'write': False}
    response = client.patch(base + '/' + identity, headers=auth(admin), json={
        'expectedRevision': 1, 'expectedAclRevision': 2, 'label': 'Ece Özel', 'order': 8})
    assert response.status_code == 200
    changed = response.json()['person']
    assert changed['ref'] == person['ref'] and changed['revision'] == 2
    assert changed['aclRevision'] == 2
    with app.state.core.db.connection() as connection:
        rows = connection.execute('SELECT * FROM home_people_records').fetchall()
        assert len(rows) == 1
        assert 'Ece Özel' not in str(dict(rows[0])) and 'Deniz' not in str(dict(rows[0]))
        assert member['user']['id'] not in str(dict(rows[0]))
        assert isinstance(rows[0]['ciphertext'], bytes)
    with TestClient(create_app(settings)) as restarted:
        assert restarted.get(public + '/' + identity, headers=auth(member)).json()['person'] == {
            **changed, 'permissions': {'read': True, 'write': False}}
    assert grant(client, admin, base, person, member['user']['id'], revision=2, read=False)['aclRevision'] == 3
    assert client.get(public + '/' + identity, headers=auth(member)).status_code == 404
    assert client.delete(base + '/' + identity, headers=auth(admin),
        params={'expectedRevision': 2, 'expectedAclRevision': 3}).status_code == 204
    assert client.get(public, headers=auth(admin)).json()['entries'] == []
    assert client.get(old, headers=auth(admin)).json()['entries'] == [room]
    assert client.get('/api/v1/admin/users', headers=auth(admin)).json() == before_users


def test_profile_routes_require_ready_current_admin_and_expose_their_own_openapi_models(server):
    app, client, settings, _ = server; public, base = paths(app)
    initial = login(client, 'admin', bootstrap_password(settings)).json()
    for headers, expected in [({}, 401), (auth(initial), 403)]:
        assert client.get(public, headers=headers).status_code == expected
        assert client.post(base, headers=headers, json={'label': 'Deniz', 'order': 0}).status_code == expected
    admin = ready(server)
    create_user(client, admin); member = activate(client, 'member')
    person = create(client, admin, base)
    grant(client, admin, base, person, member['user']['id'], write=True)
    for method, suffix, body in [
        ('post', '', {'label': 'No role change', 'order': 0}),
        ('patch', '/' + person['ref']['id'], {'label': 'Not admin', 'order': 0, 'expectedRevision': 1, 'expectedAclRevision': 2}),
    ]:
        assert getattr(client, method)(base + suffix, headers=auth(member), json=body).status_code == 403
    assert client.get(base + '/' + person['ref']['id'] + '/grants', headers=auth(member)).status_code == 403
    for field in ('coreId', 'homeId'):
        other = public.replace(getattr(app.state.core.context, field), 'f' * 32)
        assert client.get(other, headers=auth(admin)).status_code == 404
    schema = client.get('/api/v1/openapi.json', headers=auth(admin)).json()
    assert '/api/v1/home-people/{core_id}/{home_id}' in schema['paths']
    assert '/api/v1/admin/home-people/{core_id}/{home_id}' in schema['paths']
    assert not any('command' in path for path in schema['paths'] if 'home-people' in path)


@pytest.mark.parametrize('extra', [
    {'id': 'c' * 32}, {'kind': 'person'}, {'userId': 'd' * 32},
    {'role': 'admin'}, {'entityId': 'person.deniz'}, {'grants': {}}, {'health': {}},
])
def test_create_cannot_import_identity_permissions_or_upstream_binding(server, extra):
    app, client, _, _ = server; admin = ready(server); public, base = paths(app)
    result = client.post(base, headers=auth(admin), json={'label': 'Deniz', 'order': 0, **extra})
    assert result.status_code == 400
    assert client.get(public, headers=auth(admin)).json()['entries'] == []


def test_hidden_profile_changes_do_not_invalidate_a_members_visible_snapshot(server):
    app, client, _, _ = server; admin = ready(server); public, base = paths(app)
    create_user(client, admin); member = activate(client, 'member')
    visible = create(client, admin, base)
    grant(client, admin, base, visible, member['user']['id'])
    before = client.get(public, headers=auth(member)).json()
    hidden = create(client, admin, base, label='Hidden household member')
    assert client.get(public, headers=auth(member)).json() == before
    result = client.get(public, headers=auth(member), params={
        'after': hidden['ref']['id'], 'expectedSnapshot': before['snapshot']})
    assert result.status_code == 404
    grant(client, admin, base, visible, member['user']['id'], revision=2, read=False)
    assert client.get(public, headers=auth(member), params={'expectedSnapshot': before['snapshot']}).status_code == 409


def test_people_ciphertext_revision_tampering_preserves_storage_and_fails_closed(server):
    app, client, settings, _ = server; admin = ready(server); public, base = paths(app)
    person = create(client, admin, base)
    with app.state.core.db.transaction() as connection:
        connection.execute('UPDATE home_people_records SET revision=revision+1 WHERE id=?', (person['ref']['id'],))
    assert client.get(public, headers=auth(admin)).status_code == 503
    with pytest.raises(StartupError, match='home_people_storage_invalid'):
        create_app(settings)
