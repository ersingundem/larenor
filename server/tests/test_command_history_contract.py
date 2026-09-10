"""Versioned query fixture captured from production auth/SQLite/ASGI + loopback HA."""
import json
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
from unittest.mock import patch
from uuid import UUID

from fastapi.testclient import TestClient

from conftest import Clock, auth, ready
from test_admin import activate, create as create_user
from test_home_assistant_adapter import ha
from test_home_assistant_commands import command_body
from larenor_server.app import create_app
from larenor_server.config import Settings


FIXTURE = Path(__file__).resolve().parents[2] / 'contracts/home-assistant-history.v1.json'


def actual_contract(root):
    upstream = ha.__wrapped__()
    fixture = next(upstream)
    try:
        clock = Clock()
        settings = Settings(root / 'data', root / 'key', clock=clock)
        contexts, identities = iter(('a' * 32, 'b' * 32)), iter(('0' * 32, 'f' * 32))
        with patch('larenor_server.context.secrets', SimpleNamespace(token_hex=lambda _: next(contexts))), \
             patch('larenor_server.core.uuid', SimpleNamespace(uuid4=lambda: UUID(hex=next(identities)))):
            app = create_app(settings)
        with TestClient(app) as client:
            actor = ready((app, client, settings, clock))
            create_user(client, actor)
            member = activate(client, 'member')
            resource_base = '/api/v1/admin/home-resources/' + 'a' * 32 + '/' + 'b' * 32
            with patch('larenor_server.home_resources.service.uuid', SimpleNamespace(uuid4=lambda: UUID(hex='1' * 32))):
                record = client.post(resource_base, headers=auth(actor),
                    json={'kind': 'resource', 'label': 'Synthetic switch', 'order': 0}).json()['record']
            with patch('larenor_server.services.service.uuid', SimpleNamespace(uuid4=lambda: UUID(hex='2' * 32))):
                service = client.post('/api/v1/admin/services', headers=auth(actor), json={
                    'kind': 'home_assistant', 'name': 'Synthetic', 'baseUrl': fixture.url,
                    'credentials': {'token': 'synthetic-ha-only'}})
                assert service.status_code == 201
            public = '/api/v1/home-assistant/' + 'a' * 32 + '/' + 'b' * 32 + '/resources/' + '1' * 32
            admin = public.replace('/api/v1/', '/api/v1/admin/')
            values = iter(('3' * 32, '4' * 32))
            with patch('larenor_server.home_assistant.service.uuid', SimpleNamespace(uuid4=lambda: UUID(hex=next(values)))):
                preview = client.post(admin + '/binding-preview', headers=auth(actor), json={
                    'serviceId': '2' * 32, 'expectedServiceRevision': 1, 'expectedRevision': 1,
                    'expectedAclRevision': 1, 'entityId': 'switch.synthetic', 'expectedBindingId': None})
            assert preview.status_code == 201
            response = client.post(admin + '/binding-confirm', headers=auth(actor),
                json={'previewId': preview.json()['preview']['id']})
            assert response.status_code == 201
            binding = response.json()['binding']
            result = {'schemaVersion': 1, 'context': app.state.core.context.model_dump(),
                'limits': {'page': 50, 'retainedCommands': 1024, 'encryptedCommandBytes': 4096}}

            def capture(name, path, *, pair=actor, expected=200):
                counts = fixture.calls, fixture.command_calls
                reply = client.get(path, headers=auth(pair))
                assert reply.status_code == expected, reply.text
                assert (fixture.calls, fixture.command_calls) == counts
                result[name] = {'method': 'GET', 'path': path.removeprefix('/api/v1'),
                    'status': reply.status_code, 'response': reply.json()}

            capture('empty', public + '/history')
            for identity in ('8', '9'):
                payload = command_body(record, binding, actor, request_id=identity * 32)
                sent = client.post(public + '/commands', headers=auth(actor), json=payload)
                assert sent.status_code == 202
            capture('complete', public + '/history')
            capture('firstPage', public + '/history?limit=1')
            capture('lastPage', public + '/history?before=' + '9' * 32 + '&limit=1')
            capture('hiddenMember', public + '/history', pair=member, expected=404)
            grant_path = resource_base + '/' + '1' * 32 + '/grants/' + member['user']['id']
            assert client.put(grant_path, headers=auth(actor), json={'expectedAclRevision': 1,
                'permissions': {'read': True, 'write': False}}).status_code == 200
            capture('otherActorFiltered', public + '/history', pair=member)
            capture('hiddenCursor', public + '/history?before=' + '9' * 32, pair=member, expected=404)
            capture('invalidLimit', public + '/history?limit=51', expected=400)
            assert fixture.command_calls == 2
            raw = json.dumps(result)
            assert all(secret not in raw for secret in (fixture.url, 'synthetic-ha-only',
                'switch.synthetic', actor['accessToken'], actor['refreshToken']))
            return result
    finally:
        try:
            next(upstream)
        except StopIteration:
            pass


def test_history_contract_matches_actual_authenticated_core_responses(tmp_path):
    assert actual_contract(tmp_path.resolve()) == json.loads(FIXTURE.read_text())


if __name__ == '__main__':
    with TemporaryDirectory(prefix='larenor-history-contract-') as root:
        FIXTURE.write_text(json.dumps(actual_contract(Path(root).resolve()), indent=2) + '\n')
