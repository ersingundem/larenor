"""Real SQLite + temporary AF_UNIX composition; no Docker/storage effects."""
from dataclasses import asdict
import json
import os
import sqlite3
import threading

import pytest

from larenor_server.plugins.resource_journal import ResourceJournal, ResourceJournalError
from larenor_server.plugins.volume_journal import VolumeJournal
from larenor_server.plugins.volume_observation import JournaledVolumeObservations, VolumeObservationError
from larenor_server.plugins.volume_resources import volume_binding
from larenor_server.plugins.volume_transport import UnixVolumeReader
from test_engine_http import server, response
from test_volume_journal import inputs
from test_volume_plan import source
from test_volume_resources import body


def reader(client):
    return UnixVolumeReader(client._endpoint, peer_uid=lambda _: os.getuid())


def bound(journal, data, resource_id):
    """Inspect the committed row from an independent SQLite connection."""
    with sqlite3.connect(journal.directory / 'journal.sqlite') as db:
        row = db.execute('SELECT state,revision,nonce FROM resources WHERE resource_id=?', (resource_id,)).fetchone()
    assert row is not None and row[0] in {'observing', 'uncertain'}
    return volume_binding(**data, resource_id=resource_id, journal_id=journal.identity, ownership_nonce=row[2]), row


@pytest.fixture
def scenario(tmp_path, source):
    data = inputs(source)
    rid = data['plan'].resources[0].resourceId
    path = tmp_path / 'volumes'
    with VolumeJournal(path, initialize=True) as journal:
        yield data, rid, journal, path


def test_intent_committed_before_socket_reply_and_terminal_replay_is_history(scenario):
    data, rid, journal, path = scenario
    rows = []
    def reply(connection):
        binding, row = bound(journal, data, rid)
        rows.append(row)
        connection.sendall(response(body(binding)))
    with server(reply=reply) as (client, calls):
        operations = JournaledVolumeObservations(journal, reader(client))
        result = operations.observe(**data, resource_id=rid)
        assert (result.state, result.revision, result.code) == ('labels_observed', 3, 'volume_labels_observed')
        assert rows[0][:2] == ('observing', 2)
        assert operations.observe(**data, resource_id=rid) == result
    assert len(calls) == 2
    assert not {'ready', 'created', 'lease', 'Mountpoint'} & asdict(result).keys()
    assert b'DO-NOT-EXPOSE' not in (path / 'journal.sqlite').read_bytes()
    with journal.locked():
        assert journal.get(rid) == result


def test_restart_recovers_observing_with_same_nonce_and_journal_identity(tmp_path, source):
    data = inputs(source)
    rid = data['plan'].resources[0].resourceId
    path = tmp_path / 'volumes'
    with VolumeJournal(path, initialize=True) as journal, journal.locked():
        journal.prepare(**data, resource_id=rid)
        intent = journal.begin_observation(rid, 1, **data)
        identity, nonce = journal.identity, intent.binding.ownership_nonce
    with VolumeJournal(path) as reopened:
        def reply(connection):
            binding, _ = bound(reopened, data, rid)
            assert binding.journal_id == identity and binding.ownership_nonce == nonce
            connection.sendall(response(body(binding)))
        with server(reply=reply) as (client, calls):
            observed = JournaledVolumeObservations(reopened, reader(client)).observe(**data, resource_id=rid)
        assert observed.state == 'labels_observed' and len(calls) == 2
    with VolumeJournal(path) as last, server() as (client, calls):
        assert JournaledVolumeObservations(last, reader(client)).observe(**data, resource_id=rid) == observed
    assert calls == []


def test_unavailable_reply_is_durable_uncertain_and_explicit_retry_is_read_only(scenario):
    data, rid, journal, _ = scenario
    replies = []
    def reply(connection):
        binding, row = bound(journal, data, rid)
        replies.append(row[:2])
        connection.sendall(response(b'private-error', status=404) if len(replies) == 1 else response(body(binding)))
    with server(reply=reply) as (client, calls):
        operations = JournaledVolumeObservations(journal, reader(client))
        first = operations.observe(**data, resource_id=rid)
        assert (first.state, first.revision) == ('uncertain', 3)
        assert len(calls) == 2
        second = operations.observe(**data, resource_id=rid)
    assert replies == [('observing', 2), ('uncertain', 3)]
    assert (second.state, second.revision) == ('labels_observed', 4)
    assert len(calls) == 4 and all(call.startswith(b'GET ') for call in calls)


