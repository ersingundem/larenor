"""Private CREATE history uses real SQLite; observations never grant readiness."""
from contextlib import contextmanager
from dataclasses import asdict
import importlib
import importlib.util
import sqlite3
import subprocess
import sys
import threading

import pytest

from larenor_server.plugins.resource_journal import ResourceJournal, ResourceJournalError
from larenor_server.plugins.volume_journal import VolumeJournal
from larenor_server.plugins.volume_plan import build_volume_plan
from larenor_server.plugins.volume_resources import VolumeResourceError
from test_volume_journal import inputs, observe, error
from test_volume_plan import source


def journal():
    name = 'larenor_server.plugins.volume_create_journal'
    assert importlib.util.find_spec(name) is not None, 'durable volume CREATE protocol is absent'
    return importlib.import_module(name).VolumeCreateJournal


@pytest.mark.parametrize('index', range(7))
def test_each_create_intent_is_durable_and_never_means_installed(tmp_path, source, index):
    cls = journal()
    data = inputs(source)
    rid = data['plan'].resources[index].resourceId
    path = tmp_path / 'create'
    with cls(path, initialize=True) as j:
        assert repr(j) == 'VolumeCreateJournal(<private>)'
        with j.locked():
            prepared = j.prepare(**data, resource_id=rid)
            assert (prepared.state, prepared.revision) == ('prepared', 1)
            intent = j.begin_create(rid, 1, **data)
            assert (intent.receipt.state, intent.receipt.revision) == ('mutating', 2)
            identity, nonce = j.identity, intent.binding.ownership_nonce
            assert nonce != identity and len(nonce) == 32
            assert data['plan'].installAvailable is False
            error('volume_effects_disabled', lambda: j.begin(rid, 2, **data))
    with cls(path) as j:
        with j.locked():
            assert j.identity == identity
            assert j.bind(rid, 2, **data).binding.ownership_nonce == nonce
            error('reconciliation_required', lambda: j.begin_create(rid, 2, **data))
            result = j.reconcile(rid, 2, observe, **data)
            assert (result.state, result.revision) == ('observed_requires_bootstrap', 3)
            assert result.code == 'volume_labels_observed'
            assert j.prepare(**data, resource_id=rid) == result
            assert not {'name', 'Mountpoint', 'ownership_nonce', 'ready', 'installed'} & set(asdict(result))
            error('invalid_transition', lambda: j.begin_create(rid, 3, **data))
    with cls(path) as j:
        with j.locked():
            assert j.list() == (result,) and j.get(rid) == result
    assert b'DO-NOT-EXPOSE' not in (path / 'journal.sqlite').read_bytes()


@pytest.mark.parametrize('existing', [ResourceJournal, VolumeJournal])
@pytest.mark.parametrize('reverse', [False, True])
def test_even_empty_old_domains_are_not_creation_intents(tmp_path, existing, reverse):
    cls = journal()
    first, second = (cls, existing) if reverse else (existing, cls)
    path = tmp_path / 'journal'
    with first(path, initialize=True):
        pass
    before = {p.name: p.read_bytes() for p in path.iterdir()}
    error('journal_unavailable', lambda: second(path, initialize=True))
    assert {p.name: p.read_bytes() for p in path.iterdir()} == before


@pytest.mark.parametrize('revision', [True, False, 1.0, '1', 0, -1, 2**63 - 1])
def test_revision_rejection_cannot_begin_create(tmp_path, source, revision):
    cls = journal()
    data = inputs(source)
    rid = data['plan'].resources[0].resourceId
    with cls(tmp_path / 'create', initialize=True) as j:
        error('lock_required', lambda: j.prepare(**data, resource_id=rid))
        with j.locked():
            before = j.prepare(**data, resource_id=rid)
            error('revision_conflict', lambda: j.begin_create(rid, revision, **data))
            assert j.get(rid) == before
            error('worker_busy', j.close)


