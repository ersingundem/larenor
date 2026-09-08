"""Binding quota follows live Core metadata, never upstream deletion or cleanup."""
from fastapi.testclient import TestClient

from conftest import auth
from test_home_assistant_adapter import ha, setup, bind
from larenor_server.app import create_app
from larenor_server.home_assistant import schema


def record_path(record):
    ref=record['ref']
    return f'/api/v1/admin/home-resources/{ref["coreId"]}/{ref["homeId"]}/{ref["id"]}'


def new_resource(client,admin,first):
    r=client.post(record_path(first).rsplit('/',1)[0],headers=auth(admin),
        json={'kind':'resource','label':'Next synthetic switch','order':0})
    assert r.status_code==201,r.text
    return r.json()['record']


def remove_resource(client,admin,record):
    r=client.delete(record_path(record),headers=auth(admin),params={'expectedRevision':1,'expectedAclRevision':1})
    assert r.status_code==204,r.text


def preview(client,admin,base,body):
    r=client.post(base+'/binding-preview',headers=auth(admin),json=body)
    assert r.status_code==201,r.text
    return r.json()['preview']['id']


def saved(app):
    with app.state.core.db.connection() as c:
        return ([tuple(r) for r in c.execute('SELECT * FROM home_assistant_bindings ORDER BY resource_id')],
                [tuple(r) for r in c.execute('SELECT * FROM home_assistant_state')])


def test_all_256_live_bindings_reject_then_admin_delete_releases_capacity_after_restart(server,ha,monkeypatch):
    app,client,admin,first,_,base,_,body=setup(server,ha)
    # Isolate inventory capacity from the separate account request-rate limit.
    monkeypatch.setattr(app.state.core.auth,'rate_limit',lambda *args,**kwargs:None)
    resources=[first]
    for index in range(256):
        if index:resources.append(new_resource(client,admin,first))
        bind(client,admin,base.replace(first['ref']['id'],resources[-1]['ref']['id']),body)
    assert len(saved(app)[0])==256
    extra=new_resource(client,admin,first);target=base.replace(first['ref']['id'],extra['ref']['id'])
    p=preview(client,admin,target,body);before=saved(app);calls=ha.calls
    response=client.post(target+'/binding-confirm',headers=auth(admin),json={'previewId':p})
    assert response.status_code==429 and response.json()['error']['code']=='ha_limit_reached'
    assert saved(app)==before and ha.calls==calls
    remove_resource(client,admin,first)
    p=preview(client,admin,target,body);calls=ha.calls
    response=client.post(target+'/binding-confirm',headers=auth(admin),json={'previewId':p})
    assert response.status_code==201,response.text
    binding=response.json()['binding'];rows=saved(app)[0]
    assert len(rows)==256 and all(r[0]!=first['ref']['id'] for r in rows)
    assert ha.calls==calls  # Confirmation/cleanup dispatches no upstream request.
    with TestClient(create_app(server[2])) as restarted:
        assert restarted.get(target+'/binding',headers=auth(admin)).json()['binding']==binding
        live=base.replace(first['ref']['id'],resources[-1]['ref']['id'])
        assert restarted.get(live+'/binding',headers=auth(admin)).status_code==200


def test_orphan_cleanup_and_hmac_roll_back_when_real_insert_aborts(server,ha,monkeypatch):
    # The same capacity branch with one slot isolates the real SQLite fault.
    monkeypatch.setattr(schema,'MAX_BINDINGS',1)
    app,client,admin,first,_,base,_,body=setup(server,ha);bind(client,admin,base,body)
    remove_resource(client,admin,first);second=new_resource(client,admin,first)
    target=base.replace(first['ref']['id'],second['ref']['id']);p=preview(client,admin,target,body)
    with app.state.core.db.transaction() as c:
        c.execute("CREATE TRIGGER synthetic_insert_failure BEFORE INSERT ON home_assistant_bindings BEGIN SELECT RAISE(ABORT,'synthetic_failure'); END")
    before=saved(app);calls=ha.calls
    response=client.post(target+'/binding-confirm',headers=auth(admin),json={'previewId':p})
    assert response.status_code==503,response.text
    assert saved(app)==before and ha.calls==calls
    with app.state.core.db.transaction() as c:c.execute('DROP TRIGGER synthetic_insert_failure')
    # No retry of consumed intent; an explicit fresh preview can now succeed.
    assert client.post(target+'/binding-confirm',headers=auth(admin),json={'previewId':p}).status_code==409
    p=preview(client,admin,target,body)
    assert client.post(target+'/binding-confirm',headers=auth(admin),json={'previewId':p}).status_code==201
    assert saved(app)[0][0][0]==second['ref']['id']


def test_corrupt_registry_or_foreign_scope_never_authorizes_orphan_cleanup(server,ha,monkeypatch):
    monkeypatch.setattr(schema,'MAX_BINDINGS',1)
    app,client,admin,first,_,base,_,body=setup(server,ha);bind(client,admin,base,body)
    remove_resource(client,admin,first);second=new_resource(client,admin,first);other=new_resource(client,admin,first)
    target=base.replace(first['ref']['id'],second['ref']['id']);p=preview(client,admin,target,body)
    before=saved(app)
    foreign=target.replace(first['ref']['homeId'],'f'*32)
    assert client.post(foreign+'/binding-confirm',headers=auth(admin),json={'previewId':p}).status_code==404
    assert saved(app)==before
    with app.state.core.db.transaction() as c:
        old=c.execute('SELECT ciphertext FROM home_resource_records WHERE id=?',(other['ref']['id'],)).fetchone()[0]
        c.execute('UPDATE home_resource_records SET ciphertext=randomblob(length(ciphertext)) WHERE id=?',(other['ref']['id'],))
    calls=ha.calls
    response=client.post(target+'/binding-confirm',headers=auth(admin),json={'previewId':p})
    assert response.status_code==503,response.text
    assert saved(app)==before and ha.calls==calls
    with app.state.core.db.transaction() as c:c.execute('UPDATE home_resource_records SET ciphertext=? WHERE id=?',(old,other['ref']['id']))
    p=preview(client,admin,target,body)
    assert client.post(target+'/binding-confirm',headers=auth(admin),json={'previewId':p}).status_code==201
