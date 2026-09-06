"""Locked SQLite + synthetic Engine composition, no live install permission."""
from contextlib import contextmanager
from dataclasses import replace
import importlib
import importlib.util
import json
import os
import sqlite3
import threading

import pytest

from larenor_server.context import ContextResponse
from larenor_server.plugins.resource_journal import ResourceJournalError
from larenor_server.plugins.stack_plan import build_media_stack_plan
from larenor_server.plugins.volume_create_journal import VolumeCreateJournal
from larenor_server.plugins.volume_effects import (
    UnixVolumeCreator, VolumeAbsent, VolumeCreateAcknowledgement, VolumeEffectError,
)
from larenor_server.plugins.volume_journal import VolumeJournal
from larenor_server.plugins.volume_resources import VolumeResourceError
from test_engine_http import response
from test_volume_effects import engine_server, labels_digest
from test_volume_journal import inputs, observe
from test_volume_plan import source


def api():
    name = 'larenor_server.plugins.volume_preparation'
    assert importlib.util.find_spec(name) is not None, 'locked volume CREATE composition is absent'
    return importlib.import_module(name)


class Engine:
    def __init__(self, *, exists=False, lost_ack=False):
        self.calls = []
        self.exists, self.lost_ack = exists, lost_ack
        self.on_probe = None
        self.before_gate = None
    def probe(self, intent, *, cancelled=None):
        self.calls.append('get')
        if self.on_probe is not None:
            self.on_probe(intent)
        return observe(intent) if self.exists else VolumeAbsent(intent.binding.resource_id, labels_digest(intent))
    def create(self, intent, *, before_dispatch=None, cancelled=None):
        if self.before_gate is not None:
            self.before_gate(intent)
        if before_dispatch() is not True:
            raise VolumeEffectError('volume_create_not_authorized')
        self.calls.append('post')
        self.exists = True
        if self.lost_ack:
            raise VolumeEffectError('volume_engine_unavailable')
        return VolumeCreateAcknowledgement(intent.binding.resource_id, labels_digest(intent))


def test_real_journal_begin_precedes_one_effect_and_fresh_get(tmp_path, source):
    module = api()
    data = inputs(source)
    rid = data['plan'].resources[0].resourceId
    engine = Engine()
    with VolumeCreateJournal(tmp_path / 'create', initialize=True) as j:
        def locked(intent):
            assert j.get(rid).state == 'mutating'
            with pytest.raises(ResourceJournalError, match='worker_busy'):
                with j.locked():
                    pass
        engine.on_probe = locked
        result = module.JournaledVolumeCreates(j, engine).apply(**data, resource_id=rid, authorize_create=lambda: True)
        assert (result.state, result.revision) == ('observed_requires_bootstrap', 3)
        assert engine.calls == ['get', 'post', 'get']
        same = module.JournaledVolumeCreates(j, engine).apply(**data, resource_id=rid)
        assert same == result and engine.calls == ['get', 'post', 'get']


@pytest.mark.parametrize('permission', [None, False, 1, 'true', 'error'])
def test_private_authorizer_must_explicitly_allow_before_begin(tmp_path, source, permission):
    module = api()
    data = inputs(source)
    engine = Engine()
    def callback():
        if permission == 'error':
            raise RuntimeError('synthetic-private')
        return permission
    with VolumeCreateJournal(tmp_path / 'create', initialize=True) as j:
        with pytest.raises(module.VolumePreparationError, match='volume_create_not_authorized'):
            module.JournaledVolumeCreates(j, engine).apply(**data,
                resource_id=data['plan'].resources[0].resourceId,
                authorize_create=None if permission is None else callback)
        assert engine.calls == []


def test_lost_post_reply_restart_reconciles_without_replay(tmp_path, source):
    module = api()
    data = inputs(source)
    rid = data['plan'].resources[0].resourceId
    path = tmp_path / 'create'
    engine = Engine(lost_ack=True)
    with VolumeCreateJournal(path, initialize=True) as j:
        result = module.JournaledVolumeCreates(j, engine).apply(**data, resource_id=rid, authorize_create=lambda: True)
        assert result.state == 'uncertain' and engine.calls == ['get', 'post']
    with VolumeCreateJournal(path) as j:
        result = module.JournaledVolumeCreates(j, engine).apply(**data, resource_id=rid)
        assert result.state == 'observed_requires_bootstrap' and engine.calls == ['get', 'post', 'get']


def test_begin_without_dispatch_restart_missing_stays_uncertain(tmp_path, source):
    module = api()
    data = inputs(source)
    rid = data['plan'].resources[0].resourceId
    path = tmp_path / 'create'
    with VolumeCreateJournal(path, initialize=True) as j:
        with j.locked():
            j.prepare(**data, resource_id=rid)
            j.begin_create(rid, 1, **data)
    engine = Engine()
    with VolumeCreateJournal(path) as j:
        result = module.JournaledVolumeCreates(j, engine).apply(**data, resource_id=rid, authorize_create=lambda: True)
        assert result.state == 'uncertain' and engine.calls == ['get']


