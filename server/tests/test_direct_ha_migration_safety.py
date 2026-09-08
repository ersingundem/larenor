"""Closed transfer inputs and actual authority/transaction races."""
import json
from concurrent.futures import ThreadPoolExecutor
from fastapi.testclient import TestClient
import pytest
from conftest import auth
from test_direct_ha_migration import setup_transfer, stored, preview, confirm
from test_home_assistant_adapter import ha
from larenor_server.app import create_app
from larenor_server.errors import ApiError
from larenor_server.home_assistant.migration_models import MigrationInput


@pytest.mark.parametrize('field,value', [
    ('token',''),('token','x'*2049),('token','a b'),('token','a\n'),('token','é'),('token','a\x7f'),
    ('baseUrl','http://user:secret@example.invalid'),('baseUrl','http://example.invalid/#secret'),
    ('entityId','light.x'),('entityId','switch.x\n'),('entityId','switch.X'),('entityId','switch.x/y'),
    ('entityId','switch.'+'x'*122),('expectedRevision',True),('expectedAclRevision',0),
    ('requestId','A'*32),('requestId','a'*32+'\n'),('name','\x00secret'),('name','  '),('extra','secret')])
def test_invalid_transfer_is_static_before_credentials_leave_server(server,ha,field,value):
    app,client,admin,_,_,base,body=setup_transfer(server,ha)
    before=stored(app)
    r=client.post(base+'/direct-migration/preview',headers=auth(admin),json={**body,field:value})
    assert r.status_code==400 and r.json()['error']['code']=='invalid_request'
    assert len(r.content)<200 and 'secret' not in r.text
    assert stored(app)==before and ha.calls==ha.command_calls==0


@pytest.mark.parametrize('kind',['room','person'])
def test_non_resource_target_is_hidden_before_outbound(server,ha,kind):
    app,client,admin,_,path,base,body=setup_transfer(server,ha)
    # Only room is this registry's supported alternate kind; a missing person ID
    # exercises the same closed resource route without creating a person.
    if kind=='room':
        r=client.post(path,headers=auth(admin),json={'kind':'room','label':'Room','order':0})
        assert r.status_code==201
        target=r.json()['record']['ref']['id']
    else: target='0'*32
    base=base.rsplit('/',1)[0]+'/'+target
    assert client.post(base+'/direct-migration/preview',headers=auth(admin),json=body).status_code==404
    assert ha.calls==0


@pytest.mark.parametrize('change',['logout','resource','deleted','binding'])
def test_preview_rechecks_authority_after_real_http(server,ha,change):
    app,client,admin,resource,path,base,body=setup_transfer(server,ha)
    path += '/'+resource['ref']['id']
    def mutate():
        ha.during=None
        if change=='logout':
            r=client.post('/api/v1/auth/logout',headers=auth(admin),json={'refreshToken':admin['refreshToken']})
            assert r.status_code==204
        elif change=='resource':
            assert client.patch(path,headers=auth(admin),json={'expectedRevision':1,'expectedAclRevision':1,'label':'New','order':1}).status_code==200
        elif change=='deleted':
            assert client.delete(path,headers=auth(admin),params={'expectedRevision':1,'expectedAclRevision':1}).status_code==204
        else:
            # Another current explicit import wins while the first GET is pending.
            other={**body,'requestId':'d'*32}
            p=preview(client,admin,base,other)
            assert confirm(client,admin,base,other,p).status_code==201
    ha.during=mutate
    r=client.post(base+'/direct-migration/preview',headers=auth(admin),json=body)
    assert r.status_code=={'logout':401,'resource':409,'deleted':404,'binding':409}[change]
    assert not app.state.core.direct_ha_migration._previews and ha.command_calls==0
    assert len(stored(app)['service_connections'])==(1 if change=='binding' else 0)


@pytest.mark.parametrize('state,expected',[('on','on'),('off','off'),('unknown','unavailable'),('unavailable','unavailable')])
def test_preview_projects_only_closed_states_without_command_grant(server,ha,state,expected):
    _,client,admin,_,_,base,body=setup_transfer(server,ha)
    ha.state=state
    p=preview(client,admin,base,body)
    assert p['projection']=={'kind':'switch','state':expected,'commandAvailable':False}
    assert all(x not in str(p) for x in ('attributes','last_updated','synthetic-ha-only','NEVER-PUBLISH'))


