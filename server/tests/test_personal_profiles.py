"""Account-owned remote profile metadata; no credential or session authority."""
import json
import itertools
import secrets

import pytest
from conftest import auth, login, ready
from fastapi.testclient import TestClient
from larenor_server.app import create_app
from larenor_server.errors import StartupError
from test_admin import activate
from test_admin import create as create_user


def paths(app):
    scope = app.state.core.context
    return f'/api/v1/core-remote-profiles/{scope.coreId}/{scope.homeId}'


def payload(**changes):
    return {
        'label': 'Living room workstation',
        'protocol': 'ssh',
        'host': 'desk.internal.example',
        'port': 22,
        'username': 'private-user',
        **changes,
    }


_requests = itertools.count(1)


def authority(client, pair, base):
    response = client.get(base, headers=auth(pair))
    assert response.status_code == 200, response.text
    return response.json()['authority']


def request_id():
    return f'{next(_requests):032x}'


def create(client, pair, base, *, operation=None, expected=None, **changes):
    current = expected or authority(client, pair, base)
    response = client.post(base, headers=auth(pair), json={
        **payload(**changes),
        'requestId': operation or request_id(),
        'expectedAccountRevision': current['accountRevision'],
        'expectedCollectionRevision': current['collectionRevision'],
    })
    assert response.status_code == 201, response.text
    return response.json()['profile']


def read(client, pair, base, profile_id, revision, expected=None):
    current = expected or authority(client, pair, base)
    return client.get(base + '/' + profile_id, headers=auth(pair), params={
        'expectedRevision': revision,
        'expectedAccountRevision': current['accountRevision'],
        'expectedCollectionRevision': current['collectionRevision'],
    })


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
        'kind': 'coreRemoteProfile',
        'id': identity,
        'accountId': admin['user']['id'],
    }
    assert own['revision'] == 1
    assert client.get(base, headers=auth(member)).json()['profiles'] == []
    member_authority = authority(client, member, base)
    hidden = read(client, member, base, identity, 1, member_authority)
    missing = read(client, member, base, 'f' * 32, 1, member_authority)
    assert hidden.status_code == missing.status_code == 404
    assert hidden.json() == missing.json()

    theirs = create(client, member, base, label='Member target', host='member.internal')
    assert client.get(base, headers=auth(admin)).json()['profiles'] == [own]
    assert client.get(base, headers=auth(member)).json()['profiles'] == [theirs]
    for field in ('coreId', 'homeId'):
        wrong = base.replace(getattr(app.state.core.context, field), 'e' * 32)
        assert client.get(wrong, headers=auth(admin)).status_code == 404

    with TestClient(create_app(settings)) as restarted:
        assert read(restarted, admin, base, identity, 1).json()['profile'] == own
        assert restarted.get(base, headers=auth(member)).json()['profiles'] == [theirs]


def test_rdp_security_profile_is_encrypted_closed_and_restart_stable(server):
    app, client, settings, _ = server
    pair = ready(server)
    base = paths(app)
    current = authority(client, pair, base)
    body = {
        **payload(
            protocol='rdp', port=3389, username='target-user',
            rdp={
                'domain': 'TARGET',
                'certificateFingerprint':
                    'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
                'gateway': {
                    'host': 'gateway.internal.example',
                    'port': 443,
                    'username': 'gateway-user',
                    'domain': 'GATEWAY',
                    'certificateFingerprint':
                        'SHA256:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB',
                },
            },
        ),
        'requestId': 'a' * 32,
        'expectedAccountRevision': current['accountRevision'],
        'expectedCollectionRevision': current['collectionRevision'],
    }
    created = client.post(base, headers=auth(pair), json=body)
    assert created.status_code == 201, created.text
    replay = client.post(base, headers=auth(pair), json=body)
    assert replay.status_code == 201
    assert replay.json() == created.json()
    profile = created.json()['profile']
    assert profile['rdp'] == body['rdp']
    assert not any(key in json.dumps(profile).lower()
                   for key in ('password', 'gatewaypassword', 'token', 'secret'))

    with app.state.core.db.transaction() as connection:
        row = connection.execute(
            'SELECT ciphertext FROM personal_profile_records WHERE owner_id=? AND id=?',
            (pair['user']['id'], profile['ref']['id']),
        ).fetchone()
    assert row is not None
    ciphertext = bytes(row['ciphertext'])
    for private in (
            b'TARGET', b'gateway.internal.example', b'gateway-user',
            b'SHA256:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB'):
        assert private not in ciphertext

    with TestClient(create_app(settings)) as restarted:
        restored = read(
            restarted, pair, base, profile['ref']['id'], profile['revision'],
        )
        assert restored.status_code == 200
        assert restored.json()['profile'] == profile


