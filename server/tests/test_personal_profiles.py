"""Account-owned remote profile metadata; no credential or session authority."""
import json

import pytest
from conftest import auth, ready
from fastapi.testclient import TestClient
from larenor_server.app import create_app
from larenor_server.errors import StartupError
from test_admin import activate
from test_admin import create as create_user


def paths(app):
    scope = app.state.core.context
    return f'/api/v1/personal-profiles/{scope.coreId}/{scope.homeId}'


def payload(**changes):
    return {
        'label': 'Living room workstation',
        'protocol': 'ssh',
        'host': 'desk.internal.example',
        'port': 22,
        'username': 'private-user',
        **changes,
    }


def create(client, pair, base, **changes):
    response = client.post(base, headers=auth(pair), json=payload(**changes))
    assert response.status_code == 201, response.text
    return response.json()['profile']


def test_account_and_home_isolation_survive_restart(server):
    app, client, settings, _ = server
    admin = ready(server)
    create_user(client, admin)
    member = activate(client, 'member')
    base = paths(app)

    own = create(client, admin, base)
    identity = own['ref']['id']
    assert own['ref'] == {
        'schemaVersion': 1,
        'coreId': app.state.core.context.coreId,
        'homeId': app.state.core.context.homeId,
        'kind': 'remoteProfile',
        'id': identity,
    }
    assert own['revision'] == 1
    assert client.get(base, headers=auth(member)).json()['profiles'] == []
    hidden = client.get(base + '/' + identity, headers=auth(member))
    missing = client.get(base + '/' + 'f' * 32, headers=auth(member))
    assert hidden.status_code == missing.status_code == 404
    assert hidden.json() == missing.json()

    theirs = create(client, member, base, label='Member target', host='member.internal')
    assert client.get(base, headers=auth(admin)).json()['profiles'] == [own]
    assert client.get(base, headers=auth(member)).json()['profiles'] == [theirs]
    for field in ('coreId', 'homeId'):
        wrong = base.replace(getattr(app.state.core.context, field), 'e' * 32)
        assert client.get(wrong, headers=auth(admin)).status_code == 404

    with TestClient(create_app(settings)) as restarted:
        assert restarted.get(base + '/' + identity, headers=auth(admin)).json()['profile'] == own
        assert restarted.get(base, headers=auth(member)).json()['profiles'] == [theirs]


def test_optimistic_revision_and_bounded_validation_are_fail_closed(server, monkeypatch):
    from larenor_server.personal_profiles import schema

    monkeypatch.setattr(schema, 'MAX_PROFILES_PER_ACCOUNT', 2)
    app, client, _, _ = server
    pair = ready(server)
    base = paths(app)
    first = create(client, pair, base)

    stale = client.patch(base + '/' + first['ref']['id'], headers=auth(pair), json={
        **payload(label='Stale overwrite'), 'expectedRevision': 2})
    assert stale.status_code == 409
    assert client.get(base + '/' + first['ref']['id'], headers=auth(pair)).json()['profile'] == first

    changed = client.patch(base + '/' + first['ref']['id'], headers=auth(pair), json={
        **payload(label='Updated target'), 'expectedRevision': 1})
    assert changed.status_code == 200
    updated = changed.json()['profile']
    assert updated['revision'] == 2 and updated['label'] == 'Updated target'
    assert client.delete(base + '/' + first['ref']['id'], headers=auth(pair),
                         params={'expectedRevision': 1}).status_code == 409

    create(client, pair, base, label='Second', protocol='rdp', port=3389)
    assert client.post(base, headers=auth(pair), json=payload(label='Over limit')).status_code == 409
    assert len(client.get(base, headers=auth(pair)).json()['profiles']) == 2

    invalid = [
        payload(label=''), payload(host='ssh://desk.internal'), payload(port=0),
        payload(protocol='telnet'), payload(username='x' * 129), payload(extra='closed'),
    ]
    for body in invalid:
        assert client.post(base, headers=auth(pair), json=body).status_code == 400
    assert len(client.get(base, headers=auth(pair)).json()['profiles']) == 2


