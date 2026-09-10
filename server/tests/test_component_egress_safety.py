import copy
import io
import json
import socket
import sqlite3

import pytest
from fastapi.testclient import TestClient
from conftest import auth, ready, login, bootstrap_password
from test_admin import create as create_user, activate
from test_services import BASE, SECRET, create
from test_component_egress import policy_url, check_url, grant_body
from larenor_server.app import create_app
from larenor_server.errors import StartupError
from larenor_server.services.transport import ServiceTransport


def setup(server, *, scheme='http'):
    app, client, _, _ = server
    pair = ready(server)
    record = create(client, pair, baseUrl=scheme+'://ha.example.test')
    body = grant_body()
    body['grants'][0].update(scheme=scheme, port=80 if scheme == 'http' else 443)
    response = client.put(policy_url(record), headers=auth(pair), json=body)
    assert response.status_code == 200, response.text
    return app, client, pair, record, body


class Wire:
    def __init__(self, peer, *, status=200, on_send=lambda: None, on_read=lambda: None):
        body = json.dumps({'version':'2026.9.0', 'components':['api']}).encode()
        self.data = io.BytesIO(f'HTTP/1.1 {status} Fixture\r\nContent-Type: application/json\r\nContent-Length: {len(body)}\r\nLocation: http://169.254.169.254/secret\r\n\r\n'.encode()+body)
        self.peer, self.sent, self.closed = peer, [], False
        self.on_send, self.on_read = on_send, on_read
    def settimeout(self, _): pass
    def getpeername(self): return self.peer
    def sendall(self, data): self.sent.append(data); self.on_send()
    def recv(self, size):
        callback, self.on_read = self.on_read, lambda: None
        callback()
        return self.data.read(size)
    def close(self): self.closed = True
    def shutdown(self, _): pass


def network(monkeypatch, *, ips=('10.20.30.40',), peer=None, on_dns=lambda: None, on_connect=lambda: None, **wire_options):
    calls, wires = [], []
    def resolver(host, port):
        calls.append(('dns', host, port)); on_dns()
        return [(socket.AF_INET6 if ':' in ip else socket.AF_INET, socket.SOCK_STREAM, 6, '',
                 (ip, port, 0, 0) if ':' in ip else (ip, port)) for ip in ips]
    def connector(family, address, timeout):
        calls.append(('connect', family, address)); on_connect()
        wire = Wire(peer or address, **wire_options); wires.append(wire); return wire
    original = ServiceTransport.__init__
    def init(self, *args, **kwargs):
        original(self, *args, **kwargs, resolver=resolver, connector=connector)
    monkeypatch.setattr(ServiceTransport, '__init__', init)
    return calls, wires


def test_actual_packaged_probe_emits_only_pinned_request_and_attributed_audit(server, monkeypatch):
    app, client, pair, record, _ = setup(server)
    def sent():
        result = client.get(policy_url(record), headers=auth(pair)).json()
        assert result['audit'][-1]['reason'] == 'dispatch_authorized'
    calls, wires = network(monkeypatch, on_send=sent)
    response = client.post(check_url(record), headers=auth(pair), json={'expectedRevision':1})
    assert response.status_code == 200, response.text
    assert response.json()['service']['verification']['state'] == 'authenticated'
    assert calls == [('dns','ha.example.test',80), ('connect',socket.AF_INET,('10.20.30.40',80))]
    assert len(wires) == 1 and wires[0].closed
    assert wires[0].sent[0].startswith(b'GET /api/config HTTP/1.1\r\nHost: ha.example.test\r\n')
    audit = client.get(policy_url(record), headers=auth(pair)).json()['audit']
    assert [e['reason'] for e in audit] == ['policy_replaced','dispatch_authorized','probe_completed']
    assert audit[-2]['correlationId'] == audit[-1]['correlationId']
    assert audit[-1]['actorId'] == pair['user']['id'] and audit[-1]['source'] == 'core_api'
    assert SECRET not in json.dumps(audit)
    with app.state.core.db.connection() as c:
        dump = '\n'.join(c.iterdump())
    assert '10.20.30.40' not in dump and SECRET not in dump