def test_rdp_security_rejects_other_protocols_unknowns_and_credentials(server):
    app, client, _, _ = server
    pair = ready(server)
    base = paths(app)
    security = {
        'domain': 'TARGET',
        'certificateFingerprint':
            'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        'gateway': {
            'host': 'gateway.internal.example',
            'port': 443,
            'username': 'gateway-user',
            'domain': 'GATEWAY',
            'certificateFingerprint':
                'SHA256:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB',
        },
    }
    candidates = [
        payload(rdp=security),
        payload(protocol='vnc', port=5900, rdp=security),
        payload(protocol='rdp', port=3389, rdp={**security, 'password': 'private'}),
        payload(protocol='rdp', port=3389, rdp={
            **security,
            'gateway': {**security['gateway'], 'gatewayPassword': 'private'},
        }),
        payload(protocol='rdp', port=3389, rdp={
            **security,
            'gateway': {**security['gateway'], 'future': True},
        }),
    ]
    for index, candidate in enumerate(candidates, start=1):
        current = authority(client, pair, base)
        response = client.post(base, headers=auth(pair), json={
            **candidate,
            'requestId': f'{index:032x}',
            'expectedAccountRevision': current['accountRevision'],
            'expectedCollectionRevision': current['collectionRevision'],
        })
        assert response.status_code == 400
    assert client.get(base, headers=auth(pair)).json()['profiles'] == []


def test_optimistic_revision_and_bounded_validation_are_fail_closed(server, monkeypatch):
    from larenor_server.personal_profiles import schema

    monkeypatch.setattr(schema, 'MAX_PROFILES_PER_ACCOUNT', 2)
    app, client, _, _ = server
    pair = ready(server)
    base = paths(app)
    first = create(client, pair, base)
    current = authority(client, pair, base)

    stale = client.patch(base + '/' + first['ref']['id'], headers=auth(pair), json={
        **payload(label='Stale overwrite'), 'requestId': request_id(),
        'expectedAccountRevision': current['accountRevision'],
        'expectedCollectionRevision': current['collectionRevision'],
        'expectedRevision': 2})
    assert stale.status_code == 409
    assert read(client, pair, base, first['ref']['id'], 1).json()['profile'] == first

    changed = client.patch(base + '/' + first['ref']['id'], headers=auth(pair), json={
        **payload(label='Updated target'), 'requestId': request_id(),
        'expectedAccountRevision': current['accountRevision'],
        'expectedCollectionRevision': current['collectionRevision'],
        'expectedRevision': 1})
    assert changed.status_code == 200
    updated = changed.json()['profile']
    assert updated['revision'] == 2 and updated['label'] == 'Updated target'
    current = changed.json()['authority']
    stale_read = read(
        client, pair, base, first['ref']['id'], 1, expected=current)
    assert stale_read.status_code == 409
    assert stale_read.json()['error']['code'] == 'revision_conflict'
    assert client.delete(base + '/' + first['ref']['id'], headers=auth(pair),
                         params={'requestId': request_id(), 'expectedRevision': 1,
                                 'expectedAccountRevision': current['accountRevision'],
                                 'expectedCollectionRevision': current['collectionRevision']}).status_code == 409

    create(client, pair, base, label='Second', protocol='rdp', port=3389)
    current = authority(client, pair, base)
    assert client.post(base, headers=auth(pair), json={
        **payload(label='Over limit'), 'requestId': request_id(),
        'expectedAccountRevision': current['accountRevision'],
        'expectedCollectionRevision': current['collectionRevision'],
    }).status_code == 409
    assert len(client.get(base, headers=auth(pair)).json()['profiles']) == 2

    invalid = [
        payload(label=''), payload(host='ssh://desk.internal'), payload(port=0),
        payload(protocol='telnet'), payload(username='x' * 129),
        payload(extra='closed'),
    ]
    for body in invalid:
        assert client.post(base, headers=auth(pair), json={
            **body, 'requestId': request_id(),
            'expectedAccountRevision': current['accountRevision'],
            'expectedCollectionRevision': current['collectionRevision'],
        }).status_code == 400
    assert len(client.get(base, headers=auth(pair)).json()['profiles']) == 2


