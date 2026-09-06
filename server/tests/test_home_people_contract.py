"""Actual authenticated HTTP/SQLite fixture; exporter never emits auth material."""
import json
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
from unittest.mock import patch
from uuid import UUID

from fastapi.testclient import TestClient

from conftest import Clock, auth, ready
from test_admin import activate, create as create_user
from test_home_people_registry import paths
from larenor_server.app import create_app
from larenor_server.config import Settings
from larenor_server.files import private_create

FIXTURE = Path(__file__).resolve().parents[2] / 'contracts/home-people.v1.json'


def actual_journey(root, *, core_id='a' * 32, home_id='b' * 32, prefix=''):
    clock = Clock()
    settings = Settings(root / 'data', root / 'secrets/vault.key', clock=clock)
    private_create(settings.key_file, bytes(range(32)))  # Public fixture-only key.
    contexts = iter((core_id, home_id))
    core_ids = iter(('0' * 32, 'f' * 32))
    with patch('larenor_server.context.secrets', SimpleNamespace(token_hex=lambda _: next(contexts))), \
         patch('larenor_server.core.uuid', SimpleNamespace(uuid4=lambda: UUID(hex=next(core_ids)))):
        app = create_app(settings)
    with TestClient(app) as client:
        admin = ready((app, client, settings, clock))
        with patch('larenor_server.admin.service.uuid', SimpleNamespace(uuid4=lambda: UUID(hex='e' * 32))):
            create_user(client, admin)
        member = activate(client, 'member')
        public, base = paths(app)
        result = {'schemaVersion': 1, 'context': app.state.core.context.model_dump(), 'subjectId': member['user']['id']}
        before_users = client.get('/api/v1/admin/users', headers=auth(admin)).json()

        def capture(name, method, path, *, body=None, query=None, actor=admin, status=200):
            response = client.request(method, path, headers=auth(actor), json=body, params=query)
            assert response.status_code == status, (name, response.status_code, response.text)
            data = None if status == 204 else response.json()
            result[name] = dict(method=method, path=path.removeprefix('/api/v1'),
                query=query or {}, body=body, status=status, response=data)
            return data

        capture('emptyList', 'GET', public)
        record_ids = iter(('1' * 32, '2' * 32))
        with patch('larenor_server.home_people.service.uuid', SimpleNamespace(uuid4=lambda: UUID(hex=next(record_ids)))):
            capture('createPerson', 'POST', base, body={'label': prefix + 'Deniz Öztürk', 'order': 7}, status=201)
            capture('createUnicode', 'POST', base, body={'label': '🌿' * 80, 'order': 10000}, status=201)
        target = base + '/' + '1' * 32
        read_target = public + '/' + '1' * 32
        grants = target + '/grants'
        subject = member['user']['id']
        capture('emptyMember', 'GET', public, actor=member)
        capture('emptyGrants', 'GET', grants)
        capture('grantRead', 'PUT', grants + '/' + subject, body={
            'expectedAclRevision': 1, 'permissions': {'read': True, 'write': False}})
        capture('grantUnicode', 'PUT', base + '/' + '2' * 32 + '/grants/' + subject, body={
            'expectedAclRevision': 1, 'permissions': {'read': True, 'write': False}})
        capture('grantsAfterRead', 'GET', grants)
        capture('memberRecord', 'GET', read_target, actor=member)
        capture('beforeUpdate', 'GET', read_target)
        capture('adminList', 'GET', public)
        capture('memberList', 'GET', public, actor=member)
        first = capture('firstPage', 'GET', public, actor=member, query={'limit': '1'})
        capture('secondPage', 'GET', public, actor=member, query={
            'limit': '1', 'after': first['nextAfter'], 'expectedSnapshot': first['snapshot']})
        body = {'label': prefix + 'Ece Öztürk', 'order': 0, 'expectedRevision': 1, 'expectedAclRevision': 2}
        capture('updatePerson', 'PATCH', target, body=body)
        capture('noopPerson', 'PATCH', target, body={**body, 'expectedRevision': 2})
        capture('grantWrite', 'PUT', grants + '/' + subject, body={
            'expectedAclRevision': 2, 'permissions': {'read': True, 'write': True}})
        capture('grantNoop', 'PUT', grants + '/' + subject, body={
            'expectedAclRevision': 3, 'permissions': {'read': True, 'write': True}})
        capture('staleMetadata', 'PATCH', target, body=body, status=409)
        capture('memberCannotUpdate', 'PATCH', target, body={**body, 'expectedRevision': 2, 'expectedAclRevision': 3}, actor=member, status=403)
        capture('revoke', 'PUT', grants + '/' + subject, body={
            'expectedAclRevision': 3, 'permissions': {'read': False, 'write': False}})
        capture('afterRevoke', 'GET', grants)
        capture('revokedRecord', 'GET', read_target, actor=member, status=404)
        capture('stalePage', 'GET', public, actor=member, query={
            'after': first['nextAfter'], 'expectedSnapshot': first['snapshot']}, status=409)
        capture('beforeDelete', 'GET', read_target)
        capture('deletePerson', 'DELETE', target, query={'expectedRevision': '2', 'expectedAclRevision': '4'}, status=204)
        capture('deletedRecord', 'GET', read_target, status=404)
        capture('foreignScope', 'GET', public.replace(core_id, '9' * 32), status=404)
        capture('unknownCreateField', 'POST', base, body={'label': 'No account', 'order': 0, 'userId': subject}, status=400)
        old_resources = public.replace('/home-people/', '/home-resources/')
        rejected = client.post('/api/v1/admin' + old_resources.removeprefix('/api/v1'), headers=auth(admin),
                              json={'kind': 'person', 'label': 'Not a resource', 'order': 0})
        assert rejected.status_code == 400
        assert client.get('/api/v1/admin/users', headers=auth(admin)).json() == before_users
        assert client.post('/api/v1/auth/logout', headers=auth(member), json={'refreshToken': member['refreshToken']}).status_code == 204
        capture('retiredAccount', 'GET', public, actor=member, status=401)
        return result


def actual_contract(root):
    result = actual_journey(root / 'first')
    result['otherContextList'] = actual_journey(root / 'other', core_id='c' * 32, home_id='d' * 32,
                                               prefix='İkinci ev · ')['adminList']
    return result


def test_fixture_matches_actual_http_auth_sqlite_profile_lifecycle(tmp_path):
    assert actual_contract(tmp_path.resolve()) == json.loads(FIXTURE.read_text())


def test_fixture_preserves_person_only_kind_acl_paging_and_no_auth_material(tmp_path):
    value = actual_contract(tmp_path.resolve())
    first, second = (value[name]['response'] for name in ('firstPage', 'secondPage'))
    assert first['snapshot'] == second['snapshot']
    assert first['entries'] + second['entries'] == value['memberList']['response']['entries']
    assert all(p['ref']['kind'] == 'person' for p in first['entries'] + second['entries'])
    assert len(value['createUnicode']['response']['person']['label']) == 80
    assert value['memberCannotUpdate']['status'] == 403
    assert value['retiredAccount']['status'] == 401
    assert value['afterRevoke']['response'] == {'aclRevision': 4, 'grants': []}
    assert value['deletePerson']['response'] is None
    raw = json.dumps(value)
    assert all(secret not in raw for secret in ('accessToken', 'refreshToken', 'ciphertext', 'password', 'nonce'))


if __name__ == '__main__':
    with TemporaryDirectory(prefix='larenor-people-contract-') as root:
        FIXTURE.write_text(json.dumps(actual_contract(Path(root).resolve()), ensure_ascii=False, indent=2) + '\n')
