import inspect
import json
import socket
import pytest
from larenor_server.plugins.arr_authenticated_readback import (
    ArrAuthenticatedReadback, ArrAuthenticatedReadbackError,
    ArrAuthenticatedReadbackLimits)
from test_jellyfin_startup import Connection, response

KEY='01234567'*4
VERSIONS={'sonarr':('Sonarr','4.0.19.2979'),'radarr':('Radarr','6.3.0.10514')}

def result(service, value=None, status=200):
    name, version=VERSIONS[service]
    body=json.dumps(value or {'appName':name,'version':version}).encode()
    return response(status, body, content_type=b'application/json')

@pytest.mark.parametrize('service', ['sonarr','radarr'])
def test_reads_exact_pinned_status_with_private_header(service):
    connection=Connection([result(service)])
    value=ArrAuthenticatedReadback().read(connection,service_id=service,api_key=KEY)
    assert value.state=='verified' and value.service_id==service
    request=connection.requests[0]
    assert b'GET /api/v3/system/status HTTP/1.1' in request
    assert b'Host: '+service.encode() in request
    assert b'X-Api-Key: '+KEY.encode() in request
    assert KEY not in repr(value)

@pytest.mark.parametrize('status',[401,403])
def test_auth_failure_is_static_and_not_retried(status):
    connection=Connection([result('sonarr',status=status)])
    with pytest.raises(ArrAuthenticatedReadbackError,match='^arr_authentication_failed$') as raised:
        ArrAuthenticatedReadback().read(connection,service_id='sonarr',api_key=KEY)
    assert len(connection.requests)==1 and KEY not in repr(raised.value)

@pytest.mark.parametrize('value',[{'appName':'Radarr','version':'4.0.19.2979'}, {'appName':'Sonarr','version':'4.0.20.0'}])
def test_cross_service_or_version_drift_is_rejected(value):
    with pytest.raises(ArrAuthenticatedReadbackError,match='^arr_readback_mismatch$'):
        ArrAuthenticatedReadback().read(Connection([result('sonarr',value)]),service_id='sonarr',api_key=KEY)

@pytest.mark.parametrize('body',[b'[]',b'{}',b'{"appName":"Sonarr","appName":"Sonarr","version":"4.0.19.2979"}',b'no'])
def test_malformed_projection_is_protocol_failure(body):
    c=Connection([response(200,body,content_type=b'application/json')])
    with pytest.raises(ArrAuthenticatedReadbackError,match='^arr_readback_protocol$'):
        ArrAuthenticatedReadback().read(c,service_id='sonarr',api_key=KEY)

@pytest.mark.parametrize('service,key',[('other',KEY),('sonarr','short'),('sonarr',True)])
def test_closed_inputs_have_no_target_or_header_surface(service,key):
    c=Connection([])
    with pytest.raises(ArrAuthenticatedReadbackError,match='^invalid_arr_authenticated_readback$'):
        ArrAuthenticatedReadback().read(c,service_id=service,api_key=key)
    assert not {'url','host','resolver','proxy','headers','token'} & set(inspect.signature(ArrAuthenticatedReadback.read).parameters)


def test_timeout_closes_once_without_retry():
    class Stalled(Connection):
        def recv(self,_count): raise socket.timeout()
    c=Stalled([])
    with pytest.raises(ArrAuthenticatedReadbackError,match='^arr_authenticated_readback_timeout$'):
        ArrAuthenticatedReadback().read(c,service_id='sonarr',api_key=KEY,limits=ArrAuthenticatedReadbackLimits(total_seconds=.01))
    assert c.closed and len(c.requests)==1