def test_mutations_are_idempotent_family_bound_and_restart_durable(server):
    app, client, settings, _ = server
    pair = ready(server)
    base = paths(app)
    initial = authority(client, pair, base)
    create_id = 'a' * 32
    create_body = {
        **payload(), 'requestId': create_id,
        'expectedAccountRevision': initial['accountRevision'],
        'expectedCollectionRevision': initial['collectionRevision'],
    }
    first = client.post(base, headers=auth(pair), json=create_body)
    replay = client.post(base, headers=auth(pair), json=create_body)
    assert first.status_code == replay.status_code == 201
    assert first.json() == replay.json()
    assert client.post(base, headers=auth(pair), json={
        **create_body, 'label': 'Changed replay',
    }).json()['error']['code'] == 'idempotency_conflict'

    profile = first.json()['profile']
    update_id = 'b' * 32
    update_body = {
        **payload(label='Updated once'), 'requestId': update_id,
        'expectedAccountRevision': initial['accountRevision'],
        'expectedCollectionRevision': 1, 'expectedRevision': 1,
    }
    updated = client.patch(
        base + '/' + profile['ref']['id'], headers=auth(pair), json=update_body)
    update_replay = client.patch(
        base + '/' + profile['ref']['id'], headers=auth(pair), json=update_body)
    assert updated.status_code == update_replay.status_code == 200
    assert updated.json() == update_replay.json()

    delete_params = {
        'requestId': 'c' * 32, 'expectedRevision': 2,
        'expectedAccountRevision': initial['accountRevision'],
        'expectedCollectionRevision': 2,
    }
    deleted = client.delete(
        base + '/' + profile['ref']['id'], headers=auth(pair), params=delete_params)
    delete_replay = client.delete(
        base + '/' + profile['ref']['id'], headers=auth(pair), params=delete_params)
    assert deleted.status_code == delete_replay.status_code == 200
    assert deleted.json() == delete_replay.json()
    assert client.get(base, headers=auth(pair)).json()['profiles'] == []

    with TestClient(create_app(settings)) as restarted:
        durable = restarted.delete(
            base + '/' + profile['ref']['id'], headers=auth(pair),
            params=delete_params)
        assert durable.status_code == 200
        assert durable.json() == deleted.json()
        create_after_changes = restarted.post(
            base, headers=auth(pair), json=create_body)
        assert create_after_changes.status_code == 409
        assert create_after_changes.json()['error']['code'] == 'operation_replay'


def test_receipts_do_not_grant_a_different_session_family(server):
    app, client, _, _ = server
    pair = ready(server)
    base = paths(app)
    initial = authority(client, pair, base)
    operation = 'd' * 32
    body = {
        **payload(), 'requestId': operation,
        'expectedAccountRevision': initial['accountRevision'],
        'expectedCollectionRevision': initial['collectionRevision'],
    }
    assert client.post(base, headers=auth(pair), json=body).status_code == 201

    other_family = login(
        client, 'admin', 'Synthetic new password 2026', 'Second tablet').json()
    response = client.post(base, headers=auth(other_family), json=body)
    assert response.status_code == 409
    assert response.json()['error']['code'] == 'revision_conflict'
    current = authority(client, other_family, base)
    assert current['sessionFamilyId'] != initial['sessionFamilyId']
    assert current['accountId'] == initial['accountId']
    assert len(client.get(base, headers=auth(other_family)).json()['profiles']) == 1


