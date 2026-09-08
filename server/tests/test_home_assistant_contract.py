"""Exported actual FastAPI/auth/SQLite + real loopback state-GET responses."""
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
from larenor_server.app import create_app
from larenor_server.config import Settings
from larenor_server.files import private_create

FIXTURE = Path(__file__).resolve().parents[2] / 'contracts/home-assistant.v1.json'


def actual_contract(root):
    upstream = ha.__wrapped__(); fixture = next(upstream)
    try:
        clock = Clock(); settings = Settings(root / 'data', root / 'secrets/key', clock=clock)
        private_create(settings.key_file, bytes(range(32)))
        context_ids = iter(('a' * 32, 'b' * 32)); core_ids = iter(('0' * 32, 'f' * 32))
        with patch('larenor_server.context.secrets', SimpleNamespace(token_hex=lambda _: next(context_ids))), \
             patch('larenor_server.core.uuid', SimpleNamespace(uuid4=lambda: UUID(hex=next(core_ids)))):
            app = create_app(settings)
        app.state.core.home_assistant._clock = lambda: 100.0
        with TestClient(app) as client:
            admin = ready((app, client, settings, clock))
            with patch('larenor_server.admin.service.uuid', SimpleNamespace(uuid4=lambda: UUID(hex='e' * 32))):
                create_user(client, admin)
            member = activate(client, 'member')
            ref_base = '/api/v1/admin/home-resources/' + 'a' * 32 + '/' + 'b' * 32
            with patch('larenor_server.home_resources.service.uuid', SimpleNamespace(uuid4=lambda: UUID(hex='1' * 32))):
                resource = client.post(ref_base, headers=auth(admin), json={'kind':'resource','label':'Salon anahtarı','order':0}).json()['record']
            with patch('larenor_server.services.service.uuid', SimpleNamespace(uuid4=lambda: UUID(hex='2' * 32))):
                response = client.post('/api/v1/admin/services', headers=auth(admin), json={
                    'kind':'home_assistant','name':'Synthetic','baseUrl':fixture.url,'credentials':{'token':'synthetic-ha-only'}})
                assert response.status_code == 201
            suffix = '/home-assistant/' + 'a'*32 + '/' + 'b'*32 + '/resources/' + '1'*32
            base, public = '/api/v1/admin'+suffix, '/api/v1'+suffix
            result = {'schemaVersion':1, 'context':app.state.core.context.model_dump(), 'resource':resource,
                'limits': {'snapshotTtlMs':5000,'previewTtlMs':60000,'cacheEntries':256,'cacheEntriesPerUser':32,
                    'cacheEntryBytes':2048,'previews':32,'previewsPerActor':4,'bindings':256,
                    'commands':1024,'upstreamBodyBytes':65536,'upstreamTimeoutMs':3000}, 'memberId':'e'*32}
            def capture(name, method, path, body=None, actor=admin, status=200):
                r=client.request(method,path,headers=auth(actor),json=body)
                assert r.status_code == status, (name,r.status_code,r.text)
                data=None if status==204 else r.json()
                result[name]={'method':method,'path':path.removeprefix('/api/v1'),'body':body,'status':status,'response':data}
                return data
            capture('unbound','GET',base+'/binding',status=404)
            body={'serviceId':'2'*32,'expectedServiceRevision':1,'expectedRevision':1,'expectedAclRevision':1,
                  'entityId':'switch.synthetic','expectedBindingId':None}
            ids=iter(('3'*32,'4'*32,'5'*32,'6'*32))
            with patch('larenor_server.home_assistant.service.uuid',SimpleNamespace(uuid4=lambda:UUID(hex=next(ids)))):
                preview=capture('preview','POST',base+'/binding-preview',body,status=201)['preview']
                capture('cancel','DELETE',base+'/binding-preview/'+preview['id'],status=204)
                capture('cancelledConfirmation','POST',base+'/binding-confirm',{'previewId':preview['id']},status=409)
                preview=capture('secondPreview','POST',base+'/binding-preview',body,status=201)['preview']
            capture('confirm','POST',base+'/binding-confirm',{'previewId':preview['id']},status=201)
            capture('binding','GET',base+'/binding')
            capture('oneUse','POST',base+'/binding-confirm',{'previewId':preview['id']},status=409)
            capture('snapshotOff','GET',public+'/snapshot')
            before=fixture.calls;capture('cachedOff','GET',public+'/snapshot');assert fixture.calls==before
            capture('hidden','GET',public+'/snapshot',actor=member,status=404)
            capture('memberAdminDenied','GET',base+'/binding',actor=member,status=403)
            grant=ref_base+'/'+'1'*32+'/grants/'+'e'*32
            assert client.put(grant,headers=auth(admin),json={'expectedAclRevision':1,'permissions':{'read':True,'write':False}}).status_code==200
            fixture.state='on';capture('memberOn','GET',public+'/snapshot',actor=member)
            command={'schemaVersion':1,'requestId':'7'*32,'action':'turn_off','expectedBindingRevision':1,
                     'expectedResourceRevision':1,'expectedAclRevision':2}
            capture('commandWriteDenied','POST',public+'/commands',{**command},actor=member,status=403)
            assert client.put(grant,headers=auth(admin),json={'expectedAclRevision':2,'permissions':{'read':True,'write':True}}).status_code==200
            command['expectedAclRevision']=3
            accepted=capture('commandAccepted','POST',public+'/commands',command,actor=member,status=202)
            capture('commandDuplicate','POST',public+'/commands',command,actor=member,status=202)
            capture('commandResult','GET',public+'/commands/'+'7'*32,actor=member)
            capture('commandConflict','POST',public+'/commands',{**command,'action':'turn_on'},actor=member,status=409)
            assert accepted['receipt']['dispatchState']=='accepted' and fixture.command_calls==1
            app.state.core.home_assistant._clock=lambda:106.0
            fixture.state='unknown';capture('unknownUnavailable','GET',public+'/snapshot',actor=member)
            app.state.core.home_assistant._clock=lambda:112.0
            fixture.status=401;capture('upstreamUnauthorized','GET',public+'/snapshot',actor=member,status=502)
            assert client.get('/api/v1/auth/me',headers=auth(member)).status_code==200
            fixture.status=200;fixture.state='not-a-switch-state'
            capture('unsupported','GET',public+'/snapshot',actor=member,status=502)
            fixture.state='off'
            assert client.put(grant,headers=auth(admin),json={'expectedAclRevision':3,'permissions':{'read':False,'write':False}}).status_code==200
            capture('revoked','GET',public+'/snapshot',actor=member,status=404)
            assert client.post('/api/v1/auth/logout',headers=auth(member),json={'refreshToken':member['refreshToken']}).status_code==204
            capture('coreUnauthorized','GET',public+'/snapshot',actor=member,status=401)
            result['upstreamRequests']=fixture.calls
            result['upstreamCommandRequests']=fixture.command_calls
            raw=json.dumps(result)
            assert all(v not in raw for v in ('synthetic-ha-only','NEVER-PUBLISH','accessToken','refreshToken',fixture.url))
            return result
    finally:
        upstream.close()


def test_actual_http_contract_matches_committed_fixture(tmp_path):
    assert actual_contract(tmp_path.resolve()) == json.loads(FIXTURE.read_text())


if __name__ == '__main__':
    with TemporaryDirectory(prefix='larenor-ha-contract-') as path:
        FIXTURE.write_text(json.dumps(actual_contract(Path(path).resolve()),ensure_ascii=False,indent=2)+'\n')