def test_other_journal_labels_cannot_be_adopted(scenario, tmp_path):
    data, rid, journal, _ = scenario
    with VolumeJournal(tmp_path / 'other', initialize=True) as other, other.locked():
        other.prepare(**data, resource_id=rid)
        foreign = other.begin_observation(rid, 1, **data).binding
    with server(reply=response(body(foreign))) as (client, calls):
        operations = JournaledVolumeObservations(journal, reader(client))
        result = operations.observe(**data, resource_id=rid)
        assert (result.state, result.code) == ('needs_attention', 'volume_conflict')
        assert operations.observe(**data, resource_id=rid) == result
    assert len(calls) == 2


def test_changed_source_is_rejected_before_any_http(scenario):
    from larenor_server.plugins.volume_plan import build_volume_plan
    data, rid, journal, _ = scenario
    with journal.locked():
        original = journal.prepare(**data, resource_id=rid)
    changed = dict(data)
    changed['policy'] = data['policy'].model_copy(update={'workerPolicyDigest': 'e' * 64})
    changed['plan'] = build_volume_plan(changed['stack'], changed['catalog'], changed['policy'])
    with server() as (client, calls):
        with pytest.raises(ResourceJournalError, match='^idempotency_conflict$'):
            JournaledVolumeObservations(journal, reader(client)).observe(**changed, resource_id=rid)
    assert calls == []
    with journal.locked():
        assert journal.get(rid) == original


@pytest.mark.parametrize('when', ['before', 'body'])
def test_cancel_never_publishes_labels(scenario, when):
    data, rid, journal, _ = scenario
    event = threading.Event()
    if when == 'before':
        event.set()
    def reply(connection):
        binding, _ = bound(journal, data, rid)
        event.set()
        try:
            connection.sendall(response(body(binding)))
        except (BrokenPipeError, ConnectionResetError):
            pass
    with server(reply=reply) as (client, calls):
        operations = JournaledVolumeObservations(journal, reader(client))
        if when == 'before':
            with pytest.raises(VolumeObservationError, match='^volume_cancelled$'):
                operations.observe(**data, resource_id=rid, cancelled=event)
        else:
            result = operations.observe(**data, resource_id=rid, cancelled=event)
            assert (result.state, result.code) == ('uncertain', 'volume_observation_unavailable')
    assert len(calls) == (0 if when == 'before' else 2)
    if when == 'before':
        with journal.locked():
            assert journal.list() == ()


def test_native_journal_and_missing_reader_are_rejected_without_io(tmp_path, scenario):
    _, _, volume, _ = scenario
    class Observer:
        def inspect(self, binding, *, cancelled=None):
            pytest.fail('constructor dispatched observation')
    with ResourceJournal(tmp_path / 'native', initialize=True) as native:
        with pytest.raises(VolumeObservationError, match='^invalid_volume_observation$'):
            JournaledVolumeObservations(native, Observer())
    with pytest.raises(VolumeObservationError, match='^invalid_volume_observation$'):
        JournaledVolumeObservations(volume, object())


def test_cancel_during_terminal_history_read_does_not_publish_retired_result(scenario, monkeypatch):
    data, rid, journal, _ = scenario
    event = threading.Event()
    def reply(connection):
        binding, _ = bound(journal, data, rid)
        connection.sendall(response(body(binding)))
    with server(reply=reply) as (client, calls):
        operations = JournaledVolumeObservations(journal, reader(client))
        historical = operations.observe(**data, resource_id=rid)
        original = journal.prepare
        def cancel(*args, **kwargs):
            result = original(*args, **kwargs)
            event.set()
            return result
        monkeypatch.setattr(journal, 'prepare', cancel)
        with pytest.raises(VolumeObservationError, match='^volume_cancelled$'):
            operations.observe(**data, resource_id=rid, cancelled=event)
    assert len(calls) == 2
    with journal.locked():
        assert journal.get(rid) == historical


