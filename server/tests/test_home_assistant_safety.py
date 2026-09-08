"""Authority races and bounded persistence regressions for the actual adapter."""
import json
import tracemalloc

import pytest

from conftest import auth
from test_home_assistant_adapter import ha, setup, bind
from larenor_server.home_assistant import schema
from larenor_server.home_assistant.models import Projection


def test_anonymous_core_read_is_401_not_request_validation(server, ha):
    _, client, _, _, _, _, public, _ = setup(server, ha)
    response = client.get(public + '/snapshot')
    assert response.status_code == 401 and response.json()['error']['code'] == 'invalid_session'
    assert ha.calls == 0


def test_cache_is_purged_when_revoked_session_is_rejected_before_route(server, ha):
    app, client, admin, _, _, base, public, body = setup(server, ha)
    bind(client, admin, base, body)
    assert client.get(public + '/snapshot', headers=auth(admin)).status_code == 200
    assert app.state.core.home_assistant._cache
    assert client.post('/api/v1/auth/logout', headers=auth(admin), json={'refreshToken':admin['refreshToken']}).status_code == 204
    before = ha.calls
    assert client.get(public + '/snapshot', headers=auth(admin)).status_code == 401
    assert not app.state.core.home_assistant._cache
    assert ha.calls == before


def test_storage_bound_precedes_materializing_corrupt_payload(server, ha):
    app, client, admin, _, _, base, _, body = setup(server, ha)
    bind(client, admin, base, body)
    with app.state.core.db.transaction() as c:
        c.execute('UPDATE home_assistant_bindings SET ciphertext=zeroblob(4194304)')
    with app.state.core.db.connection() as c:
        tracemalloc.start()
        try:
            with pytest.raises(ValueError):
                schema.rows(c)
            _, peak = tracemalloc.get_traced_memory()
        finally:
            tracemalloc.stop()
    assert peak < 1024 * 1024


@pytest.mark.parametrize('value',[0,1,'false',None])
def test_command_capability_requires_literal_false(value):
    with pytest.raises(ValueError):
        Projection(state='on', commandAvailable=value)


@pytest.mark.parametrize('state,expected',[('on','on'),('off','off'),('unknown','unavailable'),('unavailable','unavailable')])
def test_closed_projection_and_no_upstream_attributes(server, ha, state, expected):
    _, client, admin, _, _, base, public, body = setup(server, ha)
    bind(client, admin, base, body); ha.state=state
    r=client.get(public+'/snapshot',headers=auth(admin))
    assert r.status_code==200 and r.json()['snapshot']['projection']=={'kind':'switch','state':expected,'commandAvailable':False}
    assert all(x not in r.text for x in ('entity_id','attributes','last_updated','synthetic-ha-only','NEVER-PUBLISH'))


@pytest.mark.parametrize('status,code',[(401,'ha_upstream_unauthorized'),(404,'ha_upstream_unavailable'),
    (500,'ha_upstream_unavailable'),(302,'ha_upstream_unavailable'),(204,'ha_upstream_unavailable')])
def test_upstream_status_never_becomes_core_auth_failure_or_retry(server, ha, status, code):
    _, client, admin, _, _, base, public, body = setup(server, ha)
    bind(client,admin,base,body);ha.status=status
    ha.body=b'{"error":"synthetic-ha-only NEVER-PUBLISH"}'
    before=ha.calls;r=client.get(public+'/snapshot',headers=auth(admin))
    assert r.status_code==502 and r.json()['error']['code']==code
    assert 'NEVER-PUBLISH' not in r.text and 'synthetic-ha-only' not in r.text
    assert ha.calls==before+1
    assert client.get('/api/v1/auth/me',headers=auth(admin)).status_code==200


@pytest.mark.parametrize('payload',[
    b'{"entity_id":"switch.other","state":"on"}', b'{"state":"on"}',
    b'{"entity_id":"switch.synthetic","state":"on","state":"off"}',
    b'{"entity_id":"switch.synthetic","state":NaN}',
    b'{"entity_id":"switch.synthetic","state":"armed"}', b'[]', b'null', b'\xff',
    b'{"entity_id":"switch.synthetic","state":true}', b'{' + b'"secret":"' + b'a'*65536 + b'"}',
])
def test_malformed_oversize_and_foreign_entity_responses_are_static(server, ha, payload):
    _, client, admin, _, _, base, public, body=setup(server,ha)
    bind(client,admin,base,body);ha.body=payload
    r=client.get(public+'/snapshot',headers=auth(admin))
    assert r.status_code==502 and len(r.content)<200
    assert 'secret' not in r.text and 'switch.other' not in r.text