@pytest.mark.parametrize('field', ['password', 'token', 'secret', 'pin', 'lease', 'privateKey'])
def test_secret_pin_and_lease_fields_never_cross_api_log_or_database(server, caplog, field):
    app, client, _, _ = server
    pair = ready(server)
    base = paths(app)
    marker = 'synthetic-private-material-2026'
    rejected = client.post(base, headers=auth(pair), json={**payload(), field: marker})
    assert rejected.status_code == 400
    assert marker not in rejected.text and marker not in caplog.text

    stored = create(
        client,
        pair,
        base,
        label='Encrypted personal marker',
        host='private-marker.internal',
        username='private-marker-user',
    )
    assert marker not in json.dumps(stored)
    with app.state.core.db.connection() as connection:
        columns = ' '.join(
            row['sql'] or ''
            for row in connection.execute(
                "SELECT sql FROM sqlite_master WHERE name GLOB 'personal_profile_*'"
            )
        ).lower()
        raw = '\n'.join(connection.iterdump())
    for forbidden in ('password', 'token', 'secret', 'pin', 'lease', 'private_key'):
        assert forbidden not in columns
    for private in ('Encrypted personal marker', 'private-marker.internal', 'private-marker-user', marker):
        assert private not in raw


def test_openapi_exposes_only_typed_account_profile_metadata(server):
    app, client, _, _ = server
    pair = ready(server)
    base = paths(app)
    schema = client.get('/api/v1/openapi.json', headers=auth(pair)).json()
    contract = schema['paths']['/api/v1/personal-profiles/{core_id}/{home_id}']
    assert contract['get']['security'] == [{'DeviceAccessToken': []}]
    assert contract['post']['responses']['201']['content']['application/json']['schema']['$ref'].endswith(
        'PersonalProfileResponse')
    create_schema = schema['components']['schemas']['CreatePersonalProfileRequest']
    assert set(create_schema['properties']) == {'label', 'protocol', 'host', 'port', 'username'}
    assert create_schema['additionalProperties'] is False
    assert not any(word in json.dumps(create_schema).lower()
                   for word in ('password', 'token', 'secret', 'pin', 'lease'))
    assert client.get(base).status_code == 401


def test_encrypted_record_or_integrity_state_tampering_fails_closed(server):
    app, client, settings, _ = server
    pair = ready(server)
    base = paths(app)
    profile = create(client, pair, base)
    with app.state.core.db.transaction() as connection:
        connection.execute(
            "UPDATE personal_profile_records SET ciphertext=X'00000000000000000000000000000000' "
            "WHERE owner_id=? AND id=?",
            (pair['user']['id'], profile['ref']['id']),
        )
    response = client.get(base, headers=auth(pair))
    assert response.status_code == 503
    assert response.json()['error']['code'] == 'server_unavailable'
    with pytest.raises(StartupError, match='personal_profile_storage_invalid'):
        create_app(settings)


def test_additive_migration_preserves_existing_accounts_and_sessions(server):
    app, client, settings, _ = server
    admin = ready(server)
    create_user(client, admin)
    member = activate(client, 'member')
    before = client.get('/api/v1/admin/users', headers=auth(admin)).json()
    with app.state.core.db.transaction() as connection:
        for table in (
                'personal_profile_audit',
                'personal_profile_state',
                'personal_profile_records'):
            connection.execute('DROP TABLE ' + table)
        connection.execute(
            "DELETE FROM metadata WHERE key='personal_profiles_schema'")

    restarted = create_app(settings)
    with TestClient(restarted) as next_client:
        assert next_client.get(
            '/api/v1/admin/users', headers=auth(admin)).json() == before
        assert next_client.get(
            paths(restarted), headers=auth(member)).json()['profiles'] == []