@pytest.mark.parametrize('ips', [('10.20.30.41',), ('8.8.8.8',), ('10.20.30.40','10.20.30.41'),
                               ('::ffff:10.20.30.40',), ('169.254.169.254',), ('127.0.0.1',)])
def test_all_dns_answers_must_be_explicit_pins_before_any_connect(server, monkeypatch, ips):
    _, client, pair, record, _ = setup(server)
    calls, wires = network(monkeypatch, ips=ips)
    response = client.post(check_url(record), headers=auth(pair), json={'expectedRevision':1})
    assert response.status_code == 403, response.text
    assert response.json()['error']['code'] == 'outbound_denied'
    assert len(calls) == 1 and wires == []


@pytest.mark.parametrize('stage', ['dns', 'connect', 'read'])
def test_policy_revocation_at_each_boundary_retires_check_without_later_send(server, monkeypatch, stage):
    _, client, pair, record, body = setup(server)
    def revoke():
        response = client.put(policy_url(record), headers=auth(pair), json={**body,'expectedRevision':1,'grants':[]})
        assert response.status_code == 200
    options = {'on_'+stage:revoke}
    calls, wires = network(monkeypatch, **options)
    response = client.post(check_url(record), headers=auth(pair), json={'expectedRevision':1})
    assert response.status_code == 403, response.text
    assert all(not w.sent for w in wires) if stage != 'read' else len(wires[0].sent) == 1
    assert all(w.closed for w in wires)
    saved = client.get(BASE, headers=auth(pair)).json()['services'][0]
    assert saved['verification']['state'] == 'never'


def test_peer_mismatch_and_redirect_do_not_forward_credentials_or_follow(server, monkeypatch):
    _, client, pair, record, _ = setup(server)
    calls, wires = network(monkeypatch, peer=('10.20.30.41',80))
    response = client.post(check_url(record), headers=auth(pair), json={'expectedRevision':1})
    assert response.status_code == 403, response.text
    assert len(wires) == 1 and not wires[0].sent and wires[0].closed
    monkeypatch.undo()
    calls, wires = network(monkeypatch, status=302)
    response = client.post(check_url(record), headers=auth(pair), json={'expectedRevision':1})
    assert response.status_code == 200 and response.json()['service']['verification']['state'] == 'unsupported'
    assert len(wires) == 1 and len(calls) == 2 and wires[0].closed


def test_reconnect_resolves_again_and_never_retries_new_ungranted_dns(server, monkeypatch):
    _, client, pair, record, _ = setup(server)
    calls, wires = network(monkeypatch)
    assert client.post(check_url(record), headers=auth(pair), json={'expectedRevision':1}).status_code == 200
    monkeypatch.undo()
    calls, wires = network(monkeypatch, ips=('10.20.30.41',))
    assert client.post(check_url(record), headers=auth(pair), json={'expectedRevision':1}).status_code == 403
    assert len(calls) == 1 and not wires


@pytest.mark.parametrize('change', ['service', 'logout'])
def test_current_authority_checked_after_connection_before_secret_send(server, monkeypatch, change):
    _, client, pair, record, _ = setup(server)
    def retire():
        if change == 'logout':
            assert client.post('/api/v1/auth/logout', headers=auth(pair), json={}).status_code == 204
        else:
            assert client.patch(BASE+'/'+record['id'], headers=auth(pair), json={'expectedRevision':1,'name':'Changed','baseUrl':record['baseUrl'],'credentials':{}}).status_code == 200
    _, wires = network(monkeypatch, on_connect=retire)
    response = client.post(check_url(record), headers=auth(pair), json={'expectedRevision':1})
    assert response.status_code == (401 if change == 'logout' else 409), response.text
    assert len(wires) == 1 and wires[0].closed and not wires[0].sent


