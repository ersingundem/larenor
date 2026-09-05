"""HTTP -> durable DB -> private Unix worker; synthetic admin and local folders."""
from dataclasses import replace
import os
from pathlib import Path
import socket
import time

from fastapi.testclient import TestClient
import pytest

from conftest import auth, ready
from test_plugin_api import preview
from test_plugin_preflight_ipc import running
from larenor_server.app import create_app
from larenor_server.config import Settings
from larenor_server.errors import StartupError

BASE='/api/v1/admin/plugins/jobs'


def test_default_runtime_exposes_history_without_claiming_worker_availability(server):
    app, client, settings, _ = server
    pair=ready(server)
    response=client.get(BASE+'/capabilities',headers=auth(pair))
    assert response.status_code==200
    assert response.json()=={'preflightConfigured':False,'installAvailable':False}
    assert client.get(BASE,headers=auth(pair)).json()=={'jobs':[],'nextBefore':None}
    record=preview(client,pair)
    body=dict(operation='preflight',previewId=record['id'],expectedRevision=1,
              planHash=record['plan']['planHash'],requestId='a'*32)
    denied=client.post(BASE,headers=auth(pair),json=body)
    assert denied.status_code==503
    assert denied.json()['error']['code']=='plugin_worker_unavailable'
    assert app.state.plugin_job_dispatcher is None
    with TestClient(create_app(settings)) as restarted:
        assert restarted.get(BASE,headers=auth(pair)).json()=={'jobs':[],'nextBefore':None}


def test_real_http_job_survives_restart_and_completes_through_unix_worker(server,monkeypatch):
    _app, _client, settings, clock=server
    pair=ready(server)
    if not hasattr(socket,'SO_PEERCRED'):
        monkeypatch.setattr('larenor_server.plugins.preflight_ipc._peer_uid',lambda _:os.getuid())
    with running() as (worker,_):
        configured=replace(settings,plugin_worker_socket=worker.path,plugin_worker_uid=os.getuid())
        app=create_app(configured)
        # Queue before lifespan starts, modelling restart before dispatch.
        temporary=TestClient(app)
        record=preview(temporary,pair)
        body=dict(operation='preflight',previewId=record['id'],expectedRevision=1,
                  planHash=record['plan']['planHash'],requestId='b'*32)
        submitted=temporary.post(BASE,headers=auth(pair),json=body)
        assert submitted.status_code==202,submitted.text
        identifier=submitted.json()['job']['id'];temporary.close()
        with TestClient(create_app(configured)) as client:
            end=time.monotonic()+3
            while True:
                job=client.get(BASE+'/'+identifier,headers=auth(pair)).json()['job']
                if job['state'] not in ('queued','running'):break
                assert time.monotonic()<end
                time.sleep(.025)
            assert job['state']=='succeeded'
            assert job['result']['checks'][0]['status']=='unknown'
            assert job['operation']=='preflight'
            replay=client.post(BASE,headers=auth(pair),json=body)
            assert replay.json()['job']['id']==identifier
            events=client.get(BASE+'/'+identifier+'/events',headers=auth(pair)).json()['events']
            assert [e['code'] for e in events]==['job_queued','job_started','job_completed']
        with TestClient(create_app(settings)) as restarted:
            assert restarted.get(BASE+'/'+identifier,headers=auth(pair)).json()['job']==job
            assert restarted.get(BASE+'/capabilities',headers=auth(pair)).json()['preflightConfigured'] is False


def test_partial_job_schema_fails_startup_without_resetting_database(server):
    _app, _, settings,_=server
    with _app.state.core.db.transaction() as connection:
        connection.execute('DROP TABLE plugin_job_events')
    with pytest.raises(StartupError):create_app(settings)


@pytest.mark.parametrize('value',[-1,True,2**32,'root'])
def test_worker_identity_configuration_is_strict(server,value):
    with pytest.raises(ValueError):replace(server[2],plugin_worker_uid=value)


def test_worker_socket_environment_is_explicit_and_absolute(monkeypatch,tmp_path):
    monkeypatch.setenv('LARENOR_PLUGIN_WORKER_SOCKET','relative.sock')
    with pytest.raises(ValueError):Settings.from_environment()
    monkeypatch.setenv('LARENOR_PLUGIN_WORKER_SOCKET',str(tmp_path/'preflight.sock'))
    monkeypatch.setenv('LARENOR_PLUGIN_WORKER_UID','1234')
    settings=Settings.from_environment()
    assert settings.plugin_worker_socket==tmp_path/'preflight.sock'
    assert settings.plugin_worker_uid==1234