def test_commit_then_lost_begin_ack_is_readonly_after_reopen(tmp_path, source, monkeypatch):
    cls = journal()
    data = inputs(source)
    rid = data['plan'].resources[0].resourceId
    path = tmp_path / 'create'
    with cls(path, initialize=True) as j:
        with j.locked():
            j.prepare(**data, resource_id=rid)
            transaction = j._transaction
            @contextmanager
            def lost_ack():
                with transaction():
                    yield
                raise OSError('synthetic private failure after durable commit')
            monkeypatch.setattr(j, '_transaction', lost_ack)
            error('journal_unavailable', lambda: j.begin_create(rid, 1, **data))
    with cls(path) as j:
        with j.locked():
            assert j.get(rid).state == 'mutating'
            error('reconciliation_required', lambda: j.begin_create(rid, 2, **data))
            assert j.mark_uncertain(rid, 2).state == 'uncertain'
            error('reconciliation_required', lambda: j.begin_create(rid, 3, **data))
            assert j.reconcile(rid, 3, observe, **data).state == 'observed_requires_bootstrap'


def test_foreign_observation_never_adopts_existing_volume(tmp_path, source):
    cls = journal()
    data = inputs(source)
    rid = data['plan'].resources[0].resourceId
    with cls(tmp_path / 'a', initialize=True) as a, VolumeJournal(tmp_path / 'old', initialize=True) as old:
        with a.locked(), old.locked():
            a.prepare(**data, resource_id=rid)
            old.prepare(**data, resource_id=rid)
            old_intent = old.begin_observation(rid, 1, **data)
            a.begin_create(rid, 1, **data)
            outcome = a.reconcile(rid, 2, lambda _: observe(old_intent), **data)
            assert (outcome.state, outcome.code) == ('needs_attention', 'volume_observation_invalid')


@pytest.mark.parametrize('outcome', ['conflict', 'exception', 'dict', 'none'])
def test_unproven_observer_cannot_claim_ready(tmp_path, source, outcome):
    cls = journal()
    data = inputs(source)
    rid = data['plan'].resources[0].resourceId
    with cls(tmp_path / 'create', initialize=True) as j:
        with j.locked():
            j.prepare(**data, resource_id=rid)
            j.begin_create(rid, 1, **data)
            def observer(intent):
                if outcome == 'conflict':
                    raise VolumeResourceError('volume_conflict')
                if outcome == 'exception':
                    raise RuntimeError('synthetic-private-token')
                return asdict(observe(intent)) if outcome == 'dict' else None
            result = j.reconcile(rid, 2, observer, **data)
            expected = ('uncertain', 'volume_observation_unavailable') if outcome == 'exception' else (
                'needs_attention', 'volume_conflict' if outcome == 'conflict' else 'volume_observation_invalid')
            assert (result.state, result.code) == expected
            assert 'synthetic-private' not in repr(result)


def test_reentrant_revision_and_cancel_keep_newer_state(tmp_path, source):
    cls = journal()
    data = inputs(source)
    rid = data['plan'].resources[0].resourceId
    cancelled = threading.Event()
    with cls(tmp_path / 'create', initialize=True) as j:
        with j.locked():
            j.prepare(**data, resource_id=rid)
            j.begin_create(rid, 1, **data)
            def reenter(intent):
                j.mark_uncertain(rid, 2)
                return observe(intent)
            error('revision_conflict', lambda: j.reconcile(rid, 2, reenter, **data))
            assert j.get(rid).revision == 3
            def cancel(intent):
                cancelled.set()
                return observe(intent)
            result = j.reconcile(rid, 3, cancel, cancelled=cancelled, **data)
            assert (result.state, result.revision) == ('uncertain', 4)
            called = []
            error('volume_cancelled', lambda: j.reconcile(rid, 4, lambda i: called.append(i),
                                                         cancelled=cancelled, **data))
            assert called == [] and j.get(rid) == result