def test_receipt_bound_evicts_replay_without_reapplying_it(server, monkeypatch):
    from larenor_server.personal_profiles import schema

    monkeypatch.setattr(schema, 'MAX_RECEIPTS_PER_ACCOUNT', 2)
    monkeypatch.setattr(schema, 'MAX_AUDIT', 2)
    app, client, _, _ = server
    pair = ready(server)
    base = paths(app)
    initial = authority(client, pair, base)
    create_body = {
        **payload(), 'requestId': '1' * 32,
        'expectedAccountRevision': initial['accountRevision'],
        'expectedCollectionRevision': 0,
    }
    created = client.post(base, headers=auth(pair), json=create_body).json()
    profile = created['profile']
    updated = client.patch(base + '/' + profile['ref']['id'], headers=auth(pair), json={
        **payload(label='Bounded update'), 'requestId': '2' * 32,
        'expectedAccountRevision': initial['accountRevision'],
        'expectedCollectionRevision': 1, 'expectedRevision': 1,
    }).json()
    response = client.delete(base + '/' + profile['ref']['id'], headers=auth(pair), params={
        'requestId': '3' * 32, 'expectedRevision': 2,
        'expectedAccountRevision': initial['accountRevision'],
        'expectedCollectionRevision': updated['authority']['collectionRevision'],
    })
    assert response.status_code == 200
    with app.state.core.db.connection() as connection:
        assert connection.execute(
            'SELECT COUNT(*) FROM personal_profile_receipts WHERE owner_id=?',
            (pair['user']['id'],),
        ).fetchone()[0] == 2
        audit_count = connection.execute(
            'SELECT COUNT(*) FROM personal_profile_audit'
        ).fetchone()[0]
        audit_state = connection.execute(
            'SELECT * FROM personal_profile_audit_state'
        ).fetchone()
        assert audit_count == audit_state['record_count'] == 2
    evicted = client.post(base, headers=auth(pair), json=create_body)
    assert evicted.status_code == 409
    assert evicted.json()['error']['code'] == 'revision_conflict'
    assert client.get(base, headers=auth(pair)).json()['profiles'] == []

@pytest.mark.parametrize('field', ['password', 'token', 'secret', 'pin', 'lease', 'privateKey'])
def test_secret_pin_and_lease_fields_never_cross_api_log_or_database(server, caplog, field):
    app, client, _, _ = server
    pair = ready(server)
    base = paths(app)
    marker = 'synthetic-private-material-2026'
    current = authority(client, pair, base)
    rejected = client.post(base, headers=auth(pair), json={
        **payload(), field: marker, 'requestId': request_id(),
        'expectedAccountRevision': current['accountRevision'],
        'expectedCollectionRevision': current['collectionRevision'],
    })
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
    contract = schema['paths']['/api/v1/core-remote-profiles/{core_id}/{home_id}']
    assert contract['get']['security'] == [{'DeviceAccessToken': []}]
    assert contract['post']['responses']['201']['content']['application/json']['schema']['$ref'].endswith(
        'PersonalProfileResponse')
    create_schema = schema['components']['schemas']['CreatePersonalProfileRequest']
    assert set(create_schema['properties']) == {
        'label', 'protocol', 'host', 'port', 'username', 'rdp', 'requestId',
        'expectedAccountRevision', 'expectedCollectionRevision'}
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