@pytest.mark.parametrize('entity',['switch.x\n','switch.X','light.x','switch.x/y','switch.%2f','switch.x?x','switch.'+'x'*122])
def test_entity_selection_is_closed_before_io(server,ha,entity):
    _,client,admin,_,_,base,_,body=setup(server,ha)
    r=client.post(base+'/binding-preview',headers=auth(admin),json={**body,'entityId':entity})
    assert r.status_code==400 and ha.calls==0


@pytest.mark.parametrize('stage',['snapshot','preview'])
@pytest.mark.parametrize('change',['logout','resource','service','deleted'])
def test_authority_and_revisions_are_rechecked_after_actual_network(server,ha,stage,change):
    app,client,admin,record,service,base,public,body=setup(server,ha)
    if stage=='snapshot': bind(client,admin,base,body)
    ref=record['ref'];resource=f'/api/v1/admin/home-resources/{ref["coreId"]}/{ref["homeId"]}/{ref["id"]}'
    def change_during_read():
        ha.during=None
        if change=='logout':
            r=client.post('/api/v1/auth/logout',headers=auth(admin),json={'refreshToken':admin['refreshToken']});assert r.status_code==204
        elif change=='resource':
            r=client.patch(resource,headers=auth(admin),json={'expectedRevision':1,'expectedAclRevision':1,'label':'Changed','order':1});assert r.status_code==200
        elif change=='deleted':
            r=client.delete(resource,headers=auth(admin),params={'expectedRevision':1,'expectedAclRevision':1});assert r.status_code==204
        else:
            r=client.patch('/api/v1/admin/services/'+service['id'],headers=auth(admin),json={'expectedRevision':1,'name':'Changed','baseUrl':ha.url});assert r.status_code==200
    ha.during=change_during_read
    r=(client.get(public+'/snapshot',headers=auth(admin)) if stage=='snapshot' else
       client.post(base+'/binding-preview',headers=auth(admin),json=body))
    assert r.status_code=={'logout':401,'deleted':404,'resource':409,'service':409}[change]
    assert not app.state.core.home_assistant._cache and not app.state.core.home_assistant._previews


def test_monotonic_ttl_wall_clock_regression_and_explicit_rebind(server,ha):
    app,client,admin,_,service,base,public,body=setup(server,ha)
    adapter=app.state.core.home_assistant;now=[100.0];adapter._clock=lambda:now[0]
    preview,binding=bind(client,admin,base,body)
    first=client.get(public+'/snapshot',headers=auth(admin)).json()['snapshot'];before=ha.calls
    now[0]+=4.0;server[3].now-=100
    r=client.get(public+'/snapshot',headers=auth(admin));assert r.status_code==200
    assert r.json()['snapshot']['remainingTtlMs']==1000 and ha.calls==before
    now[0]+=1.0;assert client.get(public+'/snapshot',headers=auth(admin)).status_code==200;assert ha.calls==before+1
    now[0]-=2.0;assert client.get(public+'/snapshot',headers=auth(admin)).status_code==200;assert ha.calls==before+2
    assert client.post(base+'/binding-preview',headers=auth(admin),json=body).status_code==409
    request={**body,'expectedBindingId':binding['id']}
    next_preview,next_binding=bind(client,admin,base,request)
    assert next_binding['id']!=binding['id'] and next_binding['revision']==2
    assert client.get(public+'/snapshot',headers=auth(admin)).json()['snapshot']['bindingId']==next_binding['id']


def test_preview_ttl_restart_and_binding_persistence(server,ha):
    from fastapi.testclient import TestClient
    from larenor_server.app import create_app
    app,client,admin,_,_,base,public,body=setup(server,ha)
    adapter=app.state.core.home_assistant;now=[100.0];adapter._clock=lambda:now[0]
    r=client.post(base+'/binding-preview',headers=auth(admin),json=body);p=r.json()['preview']
    now[0]=160.0
    assert client.post(base+'/binding-confirm',headers=auth(admin),json={'previewId':p['id']}).status_code==409
    _,binding=bind(client,admin,base,body)
    outstanding=client.post(base+'/binding-preview',headers=auth(admin),json={**body,'expectedBindingId':binding['id']}).json()['preview']
    with TestClient(create_app(server[2])) as restarted:
        assert restarted.post(base+'/binding-confirm',headers=auth(admin),json={'previewId':outstanding['id']}).status_code==409
        assert restarted.get(base+'/binding',headers=auth(admin)).json()['binding']==binding
        assert restarted.get(public+'/snapshot',headers=auth(admin)).status_code==200