def test_journal_commit_failure_prevents_any_engine_effect(tmp_path, source, monkeypatch):
    module = api()
    data = inputs(source)
    rid = data['plan'].resources[0].resourceId
    engine = Engine()
    with VolumeCreateJournal(tmp_path / 'create', initialize=True) as j:
        with j.locked():
            j.prepare(**data, resource_id=rid)
        @contextmanager
        def fail():
            raise OSError('synthetic private disk failure')
            yield
        monkeypatch.setattr(j, '_transaction', fail)
        with pytest.raises(ResourceJournalError, match='journal_unavailable'):
            module.JournaledVolumeCreates(j, engine).apply(**data, resource_id=rid, authorize_create=lambda: True)
        assert engine.calls == []


@pytest.mark.parametrize('change', ['cancel', 'revision', 'source', 'intent'])
def test_last_gate_retirement_prevents_post_without_overwriting_new_state(tmp_path, source, change):
    module = api()
    data = inputs(source)
    rid = data['plan'].resources[0].resourceId
    engine = Engine()
    cancelled = threading.Event()
    with VolumeCreateJournal(tmp_path / 'create', initialize=True) as j:
        def retire(intent):
            if change == 'cancel':
                cancelled.set()
            elif change == 'revision':
                j.mark_uncertain(rid, 2)
            elif change == 'source':
                object.__setattr__(data['policy'], 'workerPolicyDigest', 'e' * 64)
            else:
                object.__setattr__(intent.receipt, 'revision', 99)
        engine.before_gate = retire
        result = module.JournaledVolumeCreates(j, engine).apply(**data, resource_id=rid,
            authorize_create=lambda: True, cancelled=cancelled)
        assert result.state == 'uncertain' and result.revision == 3
        assert engine.calls == ['get']


def test_foreign_existing_volume_blocks_create_and_no_ack_can_supply_observation(tmp_path, source):
    module = api()
    data = inputs(source)
    rid = data['plan'].resources[0].resourceId
    engine = Engine()
    def foreign(_):
        raise VolumeResourceError('volume_conflict')
    engine.on_probe = foreign
    with VolumeCreateJournal(tmp_path / 'create', initialize=True) as j:
        result = module.JournaledVolumeCreates(j, engine).apply(**data, resource_id=rid, authorize_create=lambda: True)
        assert result.state == 'needs_attention' and engine.calls == ['get']


def test_observation_journal_is_not_a_creation_journal(tmp_path):
    module = api()
    with VolumeJournal(tmp_path / 'old', initialize=True) as j:
        with pytest.raises(module.VolumePreparationError):
            module.JournaledVolumeCreates(j, Engine())


@pytest.mark.parametrize('platform', ['amd64', 'arm64'])
@pytest.mark.parametrize('chunked', [False, True])
def test_actual_sqlite_and_unix_roundtrip_sends_six_fixed_requests(tmp_path, source, platform, chunked):
    module = api()
    original, catalog, policy = source
    stack = build_media_stack_plan(catalog, {}, 'linux/' + platform,
        ContextResponse(schemaVersion=1, coreId=original.coreId, homeId=original.homeId), original.preparationId)
    data = inputs((stack, catalog, policy))
    rid = data['plan'].resources[0].resourceId
    path = tmp_path / 'create'
    stored = None
    durable_states = []
    def reply(request, _calls):
        nonlocal stored
        line, raw = request
        if line.startswith('POST '):
            with sqlite3.connect(path / 'journal.sqlite') as db:
                durable_states.append(db.execute('SELECT state FROM resources').fetchone()[0])
            value = json.loads(raw)
            stored = {'Name': value['Name'], 'Driver': value['Driver'], 'Scope': 'local',
                'Options': {}, 'Labels': value['Labels'], 'Mountpoint': '/synthetic/DO-NOT-EXPOSE'}
            return response(stored, status=201)
        if stored is None:
            return response({'message': 'synthetic no such volume'}, status=404)
        if chunked:
            body = json.dumps(stored).encode()
            return (b'HTTP/1.1 200 ok\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n'
                + f'{len(body):x}\r\n'.encode() + body + b'\r\n0\r\n\r\n')
        return response(stored)
    with VolumeCreateJournal(path, initialize=True) as j:
        with engine_server(reply, platform=platform) as (endpoint, calls):
            engine = UnixVolumeCreator(endpoint, peer_uid=lambda _: os.getuid())
            result = module.JournaledVolumeCreates(j, engine).apply(**data, resource_id=rid, authorize_create=lambda: True)
    assert result.state == 'observed_requires_bootstrap'
    assert durable_states == ['mutating']
    assert [line.split(' ', 1)[0] for line, _ in calls] == ['GET', 'GET', 'GET', 'POST', 'GET', 'GET']
    assert b'DO-NOT-EXPOSE' not in (path / 'journal.sqlite').read_bytes()