@pytest.mark.parametrize('status',[401,404,500,302])
def test_upstream_failure_does_not_log_out_core_or_write(server,ha,status):
    app,client,admin,_,_,base,body=setup_transfer(server,ha)
    ha.status=status; before=stored(app)
    r=client.post(base+'/direct-migration/preview',headers=auth(admin),json=body)
    assert r.status_code==502 and ha.calls==1 and ha.command_calls==0
    assert client.get('/api/v1/auth/me',headers=auth(admin)).status_code==200
    assert stored(app)==before and not app.state.core.direct_ha_migration._previews


@pytest.mark.parametrize('payload',[b'{}',b'{"entity_id":"switch.other","state":"on"}',
    b'{"entity_id":"switch.synthetic","state":"invalid"}',b'{"entity_id":"switch.synthetic","state":"on","state":"off"}'])
def test_missing_foreign_unknown_projection_cannot_be_confirmed(server,ha,payload):
    app,client,admin,_,_,base,body=setup_transfer(server,ha)
    ha.body=payload
    r=client.post(base+'/direct-migration/preview',headers=auth(admin),json=body)
    assert r.status_code==502 and len(r.content)<200
    assert not app.state.core.direct_ha_migration._previews and not stored(app)['service_connections']


@pytest.mark.parametrize('retirement',['ttl','backwards','restart'])
def test_preview_retirement_never_creates_records(server,ha,retirement):
    app,client,admin,_,_,base,body=setup_transfer(server,ha)
    now=[100.0];app.state.core.home_assistant._clock=lambda:now[0]
    p=preview(client,admin,base,body); before=stored(app); calls=ha.calls
    if retirement=='restart':
        with TestClient(create_app(server[2])) as restarted:
            assert confirm(restarted,admin,base,body,p).status_code==409
            assert restarted.get(base+'/direct-migration/results/'+body['requestId'],headers=auth(admin)).status_code==404
    else:
        now[0]=160.0 if retirement=='ttl' else 99.0
        assert confirm(client,admin,base,body,p).status_code==409
    assert stored(app)==before and ha.calls==calls


@pytest.mark.parametrize('stage',['before','after'])
def test_private_cancellation_has_zero_durable_effect(server,ha,stage):
    app,client,admin,resource,_,base,body=setup_transfer(server,ha)
    core=app.state.core;actor=core.auth.authenticate(admin['accessToken']); cancelled=[stage=='before']
    if stage=='after': ha.during=lambda:cancelled.__setitem__(0,True)
    with pytest.raises(ApiError) as error:
        core.direct_ha_migration.preview(actor,core.context.coreId,core.context.homeId,resource['ref']['id'],
            MigrationInput(**body),cancelled=lambda:cancelled[0])
    assert error.value.status==408
    assert ha.calls==(1 if stage=='after' else 0) and ha.command_calls==0
    assert not stored(app)['service_connections'] and not core.direct_ha_migration._previews


def test_concurrent_same_confirmation_and_restart_are_one_atomic_pair(server,ha):
    app,client,admin,_,_,base,body=setup_transfer(server,ha)
    p=preview(client,admin,base,body); calls=ha.calls
    with ThreadPoolExecutor(max_workers=2) as pool:
        results=list(pool.map(lambda _:confirm(client,admin,base,body,p),range(2)))
    assert [r.status_code for r in results]==[201,201]
    assert results[0].json()==results[1].json()
    assert len(stored(app)['service_connections'])==len(stored(app)['home_assistant_bindings'])==1
    assert ha.calls==calls
    assert confirm(client,admin,base,{**body,'name':'Changed'},p).status_code==409
    assert client.post('/api/v1/auth/logout',headers=auth(admin),json={'refreshToken':admin['refreshToken']}).status_code==204
    assert client.get(base+'/direct-migration/results/'+body['requestId'],headers=auth(admin)).status_code==401
    assert ha.calls==calls