@pytest.mark.parametrize('sql',[
    "UPDATE home_assistant_bindings SET binding_id='ffffffffffffffffffffffffffffffff'",
    'DELETE FROM home_assistant_bindings',
    "UPDATE home_assistant_state SET authentication_tag='bad'",
    'CREATE UNIQUE INDEX unrelated_name ON home_assistant_bindings(revision)',
    'CREATE TRIGGER unrelated_trigger BEFORE INSERT ON home_assistant_bindings BEGIN SELECT RAISE(IGNORE); END',
    "UPDATE metadata SET value='2' WHERE key='home_assistant_schema'",
    'DROP TABLE home_assistant_state',
])
def test_startup_rejects_tampered_storage_and_preserves_dump(server,ha,sql):
    from larenor_server.app import create_app
    from larenor_server.errors import StartupError
    app,client,admin,_,_,base,_,body=setup(server,ha);bind(client,admin,base,body)
    with app.state.core.db.transaction() as c:c.execute(sql)
    with app.state.core.db.connection() as c:before='\n'.join(c.iterdump())
    with pytest.raises(StartupError):create_app(server[2])
    with app.state.core.db.connection() as c:assert '\n'.join(c.iterdump())==before


def test_invalid_queries_bodies_and_foreign_scopes_have_zero_outbound(server,ha):
    _,client,admin,record,_,base,public,body=setup(server,ha)
    for suffix in ('?foo=1','?a=1&a=2','?refresh=true'):
        assert client.get(public+'/snapshot'+suffix,headers=auth(admin)).status_code==400
    assert client.post(base+'/binding-preview',headers=auth(admin),json={**body,'token':'not-accepted'}).status_code==400
    assert client.get(public.replace(record['ref']['homeId'],'f'*32)+'/snapshot',headers=auth(admin)).status_code==404
    assert ha.calls==0


def test_acl_revocation_during_read_discards_member_result(server,ha):
    from test_admin import activate, create as create_user
    app,client,admin,record,_,base,public,body=setup(server,ha)
    bind(client,admin,base,body);create_user(client,admin);member=activate(client,'member')
    ref=record['ref'];grant=f'/api/v1/admin/home-resources/{ref["coreId"]}/{ref["homeId"]}/{ref["id"]}/grants/{member["user"]["id"]}'
    assert client.put(grant,headers=auth(admin),json={'expectedAclRevision':1,'permissions':{'read':True,'write':False}}).status_code==200
    def revoke():
        ha.during=None
        assert client.put(grant,headers=auth(admin),json={'expectedAclRevision':2,'permissions':{'read':False,'write':False}}).status_code==200
    ha.during=revoke
    assert client.get(public+'/snapshot',headers=auth(member)).status_code==404
    assert not app.state.core.home_assistant._cache


def test_cancel_during_actual_read_discards_projection_and_cache(server,ha):
    from threading import Event
    from larenor_server.errors import ApiError
    app,client,admin,record,_,base,_,body=setup(server,ha);bind(client,admin,base,body)
    actor=app.state.core.auth.authenticate(admin['accessToken']);ref=record['ref'];cancel=Event();ha.during=cancel.set
    with pytest.raises(ApiError) as error:
        app.state.core.home_assistant.snapshot(actor,ref['coreId'],ref['homeId'],ref['id'],cancelled=cancel.is_set)
    assert error.value.code=='request_timeout' and not app.state.core.home_assistant._cache


def test_literal_limits_and_actor_preview_quota_before_outbound(server,ha):
    from larenor_server.home_assistant.service import MAX_PREVIEWS, MAX_ACTOR_PREVIEWS, MAX_CACHE, MAX_USER_CACHE, MAX_CACHE_ENTRY
    assert (MAX_PREVIEWS,MAX_ACTOR_PREVIEWS,MAX_CACHE,MAX_USER_CACHE,MAX_CACHE_ENTRY)==(32,4,256,32,2048)
    _,client,admin,_,_,base,_,body=setup(server,ha)
    previews=[]
    for _ in range(4):
        r=client.post(base+'/binding-preview',headers=auth(admin),json=body);assert r.status_code==201
        previews.append(r.json()['preview'])
    before=ha.calls
    assert client.post(base+'/binding-preview',headers=auth(admin),json=body).status_code==429
    assert ha.calls==before
    assert client.delete(base+'/binding-preview/'+previews[0]['id'],headers=auth(admin)).status_code==204
    assert client.post(base+'/binding-preview',headers=auth(admin),json=body).status_code==201