def test_current_policy_and_callback_source_tampering_are_rejected(tmp_path, source):
    cls = journal()
    data = inputs(source)
    rid = data['plan'].resources[0].resourceId
    with cls(tmp_path / 'create', initialize=True) as j:
        with j.locked():
            first = j.prepare(**data, resource_id=rid)
            changed = dict(data)
            changed['policy'] = data['policy'].model_copy(update={'workerPolicyDigest': 'e' * 64})
            changed['plan'] = build_volume_plan(changed['stack'], changed['catalog'], changed['policy'])
            error('idempotency_conflict', lambda: j.begin_create(rid, 1, **changed))
            assert j.get(rid) == first
            j.begin_create(rid, 1, **data)
            def tamper(intent):
                result = observe(intent)
                object.__setattr__(data['policy'], 'workerPolicyDigest', 'e' * 64)
                return result
            with pytest.raises(ResourceJournalError):
                j.reconcile(rid, 2, tamper, **data)
            assert j.get(rid).state == 'mutating'


def test_corruption_is_preserved_and_never_reinitialized(tmp_path, source):
    cls = journal()
    data = inputs(source)
    rid = data['plan'].resources[0].resourceId
    path = tmp_path / 'create'
    with cls(path, initialize=True) as j:
        with j.locked():
            j.prepare(**data, resource_id=rid)
    with sqlite3.connect(path / 'journal.sqlite') as db:
        db.execute('UPDATE resources SET state=?', ('observed_requires_bootstrap',))
    before = (path / 'journal.sqlite').read_bytes()
    error('journal_unavailable', lambda: cls(path, initialize=True))
    assert (path / 'journal.sqlite').read_bytes() == before


@pytest.mark.parametrize('field,value', [
    ('resource_id', 'e' * 32), ('name', 'foreign'), ('plan_hash', 'e' * 64),
    ('labels_digest', 'e' * 64), ('state', 'ready'), ('extra', 'synthetic-private'),
])
def test_typed_but_modified_observation_is_not_a_creation_receipt(tmp_path, source, field, value):
    cls = journal()
    data = inputs(source)
    rid = data['plan'].resources[0].resourceId
    with cls(tmp_path / 'create', initialize=True) as j:
        with j.locked():
            j.prepare(**data, resource_id=rid)
            j.begin_create(rid, 1, **data)
            def forged(intent):
                result = observe(intent)
                object.__setattr__(result, field, value)
                return result
            result = j.reconcile(rid, 2, forged, **data)
            assert result.state == 'needs_attention'
            assert result.code == 'volume_observation_invalid'


def test_other_journal_mutators_cannot_reinterpret_create_state(tmp_path, source):
    cls = journal()
    data = inputs(source)
    rid = data['plan'].resources[0].resourceId
    with cls(tmp_path / 'create', initialize=True) as j:
        with j.locked():
            prepared = j.prepare(**data, resource_id=rid)
            for method in (ResourceJournal.begin, VolumeJournal.begin_observation):
                with pytest.raises(ResourceJournalError):
                    method(j, rid, 1, **data)
                assert j.get(rid) == prepared
            j.begin_create(rid, 1, **data)
            started = j.get(rid)
            with pytest.raises(ResourceJournalError):
                ResourceJournal.mark_uncertain(j, rid, 2)
            with pytest.raises(ResourceJournalError):
                ResourceJournal.reconcile(j, rid, 2, observe, **data)
            assert j.get(rid) == started


def test_lease_excludes_other_process_and_releases_after_close(tmp_path, source):
    cls = journal()
    path = tmp_path / 'create'
    script = '''
import sys
from larenor_server.plugins.volume_create_journal import VolumeCreateJournal
from larenor_server.plugins.resource_journal import ResourceJournalError
try:
    with VolumeCreateJournal(sys.argv[1]) as journal:
        with journal.locked(): print('opened')
except ResourceJournalError as error:
    print(error.code)
'''
    def child():
        completed = subprocess.run([sys.executable, '-c', script, str(path)],
            capture_output=True, text=True, timeout=10, check=True)
        assert completed.stderr == ''
        return completed.stdout.strip()
    with cls(path, initialize=True) as j:
        with j.locked():
            j.prepare(**inputs(source), resource_id=inputs(source)['plan'].resources[0].resourceId)
            assert child() == 'worker_busy'
    assert child() == 'opened'