@pytest.mark.parametrize('target', ['receipt', 'journal-row', 'journal-state'])
def test_receipt_and_journal_tampering_fail_closed_on_restart(server, target):
    app, client, settings, _ = server
    pair = ready(server)
    base = paths(app)
    create(client, pair, base)
    with app.state.core.db.transaction() as connection:
        if target == 'receipt':
            connection.execute(
                "UPDATE personal_profile_receipts SET ciphertext=X'00'"
            )
        elif target == 'journal-row':
            connection.execute(
                'DELETE FROM personal_profile_audit WHERE sequence=('
                'SELECT MIN(sequence) FROM personal_profile_audit)'
            )
        else:
            connection.execute(
                'UPDATE personal_profile_audit_state SET record_count=0'
            )
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
                'personal_profile_audit_state',
                'personal_profile_audit',
                'personal_profile_receipts',
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


def test_normal_rdp_gateway_patch_rotation_removal_and_delete_are_durable(server):
    app, client, settings, _ = server
    pair = ready(server)
    base = paths(app)
    original = create(client, pair, base, protocol='rdp', port=3389,
                      username='target-user')
    assert 'rdp' not in original
    target_pin = 'SHA256:' + 'A' * 43
    gateway_pin = 'SHA256:' + 'C' * 42 + 'E'
    security = {
        'domain': 'TARGET', 'certificateFingerprint': target_pin,
        'gateway': {
            'host': 'gateway.internal.example', 'port': 443,
            'username': 'gateway-user', 'domain': 'GATEWAY',
            'certificateFingerprint': gateway_pin,
        },
    }
    current = authority(client, pair, base)
    update = {
        **payload(protocol='rdp', port=3389, username='target-user', rdp=security),
        'requestId': request_id(),
        'expectedAccountRevision': current['accountRevision'],
        'expectedCollectionRevision': current['collectionRevision'],
        'expectedRevision': original['revision'],
    }
    url = base + '/' + original['ref']['id']
    changed = client.patch(url, headers=auth(pair), json=update)
    assert changed.status_code == 200
    enrolled = changed.json()['profile']
    assert enrolled['rdp'] == security
    assert enrolled['revision'] == original['revision'] + 1
    replay = client.patch(url, headers=auth(pair), json=update)
    assert replay.status_code == 200 and replay.json() == changed.json()
    stale = client.patch(url, headers=auth(pair), json={
        **update, 'requestId': request_id(), 'label': 'Stale update',
    })
    assert stale.status_code == 409
    assert client.get(base, headers=auth(pair)).json()['profiles'] == [enrolled]
    with TestClient(create_app(settings)) as restarted:
        assert read(restarted, pair, base, enrolled['ref']['id'],
                    enrolled['revision']).json()['profile'] == enrolled
        current = authority(restarted, pair, base)
        rotated_security = {**security, 'gateway': {
            **security['gateway'], 'certificateFingerprint': 'SHA256:' + 'D' * 42 + 'E',
        }}
        rotated = restarted.patch(url, headers=auth(pair), json={
            **update, 'rdp': rotated_security, 'requestId': request_id(),
            'expectedRevision': enrolled['revision'],
            'expectedCollectionRevision': current['collectionRevision'],
        })
        assert rotated.status_code == 200
        rotation = rotated.json()['profile']
        assert rotation['rdp'] == rotated_security
        current = authority(restarted, pair, base)
        removed = restarted.patch(url, headers=auth(pair), json={
            **update, 'rdp': {**security, 'gateway': None},
            'requestId': request_id(), 'expectedRevision': rotation['revision'],
            'expectedCollectionRevision': current['collectionRevision'],
        })
        assert removed.status_code == 200
        direct = removed.json()['profile']
        assert direct['rdp'] == {**security, 'gateway': None}
        assert direct['revision'] == rotation['revision'] + 1
        current = authority(restarted, pair, base)
        deleted = restarted.delete(url, headers=auth(pair), params={
            'requestId': request_id(), 'expectedRevision': direct['revision'],
            'expectedAccountRevision': current['accountRevision'],
            'expectedCollectionRevision': current['collectionRevision'],
        })
        assert deleted.status_code == 200
        assert restarted.get(base, headers=auth(pair)).json()['profiles'] == []
    with TestClient(create_app(settings)) as after_delete:
        assert after_delete.get(base, headers=auth(pair)).json()['profiles'] == []


