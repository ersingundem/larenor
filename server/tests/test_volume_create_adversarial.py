"""Boundary regressions for the private managed-volume CREATE composition."""
from dataclasses import replace
import json
import os
import sys
import threading
import time

import pytest

from larenor_server.plugins.engine_http import EngineHttpError, EngineHttpRequest, VerifiedEngineHttp, EngineHttpLimits
from larenor_server.plugins.resource_journal import ResourceJournalError
from larenor_server.plugins.volume_create_journal import VolumeCreateJournal
from larenor_server.plugins.volume_effects import (
    UnixVolumeCreator, VolumeAbsent, VolumeCreateAcknowledgement, VolumeEffectError,
    VolumeEffectLimits, build_volume_create_body,
)
from larenor_server.plugins.volume_journal import VolumeJournal
from larenor_server.plugins.volume_preparation import JournaledVolumeCreates, VolumePreparationError
from test_engine_http import response
from test_volume_effects import begun, creator, engine_server, labels_digest
from test_volume_journal import inputs
from test_volume_plan import source
from test_volume_preparation import Engine
from test_volume_resources import body


def test_oversize_response_reports_bound_instead_of_generic_unavailable(begun):
    _, _, intent = begun
    reply = b'HTTP/1.1 201 ok\r\nContent-Type: application/json\r\nContent-Length: 65537\r\n\r\n'
    with engine_server(reply) as (endpoint, calls):
        with pytest.raises(VolumeEffectError, match='^volume_response_limit$'):
            creator(endpoint).create(intent, before_dispatch=lambda: True)
    assert len(calls) == 2


def test_a_denied_gate_cannot_be_published_as_observed_by_a_bad_adapter(tmp_path, source):
    data = inputs(source)
    rid = data['plan'].resources[0].resourceId
    calls = 0
    def authorize():
        nonlocal calls
        calls += 1
        return calls == 1
    class IncorrectAdapter(Engine):
        def create(self, intent, *, before_dispatch=None, cancelled=None):
            assert before_dispatch() is False
            # No effect is performed, but a broken trusted adapter reports ACK.
            self.exists = True
            return VolumeCreateAcknowledgement(rid, labels_digest(intent))
    engine = IncorrectAdapter()
    with VolumeCreateJournal(tmp_path / 'create', initialize=True) as j:
        result = JournaledVolumeCreates(j, engine).apply(**data, resource_id=rid, authorize_create=authorize)
    assert result.state == 'uncertain'
    assert engine.calls == ['get']


@pytest.mark.parametrize('field,value', [
    ('total_seconds', True), ('total_seconds', 0), ('total_seconds', 10.1),
    ('total_seconds', float('nan')), ('total_seconds', float('inf')),
    ('idle_seconds', False), ('idle_seconds', 0), ('idle_seconds', 2.1),
    ('max_chunks', True), ('max_chunks', 0), ('max_chunks', 4097), ('max_chunks', 1.0),
])
def test_effect_limits_only_narrow_and_never_coerce(field, value):
    with pytest.raises(VolumeEffectError, match='^invalid_volume_effect_limits$'):
        VolumeEffectLimits(**{field: value})


@pytest.mark.parametrize('mutation', ['extra', 'driver', 'options', 'name', 'label', 'bool_version', 'whitespace'])
def test_wire_shape_rejection_has_no_transport(begun, mutation):
    _, _, intent = begun
    payload = json.loads(build_volume_create_body(intent))
    if mutation == 'extra': payload['Scope'] = 'global'
    elif mutation == 'driver': payload['Driver'] = 'third-party'
    elif mutation == 'options': payload['DriverOpts'] = None
    elif mutation == 'name': payload['Name'] += '/child'
    elif mutation == 'label': payload['Labels']['foreign'] = 'value'
    elif mutation == 'bool_version': payload['Labels']['org.larenor.worker-policy-version'] = True
    raw = json.dumps(payload, sort_keys=True, separators=(',', ':')).encode()
    if mutation == 'whitespace': raw += b' '
    with pytest.raises(EngineHttpError, match='^invalid_engine_request$'):
        EngineHttpRequest('POST', '/v1.47/volumes/create',
            (('Accept', 'application/json'), ('Content-Type', 'application/json')), raw)


@pytest.mark.parametrize('status', [200, 202, 204, 301, 401, 404, 409, 500])
def test_only_201_is_an_ack_and_never_retried(begun, status):
    _, _, intent = begun
    with engine_server(response(body(intent.binding), status=status)) as (endpoint, calls):
        with pytest.raises(VolumeEffectError):
            creator(endpoint).create(intent, before_dispatch=lambda: True)
    assert len(calls) == 2 and sum(line.startswith('POST ') for line, _ in calls) == 1