def test_four_preview_quota_cancel_releases_capacity_and_never_holds_secret(server,ha):
    app,client,admin,_,_,base,body=setup_transfer(server,ha)
    values=[preview(client,admin,base,{**body,'requestId':f'{i:032x}'}) for i in range(4)]
    calls=ha.calls
    r=client.post(base+'/direct-migration/preview',headers=auth(admin),json={**body,'requestId':'f'*32})
    assert r.status_code==429 and r.json()['error']['code']=='ha_migration_limit_reached' and ha.calls==calls
    for item in app.state.core.direct_ha_migration._previews.values():
        assert body['token'] not in repr(vars(item))
    assert client.delete(base+'/direct-migration/preview/'+values[0]['id'],headers=auth(admin)).status_code==204
    preview(client,admin,base,{**body,'requestId':'f'*32})


def test_service_capacity_blocks_preview_before_outbound_without_deleting_live_configuration(server,ha):
    app,client,admin,_,_,base,body=setup_transfer(server,ha)
    from larenor_server.services.service import MAX_SERVICES, NEVER
    with app.state.core.db.transaction() as c:
        for i in range(MAX_SERVICES):
            app.state.core.services._save(c,f'{i:032x}',1,{'name':f'Synthetic {i}','kind':'home_assistant',
                'baseUrl':ha.url,'credentials':{'token':'synthetic-ha-only'},'verification':dict(NEVER)})
    before=stored(app)
    r=client.post(base+'/direct-migration/preview',headers=auth(admin),json=body)
    assert r.status_code==409 and r.json()['error']['code']=='service_limit_reached'
    assert stored(app)==before and ha.calls==0


def test_service_identity_collision_after_preview_never_overwrites_existing_record(server,ha,monkeypatch):
    from types import SimpleNamespace
    from uuid import UUID
    app,client,admin,_,_,base,body=setup_transfer(server,ha)
    p=preview(client,admin,base,body)
    monkeypatch.setattr('larenor_server.services.service.uuid',SimpleNamespace(uuid4=lambda:UUID(hex=p['service']['id'])))
    r=client.post('/api/v1/admin/services',headers=auth(admin),json={'name':'Existing','kind':'home_assistant',
        'baseUrl':ha.url,'credentials':{'token':'existing-synthetic-token'}})
    assert r.status_code==201
    before=stored(app);calls=ha.calls
    assert confirm(client,admin,base,body,p).status_code==409
    assert stored(app)==before and ha.calls==calls and ha.command_calls==0


def test_request_id_is_not_a_lookup_capability_for_other_resource_or_actor(server,ha):
    from test_admin import create, activate
    app,client,admin,_,path,base,body=setup_transfer(server,ha)
    p=preview(client,admin,base,body)
    assert confirm(client,admin,base,body,p).status_code==201
    record=client.post(path,headers=auth(admin),json={'kind':'resource','label':'Other','order':1}).json()['record']
    other_base=base.rsplit('/',1)[0]+'/'+record['ref']['id']
    assert client.get(other_base+'/direct-migration/results/'+body['requestId'],headers=auth(admin)).status_code==404
    create(client,admin,name='otheradmin',role='admin');other=activate(client,'otheradmin')
    calls=ha.calls
    assert client.get(base+'/direct-migration/results/'+body['requestId'],headers=auth(other)).status_code==404
    assert confirm(client,other,base,body,p).status_code==404
    assert ha.calls==calls and len(stored(app)['service_connections'])==1


def test_duplicate_request_is_blocked_both_before_and_after_actual_get(server,ha):
    app,client,admin,_,_,base,body=setup_transfer(server,ha)
    nested=[]
    def finish_second_preview():
        ha.during=None
        nested.append(preview(client,admin,base,body))
    ha.during=finish_second_preview
    r=client.post(base+'/direct-migration/preview',headers=auth(admin),json=body)
    assert r.status_code==409 and len(nested)==1 and ha.calls==2
    calls=ha.calls
    assert client.post(base+'/direct-migration/preview',headers=auth(admin),json=body).status_code==409
    assert ha.calls==calls
    assert len(app.state.core.direct_ha_migration._previews)==1 and not stored(app)['service_connections']
    assert client.delete(base+'/direct-migration/preview/'+'0'*32,headers=auth(admin)).status_code==409