def test_simultaneous_confirm_consumes_preview_once_without_network(server,ha):
    from concurrent.futures import ThreadPoolExecutor
    _,client,admin,_,_,base,_,body=setup(server,ha)
    preview=client.post(base+'/binding-preview',headers=auth(admin),json=body).json()['preview']
    before=ha.calls
    with ThreadPoolExecutor(max_workers=2) as pool:
        responses=list(pool.map(lambda _:client.post(base+'/binding-confirm',headers=auth(admin),json={'previewId':preview['id']}),range(2)))
    assert sorted(r.status_code for r in responses)==[201,409] and ha.calls==before


def test_service_edit_invalidates_preview_and_requires_fresh_explicit_review(server,ha):
    _,client,admin,_,service,base,_,body=setup(server,ha)
    preview=client.post(base+'/binding-preview',headers=auth(admin),json=body).json()['preview']
    assert client.patch('/api/v1/admin/services/'+service['id'],headers=auth(admin),json={'expectedRevision':1,'baseUrl':ha.url,'name':'New'}).status_code==200
    r=client.post(base+'/binding-confirm',headers=auth(admin),json={'previewId':preview['id']})
    assert r.status_code==409
    assert client.post(base+'/binding-confirm',headers=auth(admin),json={'previewId':preview['id']}).json()['error']['code']=='ha_preview_invalid'
    assert client.get(base+'/binding',headers=auth(admin)).status_code==404


def test_room_target_and_wrong_service_kind_have_no_outbound(server,ha):
    _,client,admin,record,service,base,_,body=setup(server,ha)
    ref=record['ref'];path=f'/api/v1/admin/home-resources/{ref["coreId"]}/{ref["homeId"]}'
    room=client.post(path,headers=auth(admin),json={'kind':'room','label':'Room','order':0}).json()['record']
    assert client.post(base.replace(ref['id'],room['ref']['id'])+'/binding-preview',headers=auth(admin),json=body).status_code==404
    other=client.post('/api/v1/admin/services',headers=auth(admin),json={'kind':'jellyfin','name':'Other','baseUrl':ha.url,'credentials':{'token':'synthetic-ha-only'}}).json()['service']
    assert client.post(base+'/binding-preview',headers=auth(admin),json={**body,'serviceId':other['id']}).status_code==409
    assert ha.calls==0


def test_deadline_closes_real_loopback_request_without_retry(server,ha,monkeypatch):
    import time
    import larenor_server.home_assistant.transport as transport
    _,client,admin,_,_,base,public,body=setup(server,ha);bind(client,admin,base,body)
    monkeypatch.setattr(transport,'TIMEOUT',0.10)
    ha.during=lambda:time.sleep(0.3)
    before=ha.calls;start=time.monotonic();r=client.get(public+'/snapshot',headers=auth(admin))
    assert r.status_code==502 and r.json()['error']['code']=='ha_upstream_unavailable'
    assert time.monotonic()-start<2 and ha.calls==before+1