def test_uncertain_and_old_observation_intents_send_no_http(begun, tmp_path):
    data, j, intent = begun
    rid = intent.binding.resource_id
    j.mark_uncertain(rid, 2)
    uncertain = j.bind(rid, 3, **data)
    with VolumeJournal(tmp_path / 'observe', initialize=True) as old:
        with old.locked():
            old.prepare(**data, resource_id=rid)
            old_intent = old.begin_observation(rid, 1, **data)
            with engine_server(response()) as (endpoint, calls):
                for selected in (uncertain, old_intent):
                    with pytest.raises(VolumeEffectError, match='^invalid_volume_binding$'):
                        creator(endpoint).create(selected, before_dispatch=lambda: True)
            assert calls == []


@pytest.mark.parametrize('change', ['mode', 'replace', 'wrong_peer', 'platform'])
def test_socket_peer_or_platform_change_denies_post(begun, change):
    _, _, intent = begun
    with engine_server(response(body(intent.binding), status=201), platform='arm64' if change == 'platform' else 'amd64') as (endpoint, calls):
        def gate():
            if change == 'mode':
                os.chmod(endpoint.path, 0o666)
            elif change == 'replace':
                os.rename(endpoint.path, endpoint.path + '.old')
                with open(endpoint.path, 'wb'):
                    pass
                os.chmod(endpoint.path, 0o600)
            return True
        engine = UnixVolumeCreator(endpoint, peer_uid=lambda _: os.getuid() + (1 if change == 'wrong_peer' else 0))
        with pytest.raises(VolumeEffectError):
            engine.create(intent, before_dispatch=gate)
    assert all(not line.startswith('POST ') for line, _ in calls)


def test_deadline_can_expire_inside_private_gate_but_never_dispatch_afterward(begun):
    _, _, intent = begun
    with engine_server(response(body(intent.binding), status=201)) as (endpoint, calls):
        engine = creator(endpoint, limits=VolumeEffectLimits(total_seconds=.05, idle_seconds=.04))
        with pytest.raises(VolumeEffectError, match='^volume_timeout$'):
            engine.create(intent, before_dispatch=lambda: time.sleep(.08) or True)
    assert len(calls) == 1


def test_cancel_after_ack_and_final_read_source_change_never_publish_success(tmp_path, source):
    data = inputs(source)
    rid = data['plan'].resources[0].resourceId
    event = threading.Event()
    class LateCancel(Engine):
        def create(self, *args, **kwargs):
            result = super().create(*args, **kwargs)
            event.set()
            return result
    engine = LateCancel()
    with VolumeCreateJournal(tmp_path / 'cancel', initialize=True) as j:
        result = JournaledVolumeCreates(j, engine).apply(**data, resource_id=rid,
            authorize_create=lambda: True, cancelled=event)
        assert result.state == 'uncertain' and engine.calls == ['get', 'post']
    class ChangedSource(Engine):
        def probe(self, intent, **kwargs):
            result = super().probe(intent, **kwargs)
            if self.exists:
                object.__setattr__(data['policy'], 'workerPolicyDigest', 'e' * 64)
            return result
    engine = ChangedSource()
    with VolumeCreateJournal(tmp_path / 'source', initialize=True) as j:
        result = JournaledVolumeCreates(j, engine).apply(**data, resource_id=rid, authorize_create=lambda: True)
        assert result.state == 'uncertain' and engine.calls == ['get', 'post', 'get']


@pytest.mark.parametrize('point', ['before_probe', 'after_post', 'final_probe'])
def test_process_interruption_images_reopen_without_replaying_effect(tmp_path, source, point):
    data = inputs(source)
    rid = data['plan'].resources[0].resourceId
    path = tmp_path / 'create'
    class CrashingEngine(Engine):
        crash = True
        def probe(self, intent, **kwargs):
            if self.crash and (point == 'before_probe' or point == 'final_probe' and self.exists):
                raise SystemExit('synthetic crash')
            return super().probe(intent, **kwargs)
        def create(self, intent, **kwargs):
            ack = super().create(intent, **kwargs)
            if self.crash and point == 'after_post':
                raise SystemExit('synthetic crash')
            return ack
    engine = CrashingEngine()
    with VolumeCreateJournal(path, initialize=True) as j:
        with pytest.raises(SystemExit):
            JournaledVolumeCreates(j, engine).apply(**data, resource_id=rid, authorize_create=lambda: True)
    engine.crash = False
    before = engine.calls.count('post')
    with VolumeCreateJournal(path) as j:
        result = JournaledVolumeCreates(j, engine).apply(**data, resource_id=rid, authorize_create=lambda: True)
    assert engine.calls.count('post') == before
    assert result.state == ('uncertain' if point == 'before_probe' else 'observed_requires_bootstrap')


@pytest.mark.skipif(sys.platform != 'linux', reason='Production SO_PEERCRED needs Linux')
def test_real_linux_peer_for_volume_create_uses_only_synthetic_socket(begun):
    _, _, intent = begun
    with engine_server(response(body(intent.binding), status=201)) as (endpoint, calls):
        ack = UnixVolumeCreator(endpoint).create(intent, before_dispatch=lambda: True)
    assert type(ack) is VolumeCreateAcknowledgement and len(calls) == 2
