"""Actual FastAPI/SQLite and real HTTP bytes to an owned HA loopback server.

Only the test connector maps fixture.invalid:8123 to its ephemeral loopback
listener. Production request framing/parsing and all resource operations run.
Raw credentials are deliberately omitted from captured request metadata.
"""
import json
from pathlib import Path
import socket
from tempfile import TemporaryDirectory
from types import SimpleNamespace
from unittest.mock import patch
from uuid import UUID
from urllib.parse import urlsplit
from fastapi.testclient import TestClient
from conftest import Clock, auth, ready
from test_admin import activate, create as create_user
from test_home_assistant_adapter import ha
from larenor_server.app import create_app
from larenor_server.config import Settings
from larenor_server.files import private_create
from larenor_server.services.transport import ServiceTransport

FIXTURE=Path(__file__).resolve().parents[2]/'contracts/home-assistant-direct-migration.v1.json'


def actual_contract(root):
    upstream=ha.__wrapped__();fixture=next(upstream)
    try:
        def transport(base_url, **kwargs):
            assert base_url=='http://fixture.invalid:8123'
            def resolver(host,port):
                assert (host,port)==('fixture.invalid',8123)
                return [(socket.AF_INET,socket.SOCK_STREAM,0,'',('127.0.0.1',8123))]
            def connector(family,address,timeout):
                assert family==socket.AF_INET and address==('127.0.0.1',8123)
                return socket.create_connection(('127.0.0.1',urlsplit(fixture.url).port),timeout)
            return ServiceTransport(base_url,resolver=resolver,connector=connector,**kwargs)
        clock=Clock();settings=Settings(root/'data',root/'secrets/key',clock=clock)
        private_create(settings.key_file,bytes(range(32)))
        context_ids=iter(('a'*32,'b'*32));core_ids=iter(('0'*32,'f'*32))
        with patch('larenor_server.context.secrets',SimpleNamespace(token_hex=lambda _:next(context_ids))), \
             patch('larenor_server.core.uuid',SimpleNamespace(uuid4=lambda:UUID(hex=next(core_ids)))):
            app=create_app(settings)
        app.state.core.home_assistant._clock=lambda:100.0
        with TestClient(app) as client, patch('larenor_server.home_assistant.transport.ServiceTransport',transport):
            admin=ready((app,client,settings,clock))
            with patch('larenor_server.admin.service.uuid',SimpleNamespace(uuid4=lambda:UUID(hex='e'*32))):
                create_user(client,admin)
            member=activate(client,'member')
            ref_base='/api/v1/admin/home-resources/'+'a'*32+'/'+'b'*32
            with patch('larenor_server.home_resources.service.uuid',SimpleNamespace(uuid4=lambda:UUID(hex='1'*32))):
                resource=client.post(ref_base,headers=auth(admin),json={'kind':'resource','label':'Salon anahtarı','order':0}).json()['record']
            suffix='/home-assistant/'+'a'*32+'/'+'b'*32+'/resources/'+'1'*32
            base='/api/v1/admin'+suffix+'/direct-migration'
            result={'schemaVersion':1,'context':app.state.core.context.model_dump(),'resource':resource,
                'limits':{'previewTtlMs':60000,'previews':32,'previewsPerActor':4,'receipts':256,
                          'receiptCiphertextBytes':8192,'services':128,'bindings':256},
                'requestCapture':{'omittedPrivateFields':['token'],'upstreamRouting':'test-only-loopback-connector'}}
            def capture(name,method,path,body=None,actor=admin,status=200):
                r=client.request(method,path,headers=auth(actor),json=body)
                assert r.status_code==status,(name,r.status_code,r.text)
                data=None if status==204 else r.json()
                captured=None if body is None else {k:v for k,v in body.items() if k!='token'}
                result[name]={'method':method,'path':path.removeprefix('/api/v1'),'body':captured,'status':status,'response':data}
                return data
            body={'requestId':'c'*32,'name':'Transferred HA','baseUrl':'http://fixture.invalid:8123',
                  'token':'synthetic-ha-only','entityId':'switch.synthetic','expectedRevision':1,'expectedAclRevision':1}
            capture('notCommitted','GET',base+'/results/'+body['requestId'],status=404)
            capture('memberDenied','POST',base+'/preview',body,actor=member,status=403)
            ids=iter(('2'*32,'3'*32,'4'*32,'5'*32,'6'*32,'7'*32))
            with patch('larenor_server.home_assistant.migration.uuid',SimpleNamespace(uuid4=lambda:UUID(hex=next(ids)))):
                p=capture('preview','POST',base+'/preview',body,status=201)['preview']
                capture('cancel','DELETE',base+'/preview/'+p['id'],status=204)
                capture('cancelledConfirm','POST',base+'/confirm',{**body,'previewId':p['id']},status=409)
                p=capture('secondPreview','POST',base+'/preview',body,status=201)['preview']
            confirmed={**body,'previewId':p['id']}
            receipt=capture('confirm','POST',base+'/confirm',confirmed,status=201)['receipt']
            capture('result','GET',base+'/results/'+body['requestId'])
            capture('duplicateConfirm','POST',base+'/confirm',confirmed,status=201)
            capture('differentConfirm','POST',base+'/confirm',{**confirmed,'name':'Changed'},status=409)
            capture('alreadyBound','POST',base+'/preview',{**body,'requestId':'d'*32},status=409)
            capture('snapshot','GET','/api/v1'+suffix+'/snapshot')
            capture('memberResultDenied','GET',base+'/results/'+body['requestId'],actor=member,status=403)
            calls=fixture.calls
            with TestClient(create_app(settings)) as restarted:
                r=restarted.get(base+'/results/'+body['requestId'],headers=auth(admin))
                assert r.status_code==200 and r.json()['receipt']==receipt and fixture.calls==calls
                result['restartResult']={'method':'GET','path':(base+'/results/'+body['requestId']).removeprefix('/api/v1'),
                    'body':None,'status':200,'response':r.json()}
            assert client.post('/api/v1/auth/logout',headers=auth(admin),json={'refreshToken':admin['refreshToken']}).status_code==204
            capture('coreUnauthorized','GET',base+'/results/'+body['requestId'],status=401)
            result['upstreamRequests']=fixture.calls;result['upstreamCommandRequests']=fixture.command_calls
            raw=json.dumps(result)
            assert all(v not in raw for v in ('synthetic-ha-only','NEVER-PUBLISH','accessToken','refreshToken',fixture.url))
            assert fixture.calls==3 and fixture.command_calls==0
            return result
    finally:
        upstream.close()


def test_actual_http_contract_matches_committed_fixture(tmp_path):
    assert actual_contract(tmp_path.resolve())==json.loads(FIXTURE.read_text())


if __name__=='__main__':
    with TemporaryDirectory(prefix='larenor-direct-ha-contract-') as path:
        FIXTURE.write_text(json.dumps(actual_contract(Path(path).resolve()),ensure_ascii=False,indent=2)+'\n')