@pytest.mark.parametrize('replacement', ['file', 'symlink', 'mode'])
def test_open_lease_detects_private_storage_identity_change(tmp_path, source, replacement):
    cls = journal()
    path = tmp_path / 'create'
    data = inputs(source)
    rid = data['plan'].resources[0].resourceId
    with cls(path, initialize=True) as j:
        with j.locked():
            j.prepare(**data, resource_id=rid)
            target = path / 'identity.json'
            saved = path / 'old-identity'
            if replacement == 'mode':
                target.chmod(0o644)
            else:
                target.rename(saved)
                if replacement == 'symlink':
                    target.symlink_to(saved)
                else:
                    target.write_bytes(saved.read_bytes())
                    target.chmod(0o600)
            error('unsafe_worker_path', lambda: j.begin_create(rid, 1, **data))
            # Only restore this test-owned path to allow the normal lease cleanup.
            if replacement == 'mode':
                target.chmod(0o600)
            else:
                target.unlink()
                saved.rename(target)
            assert j.get(rid).state == 'prepared'


def test_quota_refuses_new_intent_but_preserves_existing_history(tmp_path, source, monkeypatch):
    cls = journal()
    module = importlib.import_module(cls.__module__)
    monkeypatch.setattr(module, 'MAX_VOLUME_CREATES', 1)
    data = inputs(source)
    first, second = data['plan'].resources[:2]
    with cls(tmp_path / 'create', initialize=True) as j:
        with j.locked():
            existing = j.prepare(**data, resource_id=first.resourceId)
            error('journal_capacity', lambda: j.prepare(**data, resource_id=second.resourceId))
            assert j.list() == (existing,)
            assert j.prepare(**data, resource_id=first.resourceId) == existing


@pytest.mark.parametrize('change', ['trigger', 'delete', 'payload', 'nonce', 'revision', 'domain'])
def test_schema_and_integrity_changes_fail_closed_on_restart(tmp_path, source, change):
    cls = journal()
    data = inputs(source)
    rid = data['plan'].resources[0].resourceId
    path = tmp_path / 'create'
    with cls(path, initialize=True) as j:
        with j.locked():
            j.prepare(**data, resource_id=rid)
    with sqlite3.connect(path / 'journal.sqlite') as db:
        if change == 'trigger':
            db.execute('CREATE TRIGGER unexpected AFTER UPDATE ON resources BEGIN SELECT 1; END')
        elif change == 'delete':
            db.execute('DELETE FROM resources')
        elif change == 'domain':
            db.execute('UPDATE metadata SET digest=?', ('e' * 64,))
        else:
            value = {'payload': '{}', 'nonce': 'e' * 32, 'revision': 2}[change]
            db.execute(f'UPDATE resources SET {change}=?', (value,))
    before = (path / 'journal.sqlite').read_bytes()
    error('journal_unavailable', lambda: cls(path, initialize=True))
    assert (path / 'journal.sqlite').read_bytes() == before


def test_snapshots_and_receipts_do_not_alias_callers(tmp_path, source):
    cls = journal()
    data = inputs(source)
    rid = data['plan'].resources[0].resourceId
    with cls(tmp_path / 'create', initialize=True) as j:
        with j.locked():
            receipt = j.prepare(**data, resource_id=rid)
            bound = j.bind(rid, 1, **data)
            object.__setattr__(receipt, 'state', 'installed')
            object.__setattr__(bound.binding.source[0], 'installAvailable', True)
            assert j.get(rid).state == 'prepared'
            assert j.bind(rid, 1, **data).binding.source[0].installAvailable is False