@pytest.mark.parametrize('change', ['scheme','host','port','revision','wildcard','cidr','duplicate','extra','bool'])
def test_closed_exact_policy_contract(server, change):
    _, client, pair, record, body = setup(server)
    body = copy.deepcopy(body); body['expectedRevision'] = 1
    grant = body['grants'][0]
    if change == 'scheme': grant['scheme'] = 'https'
    if change == 'host': grant['host'] = 'other.example.test'
    if change == 'port': grant['port'] = 9999
    if change == 'revision': body['expectedServiceRevision'] = 2
    if change == 'wildcard': grant['host'] = '*.example.test'
    if change == 'cidr': grant['addresses'][0]['address'] = '10.20.30.0/24'
    if change == 'duplicate': grant['addresses'] *= 2
    if change == 'extra': body['proxy'] = 'http://secret'
    if change == 'bool': body['expectedRevision'] = True
    response = client.put(policy_url(record), headers=auth(pair), json=body)
    assert response.status_code == (409 if change == 'revision' else 400), response.text
    assert client.get(policy_url(record), headers=auth(pair)).json()['policy']['revision'] == 1


def test_admin_only_foreign_kind_unknown_duplicate_query_and_headers(server):
    _, client, settings, _ = server
    initial = login(client,'admin',bootstrap_password(settings)).json()
    url = BASE+'/'+('a'*32)+'/outbound-policy'
    assert client.get(url).status_code == 401
    assert client.get(url,headers=auth(initial)).status_code == 403
    _, client, pair, record, _ = setup(server)
    create_user(client,pair); member = activate(client,'member')
    assert client.get(policy_url(record),headers=auth(member)).status_code == 403
    other = create(client,pair,kind='jellyfin')
    assert client.get(policy_url(other),headers=auth(pair)).status_code == 404
    for suffix in ('?x=1','?revision=1&revision=1'):
        assert client.get(policy_url(record)+suffix,headers=auth(pair)).status_code == 400
    assert client.get(policy_url(record),headers=[('Authorization',auth(pair)['Authorization'])]*2).status_code == 400


def test_policy_encrypted_restart_and_legacy_migration_never_grant(server):
    app, client, pair, record, _ = setup(server)
    settings=server[2]
    with TestClient(create_app(settings)) as restarted:
        assert restarted.get(policy_url(record),headers=auth(pair)).json()['policy']['revision'] == 1
    with app.state.core.db.transaction() as c:
        old = [tuple(r) for r in c.execute('SELECT * FROM service_connections')]
        c.execute('DROP TABLE component_egress_state')
        c.execute("DELETE FROM metadata WHERE key='component_egress_schema'")
    with TestClient(create_app(settings)) as migrated:
        assert migrated.get(policy_url(record),headers=auth(pair)).json()['policy']['grants'] == []
        assert migrated.post(check_url(record),headers=auth(pair),json={'expectedRevision':1}).status_code == 403
    with app.state.core.db.connection() as c:
        assert [tuple(r) for r in c.execute('SELECT * FROM service_connections')] == old


@pytest.mark.parametrize('sql', ['DELETE FROM component_egress_state', "UPDATE component_egress_state SET ciphertext=zeroblob(1048577)", "UPDATE component_egress_state SET nonce=zeroblob(12)", 'CREATE TRIGGER hidden AFTER UPDATE ON component_egress_state BEGIN SELECT 1; END'])
def test_corrupt_storage_fails_closed_without_repair_or_probe(server, monkeypatch, sql):
    app, client, pair, record, _ = setup(server)
    with app.state.core.db.transaction() as c: c.execute(sql)
    with app.state.core.db.connection() as c: before='\n'.join(c.iterdump())
    calls,wires=network(monkeypatch)
    assert client.get(policy_url(record),headers=auth(pair)).status_code == 503
    assert client.post(check_url(record),headers=auth(pair),json={'expectedRevision':1}).status_code == 503
    with pytest.raises(StartupError,match='component_egress_storage_invalid'): create_app(server[2])
    with app.state.core.db.connection() as c:
        # Auth/rate counters can change; encrypted policy rows and schema cannot.
        assert c.execute('SELECT sql FROM sqlite_master WHERE name="component_egress_state"').fetchone()[0] in before
    assert calls == [] and wires == []
