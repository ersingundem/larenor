from dataclasses import replace
import copy,json,socket
import pytest
from larenor_server.plugins.arr_endpoint import ArrEndpointError,open_arr_endpoint,prove_arr_endpoint
from larenor_server.plugins.catalog import load_catalog
from larenor_server.plugins.managed_container import JellyfinBindingBuilder,ManagedImageProof,ManagedNetworkProof,ManagedVolumeProof,VerifiedJellyfinResources
from test_managed_container_binding import source,snapshot

def build(service):
    catalog,stack,policy=source()
    def provider(resources,volumes,component):
        image=next(x for x in resources.resources if x.kind=='ensure_image' and x.serviceId==service); network=resources.resources[-1]
        selected=tuple(x for x in volumes.resources if x.serviceId==service or x.kind=='managed_library')
        return VerifiedJellyfinResources(resources.stackPlanHash,resources.planHash,volumes.planHash,resources.workerPolicyDigest,
            ManagedImageProof(image.resourceId,3,image.image.configDigest,json.dumps({'Env':['PATH=/usr/bin'],'Volumes':{'/config':{}}},sort_keys=True,separators=(',',':')).encode()),
            tuple(ManagedVolumeProof(x.resourceId,x.operationId,4,'e'*32,'f'*32,x.name,x.target,True) for x in selected),
            ManagedNetworkProof(network.resourceId,network.operationId,3,'1'*32,'2'*32,network.name,'3'*64))
    binding=JellyfinBindingBuilder(catalog,policy,'4'*32,provider,service_id=service)(stack)
    observed=snapshot(binding); observed['State']={'Status':'running','Running':True,'Paused':False,'Restarting':False,'Dead':False}
    next(iter(observed['NetworkSettings']['Networks'].values())).update(IPAddress='172.28.0.2',IPPrefixLen=16,Gateway='172.28.0.1')
    return stack,binding,observed

@pytest.mark.parametrize('service,port',[('sonarr',8989),('radarr',7878)])
def test_exact_running_container_yields_fixed_private_endpoint(service,port):
    stack,binding,observed=build(service); proof=prove_arr_endpoint(observed,binding,stack,'5'*64,service)
    assert (proof.service_id,proof.port,proof.address)==(service,port,'172.28.0.2') and '172.28' not in repr(proof)

@pytest.mark.parametrize('damage',['id','stopped','public','network','extra','cross_service'])
def test_drift_never_opens_socket(damage,monkeypatch):
    stack,binding,observed=build('sonarr'); service='sonarr'
    if damage=='id': observed['Id']='6'*64
    elif damage=='stopped': observed['State'].update(Status='exited',Running=False)
    elif damage=='public': next(iter(observed['NetworkSettings']['Networks'].values()))['IPAddress']='8.8.8.8'
    elif damage=='network': next(iter(observed['NetworkSettings']['Networks'].values()))['NetworkID']='9'*64
    elif damage=='extra': observed['NetworkSettings']['Networks']['foreign']=copy.deepcopy(next(iter(observed['NetworkSettings']['Networks'].values())))
    else: service='radarr'
    monkeypatch.setattr(socket,'socket',lambda *_: (_ for _ in ()).throw(AssertionError()))
    with pytest.raises(ArrEndpointError,match='^arr_endpoint_untrusted$'): open_arr_endpoint(observed,binding,stack,'5'*64,service)

class Connection:
    def __init__(self,fail=False): self.fail=fail; self.calls=[]; self.closed=False
    def settimeout(self,v): self.calls.append(('timeout',v))
    def connect(self,v): self.calls.append(('connect',v)); (_ for _ in ()).throw(OSError()) if self.fail else None
    def close(self): self.closed=True

def test_opens_one_numeric_target_without_dns_or_retry(monkeypatch):
    stack,binding,observed=build('radarr'); c=Connection(); monkeypatch.setattr(socket,'getaddrinfo',lambda *_: (_ for _ in ()).throw(AssertionError())); monkeypatch.setattr(socket,'socket',lambda *_: c)
    opened=open_arr_endpoint(observed,binding,stack,'5'*64,'radarr'); assert opened.connection is c and c.calls[-1]==('connect',('172.28.0.2',7878))

def test_failure_closes_once(monkeypatch):
    stack,binding,observed=build('sonarr'); c=Connection(True); monkeypatch.setattr(socket,'socket',lambda *_: c)
    with pytest.raises(ArrEndpointError,match='^arr_endpoint_unavailable$'): open_arr_endpoint(observed,binding,stack,'5'*64,'sonarr')
    assert c.closed and len([x for x in c.calls if x[0]=='connect'])==1