@pytest.mark.parametrize(('protocol', 'port'), [('ssh', 22), ('vnc', 5900), ('rdp', 3389)])
def test_legacy_profile_public_keys_survive_create_read_replay_and_restart(
        server, protocol, port):
    app, client, settings, _ = server
    pair = ready(server)
    base = paths(app)
    current = authority(client, pair, base)
    body = {
        **payload(protocol=protocol, port=port),
        'requestId': request_id(),
        'expectedAccountRevision': current['accountRevision'],
        'expectedCollectionRevision': current['collectionRevision'],
    }
    created = client.post(base, headers=auth(pair), json=body)
    assert created.status_code == 201
    profile = created.json()['profile']
    # Shipped clients use a closed decoder for these seven public keys.
    assert set(profile) == {'ref', 'revision', 'label', 'protocol', 'host', 'port', 'username'}
    replay = client.post(base, headers=auth(pair), json=body)
    assert replay.status_code == 201 and replay.json() == created.json()
    assert read(client, pair, base, profile['ref']['id'], 1).json()['profile'] == profile
    assert client.get(base, headers=auth(pair)).json()['profiles'] == [profile]
    with TestClient(create_app(settings)) as restarted:
        assert read(restarted, pair, base, profile['ref']['id'], 1).json()['profile'] == profile
        assert restarted.get(base, headers=auth(pair)).json()['profiles'] == [profile]


@pytest.mark.parametrize('action', ['create', 'update'])
def test_legacy_encrypted_request_receipt_replays_after_security_contract_upgrade(server, action):
    app, client, settings, _ = server
    pair = ready(server)
    base = paths(app)
    target = None
    url = base
    method = client.post
    status = 201
    if action == 'update':
        profile = create(client, pair, base)
        target = profile['ref']['id']
        url += '/' + target
        method = client.patch
        status = 200
    current = authority(client, pair, base)
    body = {
        **payload(label='Legacy request'), 'requestId': request_id(),
        'expectedAccountRevision': current['accountRevision'],
        'expectedCollectionRevision': current['collectionRevision'],
    }
    if action == 'update':
        body['expectedRevision'] = profile['revision']
    response = method(url, headers=auth(pair), json=body)
    assert response.status_code == status
    repository = app.state.core.personal_profiles
    # A receipt issued by the shipped seven-field contract hashes the request
    # without a new optional security key. Bind its ciphertext to that old AAD.
    legacy_hash = repository._request_hash(action, target, body)
    with app.state.core.db.transaction() as connection:
        row = connection.execute(
            'SELECT * FROM personal_profile_receipts WHERE request_id=?',
            (body['requestId'],),
        ).fetchone()
        plain = repository._cipher.decrypt(
            row['nonce'], row['ciphertext'], repository._receipt_aad(
                row['owner_id'], row['family_id'], row['request_id'],
                action, row['request_hash']),
        )
        nonce = secrets.token_bytes(12)
        ciphertext = repository._cipher.encrypt(
            nonce, plain, repository._receipt_aad(
                row['owner_id'], row['family_id'], row['request_id'], action, legacy_hash),
        )
        connection.execute(
            'UPDATE personal_profile_receipts SET request_hash=?,nonce=?,ciphertext=? WHERE sequence=?',
            (legacy_hash, nonce, ciphertext, row['sequence']),
        )
    replay = method(url, headers=auth(pair), json=body)
    assert replay.status_code == status
    assert replay.json() == response.json()
    with TestClient(create_app(settings)) as restarted:
        replay = getattr(restarted, 'post' if action == 'create' else 'patch')(
            url, headers=auth(pair), json=body,
        )
        assert replay.status_code == status and replay.json() == response.json()