def test_first_version_request_already_has_durable_intent_and_one_lease(scenario):
    from test_engine_http import VERSION
    data, rid, journal, path = scenario
    checkpoints = []
    def version(connection):
        binding, row = bound(journal, data, rid)
        checkpoints.append(('version', row[:2], binding.ownership_nonce))
        # SQLite is not left in a transaction while waiting on the socket.
        with sqlite3.connect(path / 'journal.sqlite') as db:
            db.execute('BEGIN IMMEDIATE')
            db.rollback()
        # A competing process-shell cannot get the journal's process lease.
        with pytest.raises(ResourceJournalError, match='^worker_busy$'):
            VolumeJournal(path)
        connection.sendall(response(VERSION))
    def reply(connection):
        binding, row = bound(journal, data, rid)
        checkpoints.append(('inspect', row[:2], binding.ownership_nonce))
        connection.sendall(response(body(binding)))
    with server(version=version, reply=reply) as (client, calls):
        result = JournaledVolumeObservations(journal, reader(client)).observe(**data, resource_id=rid)
    assert [entry[0] for entry in checkpoints] == ['version', 'inspect']
    assert checkpoints[0][1:] == checkpoints[1][1:]
    assert checkpoints[0][1] == ('observing', 2) and len(calls) == 2
    assert result.state == 'labels_observed'


def test_failed_durable_begin_sends_no_http_and_preserves_prepared(scenario, monkeypatch):
    data, rid, journal, _ = scenario
    original = journal._write
    def fail(row, **kwargs):
        if row['state'] == 'observing':
            raise OSError('private durability failure')
        return original(row, **kwargs)
    monkeypatch.setattr(journal, '_write', fail)
    with server() as (client, calls):
        with pytest.raises(ResourceJournalError, match='^journal_unavailable$'):
            JournaledVolumeObservations(journal, reader(client)).observe(**data, resource_id=rid)
    assert calls == []
    with journal.locked():
        assert (journal.get(rid).state, journal.get(rid).revision) == ('prepared', 1)


@pytest.mark.parametrize('stage', ['lease', 'prepare'])
def test_cancel_during_local_work_sends_no_http(scenario, monkeypatch, stage):
    from contextlib import contextmanager
    data, rid, journal, _ = scenario
    event = threading.Event()
    if stage == 'lease':
        original = journal.locked
        @contextmanager
        def cancel():
            with original() as held:
                event.set()
                yield held
        monkeypatch.setattr(journal, 'locked', cancel)
    else:
        original = journal.prepare
        def cancel(*args, **kwargs):
            result = original(*args, **kwargs)
            event.set()
            return result
        monkeypatch.setattr(journal, 'prepare', cancel)
    with server() as (client, calls):
        with pytest.raises(VolumeObservationError, match='^volume_cancelled$'):
            JournaledVolumeObservations(journal, reader(client)).observe(**data, resource_id=rid, cancelled=event)
    assert calls == []
    with journal.locked():
        assert len(journal.list()) == (0 if stage == 'lease' else 1)
        if stage == 'prepare':
            assert journal.get(rid).state == 'prepared'


@pytest.mark.parametrize('bad_event', [True, 1, {}, object()])
def test_invalid_cancel_type_has_no_disk_or_http_work(scenario, bad_event):
    data, rid, journal, _ = scenario
    with server() as (client, calls):
        with pytest.raises(VolumeObservationError, match='^invalid_volume_observation$'):
            JournaledVolumeObservations(journal, reader(client)).observe(**data, resource_id=rid, cancelled=bad_event)
    assert calls == []
    with journal.locked():
        assert journal.list() == ()


def test_reader_property_failure_is_static_and_subclass_is_not_a_volume_domain(scenario):
    _, _, journal, _ = scenario
    class Broken:
        @property
        def inspect(self):
            raise ValueError('private reader metadata')
    with pytest.raises(VolumeObservationError, match='^invalid_volume_observation$'):
        JournaledVolumeObservations(journal, Broken())
    class Derived(VolumeJournal):
        pass
    with pytest.raises(VolumeObservationError, match='^invalid_volume_observation$'):
        JournaledVolumeObservations(object.__new__(Derived), object())
    assert str(VolumeObservationError('private diagnostic')) == 'invalid_volume_observation'


@pytest.mark.parametrize('failure', ['raise', 'wrong_shape'])
def test_trusted_reader_failures_never_persist_or_reflect_raw_payload(scenario, failure):
    data, rid, journal, path = scenario
    class Fault:
        def inspect(self, binding, *, cancelled=None):
            assert journal.get(rid).state == 'observing'
            if failure == 'raise':
                raise ValueError('DO-NOT-EXPOSE-private')
            return {'ready': True, 'payload': 'DO-NOT-EXPOSE-private'}
    result = JournaledVolumeObservations(journal, Fault()).observe(**data, resource_id=rid)
    assert result.state == ('uncertain' if failure == 'raise' else 'needs_attention')
    assert 'DO-NOT-EXPOSE' not in repr(result) + json.dumps(asdict(result))
    assert b'DO-NOT-EXPOSE' not in (path / 'journal.sqlite').read_bytes()


