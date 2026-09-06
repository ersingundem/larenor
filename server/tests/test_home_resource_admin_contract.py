"""Versioned metadata-only mutation fixtures from actual authenticated SQLite HTTP."""
import json
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
from uuid import UUID

from fastapi.testclient import TestClient

from conftest import Clock, auth, ready
from test_admin import activate, create as create_user
from test_home_resource_registry import grant, paths
from larenor_server.app import create_app
from larenor_server.config import Settings


FIXTURE = Path(__file__).resolve().parents[2] / 'contracts/home-resource-admin.v1.json'


def actual_contract(root):
    clock = Clock()
    settings = Settings(root / 'data', root / 'secrets/vault.key', clock=clock)
    identities = iter(('a' * 32, 'b' * 32))
    with patch('larenor_server.context.secrets',
               SimpleNamespace(token_hex=lambda _: next(identities))):
        app = create_app(settings)
    with TestClient(app) as client:
        admin = ready((app, client, settings, clock))
        create_user(client, admin)
        member = activate(client, 'member')
        public, base = paths(app)
        result = {'schemaVersion': 1, 'context': app.state.core.context.model_dump()}

        def capture(name, method, path, *, body=None, query=None, pair=admin, expected=200):
            response = client.request(method, path, headers=auth(pair), json=body, params=query)
            assert response.status_code == expected, response.text
            result[name] = {
                'method': method, 'path': path.removeprefix('/api/v1'),
                'body': body, 'query': query, 'status': response.status_code,
                'response': response.json() if response.content else None,
            }
            return result[name]['response']

        record_ids = iter(('1' * 32, '2' * 32))
        with patch('larenor_server.home_resources.service.uuid',
                   SimpleNamespace(uuid4=lambda: UUID(hex=next(record_ids)))):
            room = capture('createRoom', 'POST', base, expected=201,
                           body={'kind': 'room', 'label': 'Salon', 'order': 1})['record']
            capture('createResource', 'POST', base, expected=201,
                    body={'kind': 'resource', 'label': '🌿' * 80, 'order': 10000})
        grant(client, admin, base, room, member['user']['id'], write=False)
        target = base + '/' + room['ref']['id']
        # The opaque account ID is intentionally absent from exported metadata.
        result['beforeUpdate'] = client.get(public + '/' + room['ref']['id'], headers=auth(admin)).json()
        capture('updateRoom', 'PATCH', target,
                body={'expectedRevision': 1, 'expectedAclRevision': 2,
                      'label': 'Yeni oda', 'order': 3})
        capture('noopRoom', 'PATCH', target,
                body={'expectedRevision': 2, 'expectedAclRevision': 2,
                      'label': 'Yeni oda', 'order': 3})
        capture('staleUpdate', 'PATCH', target, expected=409,
                body={'expectedRevision': 1, 'expectedAclRevision': 2,
                      'label': 'Eski istek', 'order': 3})
        capture('memberUpdate', 'PATCH', target, pair=member, expected=403,
                body={'expectedRevision': 2, 'expectedAclRevision': 2,
                      'label': 'İzinsiz', 'order': 3})
        capture('deleteRoom', 'DELETE', target, expected=204,
                query={'expectedRevision': '2', 'expectedAclRevision': '2'})
        capture('deletedRead', 'GET', public + '/' + room['ref']['id'], expected=404)
        return result


def test_fixture_matches_actual_create_acl_rename_noop_delete_http(tmp_path):
    actual = actual_contract(tmp_path.resolve())
    assert actual == json.loads(FIXTURE.read_text())


def test_actual_mutations_preserve_scope_acl_and_server_generated_identity(tmp_path):
    value = actual_contract(tmp_path.resolve())
    before = value['beforeUpdate']['record']
    updated = value['updateRoom']['response']['record']
    noop = value['noopRoom']['response']['record']
    assert before['ref'] == updated['ref'] == noop['ref']
    assert before['revision'] == 1 and updated['revision'] == noop['revision'] == 2
    assert before['aclRevision'] == updated['aclRevision'] == noop['aclRevision'] == 2
    assert updated == noop
    assert value['deleteRoom']['status'] == 204 and value['deleteRoom']['response'] is None
    assert value['staleUpdate']['status'] == 409 and value['memberUpdate']['status'] == 403
    assert len(value['createResource']['response']['record']['label']) == 80
    raw = json.dumps(value)
    assert all(secret not in raw for secret in ('accessToken', 'refreshToken', 'ciphertext', 'password', 'grants', 'subjectId'))
