"""Real Core/auth/SQLite and owned loopback HA; no real home operations."""
from fastapi.testclient import TestClient
import pytest

from conftest import auth, ready
from test_home_assistant_adapter import ha
from larenor_server.app import create_app


def setup_transfer(server, ha):
    app, client, _, _ = server
    admin = ready(server)
    scope = app.state.core.context
    path = f'/api/v1/admin/home-resources/{scope.coreId}/{scope.homeId}'
    response = client.post(path, headers=auth(admin), json={'kind': 'resource', 'label': 'Chosen switch', 'order': 0})
    assert response.status_code == 201
    resource = response.json()['record']
    base = f'/api/v1/admin/home-assistant/{scope.coreId}/{scope.homeId}/resources/{resource["ref"]["id"]}'
    body = {'requestId': 'c'*32, 'name': 'Transferred HA', 'baseUrl': ha.url,
            'token': 'synthetic-ha-only', 'entityId': 'switch.synthetic',
            'expectedRevision': 1, 'expectedAclRevision': 1}
    return app, client, admin, resource, path, base, body


def stored(app):
    with app.state.core.db.connection() as c:
        tables = ('service_connections', 'home_assistant_bindings', 'home_assistant_state', 'service_audit')
        return {table: [tuple(r) for r in c.execute(f'SELECT * FROM {table} ORDER BY 1')] for table in tables}


def preview(client, admin, base, body):
    response = client.post(base+'/direct-migration/preview', headers=auth(admin), json=body)
    assert response.status_code == 201, response.text
    return response.json()['preview']


def confirm(client, admin, base, body, p):
    return client.post(base+'/direct-migration/confirm', headers=auth(admin), json={**body, 'previewId': p['id']})


def test_preview_cancel_then_atomic_confirm_and_restart_result_without_replaying(server, ha):
    app, client, admin, resource, _, base, body = setup_transfer(server, ha)
    before = stored(app)
    p = preview(client, admin, base, body)
    assert stored(app) == before
    assert p['requestId'] == body['requestId'] and p['binding']['ref'] == resource['ref']
    assert p['projection'] == {'kind': 'switch', 'state': 'off', 'commandAvailable': False}
    assert body['token'] not in str(p) and 'NEVER-PUBLISH' not in str(p)
    assert client.delete(base+'/direct-migration/preview/'+p['id'], headers=auth(admin)).status_code == 204
    assert confirm(client, admin, base, body, p).status_code == 409
    assert stored(app) == before
    body = {**body, 'requestId': 'd'*32}
    p = preview(client, admin, base, body)
    calls = ha.calls
    response = confirm(client, admin, base, body, p)
    assert response.status_code == 201, response.text
    receipt = response.json()['receipt']
    assert receipt['status'] == 'committed' and receipt['binding'] == p['binding'] and receipt['service'] == p['service']
    assert receipt['ref'] == resource['ref'] and ha.calls == calls and ha.command_calls == 0
    after = stored(app)
    assert len(after['service_connections']) == len(after['home_assistant_bindings']) == 1
    assert body['token'] not in str(after) and body['token'] not in str(receipt)
    assert confirm(client, admin, base, body, p).json()['receipt'] == receipt
    assert stored(app) == after and ha.calls == calls
    with TestClient(create_app(server[2])) as restarted:
        result = restarted.get(base+'/direct-migration/results/'+body['requestId'], headers=auth(admin))
        assert result.status_code == 200 and result.json()['receipt'] == receipt
        assert stored(app) == after and ha.calls == calls
        public = base.replace('/admin/home-assistant/', '/home-assistant/')
        assert restarted.get(public+'/snapshot', headers=auth(admin)).status_code == 200
    assert ha.command_calls == 0


@pytest.mark.parametrize('drift', ['source', 'resource', 'acl'])
def test_source_or_target_drift_cannot_create_partial_configuration(server, ha, drift):
    app, client, admin, resource, path, base, body = setup_transfer(server, ha)
    p = preview(client, admin, base, body)
    if drift == 'source':
        body = {**body, 'token': 'different-synthetic-token'}
    elif drift == 'resource':
        assert client.patch(path+'/'+resource['ref']['id'], headers=auth(admin), json={
            'expectedRevision': 1, 'expectedAclRevision': 1, 'label': 'Changed', 'order': 1}).status_code == 200
    else:
        from test_admin import create, activate
        create(client, admin); member = activate(client, 'member')
        assert client.put(path+'/'+resource['ref']['id']+'/grants/'+member['user']['id'], headers=auth(admin),
            json={'expectedAclRevision': 1, 'permissions': {'read': True, 'write': False}}).status_code == 200
    before = stored(app); calls = ha.calls
    assert confirm(client, admin, base, body, p).status_code == 409
    assert stored(app) == before and ha.calls == calls and ha.command_calls == 0