def test_real_read_cannot_overwrite_reentrant_newer_revision(scenario):
    data, rid, journal, _ = scenario
    def reply(connection):
        binding, _ = bound(journal, data, rid)
        connection.sendall(response(body(binding)))
    with server(reply=reply) as (client, calls):
        class Reentrant:
            def inspect(self, binding, *, cancelled=None):
                result = reader(client).inspect(binding, cancelled=cancelled)
                journal.mark_uncertain(rid, 2)
                return result
        with pytest.raises(ResourceJournalError, match='^revision_conflict$'):
            JournaledVolumeObservations(journal, Reentrant()).observe(**data, resource_id=rid)
    assert len(calls) == 2
    with journal.locked():
        assert (journal.get(rid).state, journal.get(rid).revision) == ('uncertain', 3)


def test_alias_change_after_socket_response_cannot_commit_labels(scenario):
    data, rid, journal, _ = scenario
    def reply(connection):
        binding, _ = bound(journal, data, rid)
        connection.sendall(response(body(binding)))
    with server(reply=reply) as (client, calls):
        class ChangedSource:
            def inspect(self, binding, *, cancelled=None):
                result = reader(client).inspect(binding, cancelled=cancelled)
                object.__setattr__(data['policy'], 'workerPolicyDigest', 'e' * 64)
                return result
        with pytest.raises(ResourceJournalError):
            JournaledVolumeObservations(journal, ChangedSource()).observe(**data, resource_id=rid)
    assert len(calls) == 2
    with journal.locked():
        assert (journal.get(rid).state, journal.get(rid).revision) == ('observing', 2)


def test_interrupted_real_read_does_not_claim_success_and_restart_only_observes(scenario):
    data, rid, journal, path = scenario
    def reply(connection):
        binding, _ = bound(journal, data, rid)
        connection.sendall(response(body(binding)))
    with server(reply=reply) as (client, calls):
        class Interrupted:
            def inspect(self, binding, *, cancelled=None):
                reader(client).inspect(binding, cancelled=cancelled)
                raise KeyboardInterrupt()
        with pytest.raises(KeyboardInterrupt):
            JournaledVolumeObservations(journal, Interrupted()).observe(**data, resource_id=rid)
        with journal.locked():
            assert journal.get(rid).state == 'observing'
        with VolumeJournal(path) as reopened:
            result = JournaledVolumeObservations(reopened, reader(client)).observe(**data, resource_id=rid)
    assert result.state == 'labels_observed' and len(calls) == 4
    assert all(call.startswith(b'GET ') for call in calls)


@pytest.mark.parametrize('when', ['before', 'during'])
def test_corrupt_durable_record_is_not_repaired_by_matching_engine(scenario, when):
    data, rid, journal, path = scenario
    with journal.locked():
        journal.prepare(**data, resource_id=rid)
    def corrupt():
        with sqlite3.connect(path / 'journal.sqlite') as db:
            db.execute('UPDATE resources SET digest=? WHERE resource_id=?', ('d' * 64, rid))
    if when == 'before':
        corrupt()
    def reply(connection):
        binding, _ = bound(journal, data, rid)
        wire = response(body(binding))
        corrupt()
        connection.sendall(wire)
    with server(reply=reply) as (client, calls):
        with pytest.raises(ResourceJournalError, match='^journal_unavailable$'):
            JournaledVolumeObservations(journal, reader(client)).observe(**data, resource_id=rid)
    assert len(calls) == (0 if when == 'before' else 2)
    with sqlite3.connect(path / 'journal.sqlite') as db:
        assert db.execute('SELECT digest,observation FROM resources').fetchone() == ('d' * 64, None)


@pytest.mark.parametrize('status', [201, 301, 500])
def test_composition_never_treats_other_status_as_creation_or_missing(scenario, status):
    data, rid, journal, _ = scenario
    with server(reply=response(b'private response', status=status)) as (client, calls):
        result = JournaledVolumeObservations(journal, reader(client)).observe(**data, resource_id=rid)
    assert (result.state, result.code, result.revision) == ('uncertain', 'volume_observation_unavailable', 3)
    assert len(calls) == 2
