"""Export actual authenticated grant/revoke metadata, never auth material."""
import json
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
from uuid import UUID

from fastapi.testclient import TestClient

from conftest import Clock, auth, ready
from test_admin import activate, create as create_user
from test_home_resource_registry import paths
from larenor_server.app import create_app
from larenor_server.config import Settings


FIXTURE = Path(__file__).resolve().parents[2] / 'contracts/home-resource-grants.v1.json'


def actual_grants_contract(root):
    clock = Clock()
    settings = Settings(root / 'data', root / 'secrets/vault.key', clock=clock)
    identities = iter(('a' * 32, 'b' * 32))
    with patch('larenor_server.context.secrets',
               SimpleNamespace(token_hex=lambda _: next(identities))):
        app = create_app(settings)
    with TestClient(app) as client:
        admin = ready((app, client, settings, clock))
        user_ids = iter(('3' * 32, '2' * 32))
        with patch('larenor_server.admin.service.uuid',
                   SimpleNamespace(uuid4=lambda: UUID(hex=next(user_ids)))):
            first = create_user(client, admin)
            second = create_user(client, admin, name='second')
        member = activate(client, 'member')
        public, base = paths(app)
        result = {'schemaVersion': 1, 'context': app.state.core.context.model_dump()}
        with patch('larenor_server.home_resources.service.uuid',
                   SimpleNamespace(uuid4=lambda: UUID(hex='1' * 32))):
            response = client.post(base, headers=auth(admin), json={
                'kind': 'room', 'label': 'Salon', 'order': 1})
            assert response.status_code == 201
            result['target'] = response.json()['record']
        target = base + '/' + result['target']['ref']['id'] + '/grants'
        def capture(name, method, path, *, body=None, pair=admin, status=200):
            response = client.request(method, path, headers=auth(pair), json=body)
            assert response.status_code == status, response.text
            result[name] = dict(method=method, path=path.removeprefix('/api/v1'),
                body=body, status=response.status_code, response=response.json())
            return result[name]['response']
        def grant(name, user, revision, read, write, **kwargs):
            return capture(name, 'PUT', target + '/' + user['id'], body={
                'expectedAclRevision': revision, 'permissions': dict(read=read, write=write)}, **kwargs)

        capture('empty', 'GET', target)
        grant('readOnly', first, 1, True, False)
        capture('afterReadOnly', 'GET', target)
        capture('memberCanRead', 'GET', public + '/' + result['target']['ref']['id'], pair=member)
        grant('readOnlyNoop', first, 2, True, False)
        grant('secondReadWrite', second, 2, True, True)
        capture('sorted', 'GET', target)
        grant('upgrade', first, 3, True, True)
        grant('revoke', first, 4, False, False)
        grant('revokeNoop', first, 5, False, False)
        capture('afterRevoke', 'GET', target)
        capture('memberReadRevoked', 'GET', public + '/' + result['target']['ref']['id'], pair=member, status=404)
        capture('memberCannotList', 'GET', target, pair=member, status=403)
        grant('memberCannotGrant', first, 5, True, True, pair=member, status=403)
        grant('stale', first, 4, True, False, status=409)
        grant('writeRequiresRead', first, 5, False, True, status=400)
        return result


def test_fixture_matches_actual_sqlite_authorization_and_grant_lifecycle(tmp_path):
    actual = actual_grants_contract(tmp_path.resolve())
    assert actual == json.loads(FIXTURE.read_text())


def test_actual_grants_are_revision_bound_ordered_and_revocable(tmp_path):
    result = actual_grants_contract(tmp_path.resolve())
    assert result['empty']['response'] == {'grants': [], 'aclRevision': 1}
    assert [x['subjectId'] for x in result['sorted']['response']['grants']] == ['2' * 32, '3' * 32]
    assert result['readOnlyNoop']['response'] == result['readOnly']['response']
    assert result['revokeNoop']['response'] == result['revoke']['response']
    remaining = result['afterRevoke']['response']
    assert remaining['aclRevision'] == 5 and len(remaining['grants']) == 1
    assert remaining['grants'][0]['subjectId'] == '2' * 32
    assert result['memberCanRead']['status'] == 200 and result['memberReadRevoked']['status'] == 404
    raw = json.dumps(result)
    assert all(secret not in raw for secret in ('accessToken', 'refreshToken', 'ciphertext', 'password', 'nonce'))