def test_actual_user_and_global_cache_eviction_limits(server,ha,monkeypatch):
    """Exercise 32/user and256/global with actual authorized resource requests.

    Independent account request-rate policy is disabled only in this quota
    fixture; ACL/authentication and the production cache limits remain real.
    """
    from test_admin import activate, create as create_user
    app,client,admin,first,_,base,public,body=setup(server,ha)
    adapter=app.state.core.home_assistant;adapter._clock=lambda:100.0
    monkeypatch.setattr(app.state.core.auth,'rate_limit',lambda *args,**kwargs:None)
    ref=first['ref'];resource_base=f'/api/v1/admin/home-resources/{ref["coreId"]}/{ref["homeId"]}'
    resources=[first]
    for i in range(32):
        r=client.post(resource_base,headers=auth(admin),json={'kind':'resource','label':f'Switch {i}','order':i})
        assert r.status_code==201;resources.append(r.json()['record'])
    for resource in resources:
        _,binding=bind(client,admin,base.replace(ref['id'],resource['ref']['id']),body)
    members=[]
    for i in range(9):
        create_user(client,admin,f'cache{i}');members.append(activate(client,f'cache{i}'))
        for resource in resources[:32]:
            r=client.put(resource_base+'/'+resource['ref']['id']+'/grants/'+members[-1]['user']['id'],
                headers=auth(admin),json={'expectedAclRevision':i+1,'permissions':{'read':True,'write':False}})
            assert r.status_code==200
    for resource in resources:
        assert client.get(public.replace(ref['id'],resource['ref']['id'])+'/snapshot',headers=auth(admin)).status_code==200
    assert len(adapter._cache)==32
    assert not any(k[4]==first['ref']['id'] for k in adapter._cache)
    for member in members:
        for resource in resources[:32]:
            r=client.get(public.replace(ref['id'],resource['ref']['id'])+'/snapshot',headers=auth(member))
            assert r.status_code==200
    assert len(adapter._cache)==256
    assert max(sum(k[2]==user for k in adapter._cache) for user in {k[2] for k in adapter._cache})==32
    assert not any(k[2]==admin['user']['id'] for k in adapter._cache)
    assert not any(k[2]==members[0]['user']['id'] for k in adapter._cache)


def test_global_preview_quota_never_dispatches_the_thirty_third_read(server,ha,monkeypatch):
    from test_admin import activate, create as create_user
    app,client,admin,_,_,base,_,body=setup(server,ha)
    app.state.core.home_assistant._clock=lambda:100.0
    monkeypatch.setattr(app.state.core.auth,'rate_limit',lambda *args,**kwargs:None)
    actors=[admin]
    for i in range(8):
        create_user(client,admin,f'preview{i}',role='admin');actors.append(activate(client,f'preview{i}'))
    for actor in actors[:8]:
        for _ in range(4):
            assert client.post(base+'/binding-preview',headers=auth(actor),json=body).status_code==201
    assert len(app.state.core.home_assistant._previews)==32
    before=ha.calls
    assert client.post(base+'/binding-preview',headers=auth(actors[8]),json=body).status_code==429
    assert ha.calls==before


@pytest.mark.parametrize('helper',['v1','v2'])
def test_pre_adapter_legacy_fixtures_have_no_future_binding_domain(server,helper):
    from test_admin_migration import downgrade_to_known_v1
    from test_core_context import legacy_v2
    app=server[0]
    (downgrade_to_known_v1 if helper=='v1' else legacy_v2)(app)
    with app.state.core.db.connection() as c:
        assert c.execute("SELECT name FROM sqlite_master WHERE name GLOB 'home_assistant_*' OR tbl_name GLOB 'home_assistant_*'").fetchall()==[]
        assert c.execute("SELECT value FROM metadata WHERE key='home_assistant_schema'").fetchone() is None


@pytest.mark.parametrize('column',['resource_id','binding_id','authentication_tag'])
def test_storage_metadata_is_bounded_before_materialization(server,ha,column):
    app,client,admin,_,_,base,_,body=setup(server,ha);bind(client,admin,base,body)
    table='home_assistant_state' if column=='authentication_tag' else 'home_assistant_bindings'
    with app.state.core.db.transaction() as c:
        c.execute(f"UPDATE {table} SET {column}=replace(hex(zeroblob(2097152)),'0','f')")
    with app.state.core.db.connection() as c:
        tracemalloc.start()
        try:
            with pytest.raises(ValueError):
                schema.validate(c,app.state.core.home_assistant._key,app.state.core.home_resources.scope)
            _,peak=tracemalloc.get_traced_memory()
        finally:tracemalloc.stop()
    assert peak<1024*1024


def test_non_ascii_invalid_core_token_keeps_401_and_other_cached_data(server,ha):
    app,client,admin,_,_,base,public,body=setup(server,ha);bind(client,admin,base,body)
    assert client.get(public+'/snapshot',headers=auth(admin)).status_code==200
    before=dict(app.state.core.home_assistant._cache);calls=ha.calls
    import asyncio
    import httpx
    async def raw_request():
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app),base_url='http://testserver') as raw:
            return await raw.get(public+'/snapshot',headers=[(b'authorization',b'Bearer '+b'\xe9'*43)])
    response=asyncio.run(raw_request())
    assert response.status_code==401 and response.json()['error']['code']=='invalid_session'
    assert app.state.core.home_assistant._cache==before and ha.calls==calls