@pytest.mark.parametrize('fault', ['binding_abort', 'binding_ignore', 'receipt_abort', 'commit'])
def test_second_insert_or_commit_failure_rolls_back_service_binding_and_receipt(server, ha, fault):
    app, client, admin, _, _, base, body = setup_transfer(server, ha)
    p = preview(client, admin, base, body)
    with app.state.core.db.transaction() as c:
        if fault == 'commit':
            c.execute('CREATE TABLE synthetic_deferred(id TEXT REFERENCES users(id) DEFERRABLE INITIALLY DEFERRED)')
        trigger = {
            'binding_abort': "BEFORE INSERT ON home_assistant_bindings BEGIN SELECT RAISE(ABORT,'synthetic'); END",
            'binding_ignore': 'BEFORE INSERT ON home_assistant_bindings BEGIN SELECT RAISE(IGNORE); END',
            'receipt_abort': "BEFORE INSERT ON direct_ha_migrations BEGIN SELECT RAISE(ABORT,'synthetic'); END",
            'commit': "AFTER INSERT ON direct_ha_migrations BEGIN INSERT INTO synthetic_deferred VALUES('missing'); END",
        }[fault]
        c.execute('CREATE TRIGGER synthetic_failure '+trigger)
    before = stored(app); calls = ha.calls
    response = confirm(client, admin, base, body, p)
    assert response.status_code == 503, response.text
    assert stored(app) == before and ha.calls == calls and ha.command_calls == 0
    result = client.get(base+'/direct-migration/results/'+body['requestId'], headers=auth(admin))
    assert result.status_code == 404
    with app.state.core.db.transaction() as c:
        assert c.execute('SELECT COUNT(*) FROM direct_ha_migrations').fetchone()[0] == 0
        c.execute('DROP TRIGGER synthetic_failure')
    assert confirm(client, admin, base, body, p).status_code == 409


def test_existing_binding_and_member_cannot_start_transfer(server, ha):
    app, client, admin, resource, _, base, body = setup_transfer(server, ha)
    p = preview(client, admin, base, body)
    assert confirm(client, admin, base, body, p).status_code == 201
    before = stored(app); calls = ha.calls
    assert client.post(base+'/direct-migration/preview', headers=auth(admin),
        json={**body, 'requestId': 'e'*32}).status_code == 409
    from test_admin import create, activate
    create(client, admin); member = activate(client, 'member')
    assert client.post(base+'/direct-migration/preview', headers=auth(member), json=body).status_code == 403
    assert stored(app) == before and ha.calls == calls and ha.command_calls == 0


@pytest.mark.parametrize('fault', ['late_service_delete', 'late_binding_delete', 'late_service_revision',
    'receipt_ignore', 'receipt_tag_ignore'])
def test_final_receipt_cannot_acknowledge_later_storage_damage(server, ha, fault):
    app, client, admin, _, _, base, body = setup_transfer(server, ha)
    p = preview(client, admin, base, body)
    triggers = {
        'late_service_delete': 'AFTER INSERT ON direct_ha_migrations BEGIN DELETE FROM service_connections; END',
        'late_binding_delete': 'AFTER INSERT ON direct_ha_migrations BEGIN DELETE FROM home_assistant_bindings; END',
        'late_service_revision': 'AFTER INSERT ON direct_ha_migrations BEGIN UPDATE service_connections SET revision=2; END',
        'receipt_ignore': 'BEFORE INSERT ON direct_ha_migrations BEGIN SELECT RAISE(IGNORE); END',
        'receipt_tag_ignore': 'BEFORE UPDATE ON direct_ha_state BEGIN SELECT RAISE(IGNORE); END',
    }
    with app.state.core.db.transaction() as c:
        c.execute('CREATE TRIGGER synthetic_final_failure '+triggers[fault])
    before = stored(app); calls = ha.calls
    response = confirm(client, admin, base, body, p)
    assert response.status_code == 503, response.text
    assert stored(app) == before and ha.calls == calls and ha.command_calls == 0
    with app.state.core.db.connection() as c:
        assert c.execute('SELECT COUNT(*) FROM direct_ha_migrations').fetchone()[0] == 0


def test_ignored_first_service_insert_is_storage_failure_not_missing_user_target(server,ha):
    app,client,admin,_,_,base,body=setup_transfer(server,ha)
    p=preview(client,admin,base,body)
    with app.state.core.db.transaction() as c:
        c.execute('CREATE TRIGGER synthetic_service_ignore BEFORE INSERT ON service_connections '
            'BEGIN SELECT RAISE(IGNORE); END')
    before=stored(app);calls=ha.calls
    response=confirm(client,admin,base,body,p)
    assert response.status_code==503, response.text
    assert response.json()['error']['code']=='server_unavailable'
    assert stored(app)==before and ha.calls==calls
    with app.state.core.db.connection() as c:
        assert c.execute('SELECT COUNT(*) FROM direct_ha_migrations').fetchone()[0]==0


def test_dropped_core_response_after_commit_recovers_only_by_restart_get(server,ha):
    """Actual ASGI response delivery fails after DB commit, not before handler."""
    import asyncio
    import httpx
    app,client,admin,_,_,base,body=setup_transfer(server,ha)
    p=preview(client,admin,base,body);calls=ha.calls;starts=[]
    async def lost_ack(scope,receive,send):
        assert scope['path']==base+'/direct-migration/confirm'
        async def discard(message):
            if message['type']=='http.response.start':
                starts.append(message['status'])
                assert message['status']==201
                raise ConnectionResetError('synthetic lost Core response')
            await send(message)
        await app(scope,receive,discard)
        # Starlette may treat OSError from ASGI send as a client disconnect
        # and return normally. The caller still received no response bytes.
        assert starts==[201]
        raise ConnectionResetError('synthetic caller lost Core response')
    async def dispatch_once():
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=lost_ack),base_url='http://testserver') as lost:
            with pytest.raises(ConnectionResetError):
                await lost.post(base+'/direct-migration/confirm',headers=auth(admin),json={**body,'previewId':p['id']})
    asyncio.run(dispatch_once())
    assert starts==[201] and ha.calls==calls
    with TestClient(create_app(server[2])) as restarted:
        recovered=restarted.get(base+'/direct-migration/results/'+body['requestId'],headers=auth(admin))
        assert recovered.status_code==200 and recovered.json()['receipt']['binding']==p['binding']
        assert len(stored(app)['service_connections'])==len(stored(app)['home_assistant_bindings'])==1
    assert starts==[201] and ha.calls==calls and ha.command_calls==0
