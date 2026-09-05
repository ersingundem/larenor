"""Private resource receipts only. Synthetic observers, never Docker or mkdir effects."""

from concurrent.futures import ThreadPoolExecutor
import os
from pathlib import Path
import sqlite3
import hashlib
import json
import multiprocessing
from dataclasses import replace

import pytest

from larenor_server.plugins.resource_journal import (
    ResourceJournal, ResourceJournalError, ResourceObservation,
    ImageIdentity, NetworkIdentity, DirectoryIdentity, AppdataIdentity,
)
from larenor_server.context import ContextResponse
from larenor_server.plugins.catalog import load_catalog
from larenor_server.plugins.stack_plan import build_media_stack_plan
from larenor_server.plugins.resource_models import WorkerPolicyBinding
from larenor_server.plugins.resource_plan import build_resource_plan


def rejected(code, action):
    with pytest.raises(ResourceJournalError) as caught:
        action()
    assert str(caught.value) == caught.value.code == code


@pytest.fixture
def journal(tmp_path):
    value = ResourceJournal(tmp_path / 'resources-v1', initialize=True)
    yield value
    value.close()


def test_first_initialization_is_private_and_reopens_identical_identity(tmp_path):
    directory = tmp_path / 'resources-v1'
    with ResourceJournal(directory, initialize=True) as first:
        identity = first.identity
        assert len(identity) == 32 and all(c in '0123456789abcdef' for c in identity)
        assert str(directory) not in repr(first)
        assert directory.stat().st_mode & 0o777 == 0o700
        assert {entry.name for entry in directory.iterdir()} == {'journal.sqlite', 'journal.lock', 'identity.json'}
        assert all(entry.stat().st_mode & 0o777 == 0o600 for entry in directory.iterdir())
        with first.locked():
            assert first.list() == ()
    with ResourceJournal(directory, initialize=True) as reopened:
        assert reopened.identity == identity
        with reopened.locked():
            assert reopened.list() == ()


@pytest.mark.parametrize('missing', ['journal.sqlite', 'journal.lock', 'identity.json'])
@pytest.mark.parametrize('initialize', [False, True])
def test_missing_current_files_never_regenerate_or_reset(tmp_path, missing, initialize):
    directory = tmp_path / 'resources-v1'
    with ResourceJournal(directory, initialize=True):
        pass
    (directory / missing).unlink()
    rejected('journal_unavailable', lambda: ResourceJournal(directory, initialize=initialize))
    assert not (directory / missing).exists()


def test_preexisting_empty_directory_is_not_adopted(tmp_path):
    directory = tmp_path / 'resources-v1'
    directory.mkdir(mode=0o700)
    rejected('journal_unavailable', lambda: ResourceJournal(directory, initialize=True))
    assert list(directory.iterdir()) == []


def test_parent_must_exist_and_have_private_operator_ownership(tmp_path):
    parent = tmp_path / 'public'
    parent.mkdir(mode=0o777)
    parent.chmod(0o777)
    rejected('unsafe_worker_path', lambda: ResourceJournal(parent / 'resources-v1', initialize=True))
    assert not (parent / 'resources-v1').exists()
    rejected('unsafe_worker_path', lambda: ResourceJournal(tmp_path / 'missing' / 'resources-v1', initialize=True))


@pytest.mark.parametrize('target', ['directory', 'journal.sqlite', 'journal.lock', 'identity.json', 'journal.sqlite-journal'])
def test_symlink_never_follows_or_changes_foreign_target(tmp_path, target):
    directory = tmp_path / 'resources-v1'
    with ResourceJournal(directory, initialize=True):
        pass
    if target == 'directory':
        real = tmp_path / 'real'
        directory.rename(real)
        directory.symlink_to(real, target_is_directory=True)
        selected = real / 'identity.json'
    else:
        selected = tmp_path / 'foreign-file'
        selected.write_bytes(b'foreign-content')
        selected.chmod(0o600)
        path = directory / target
        if path.exists():
            path.unlink()
        path.symlink_to(selected)
    before = selected.read_bytes()
    rejected('unsafe_worker_path', lambda: ResourceJournal(directory))
    assert selected.read_bytes() == before


@pytest.mark.parametrize('name', ['journal.sqlite', 'journal.lock', 'identity.json'])
def test_hardlinked_or_public_files_are_not_accepted(tmp_path, name):
    directory = tmp_path / 'resources-v1'
    with ResourceJournal(directory, initialize=True):
        pass
    target = directory / name
    target.chmod(0o640)
    rejected('unsafe_worker_path', lambda: ResourceJournal(directory))
    target.chmod(0o600)
    os.link(target, tmp_path / 'alias')
    rejected('unsafe_worker_path', lambda: ResourceJournal(directory))


def test_lock_is_required_and_never_released_during_an_active_effect(journal):
    rejected('lock_required', journal.list)
    with journal.locked():
        assert journal.list() == ()
        rejected('worker_busy', journal.close)
        def other_thread():
            rejected('lock_required', journal.list)
            with pytest.raises(ResourceJournalError, match='^worker_busy$'):
                with journal.locked():
                    pass
        with ThreadPoolExecutor(max_workers=1) as pool:
            pool.submit(other_thread).result()
    with journal.locked():
        assert journal.list() == ()


def test_independent_process_lock_prevents_overlapping_leases(journal):
    with ResourceJournal(journal.directory) as other:
        with journal.locked():
            with pytest.raises(ResourceJournalError, match='^worker_busy$'):
                with other.locked():
                    pass
        with other.locked():
            assert other.list() == ()


@pytest.mark.parametrize('target', ['directory', 'journal.sqlite', 'journal.lock', 'identity.json'])
def test_path_identity_replacement_after_open_fails_before_receipt_write(journal, target):
    if target == 'directory':
        path = journal.directory
        replacement = path.with_name('moved')
        path.rename(replacement)
        path.mkdir(mode=0o700)
    else:
        path = journal.directory / target
        old = path.with_name(target + '.old')
        path.rename(old)
        path.write_bytes(old.read_bytes())
        path.chmod(0o600)
    with pytest.raises(ResourceJournalError, match='^unsafe_worker_path$'):
        with journal.locked():
            pass


@pytest.mark.parametrize('damage', ['metadata_identity', 'metadata_version', 'metadata_count', 'metadata_digest', 'columns', 'unique', 'extra_table'])
def test_full_schema_and_metadata_integrity_fail_on_an_empty_current_journal(tmp_path, damage):
    directory = tmp_path / 'resources-v1'
    with ResourceJournal(directory, initialize=True):
        pass
    with sqlite3.connect(directory / 'journal.sqlite') as db:
        if damage.startswith('metadata_'):
            column = damage.removeprefix('metadata_')
            value = 9 if column in ('version', 'count') else 'f' * (32 if column == 'identity' else 64)
            db.execute(f'UPDATE metadata SET {column}=?', (value,))
        elif damage == 'columns':
            db.execute('ALTER TABLE resources ADD COLUMN untrusted TEXT')
        elif damage == 'extra_table':
            db.execute('CREATE TABLE foreign_state(value TEXT)')
        else:
            source = db.execute("SELECT sql FROM sqlite_master WHERE name='resources'").fetchone()[0]
            assert 'UNIQUE(preparation_id,resource_id,kind)' in source
            db.execute('DROP TABLE resources')
            db.execute(source.replace('UNIQUE(preparation_id,resource_id,kind)', 'CHECK(1)'))
    rejected('journal_unavailable', lambda: ResourceJournal(directory))


def test_close_is_idempotent_and_closed_journal_cannot_observe(journal):
    journal.close()
    journal.close()
    with pytest.raises(ResourceJournalError, match='^journal_unavailable$'):
        with journal.locked():
            pass


@pytest.fixture
def source():
    catalog = load_catalog()
    stack = build_media_stack_plan(catalog, {}, 'linux/amd64',
        ContextResponse(schemaVersion=1, coreId='a' * 32, homeId='b' * 32), 'c' * 32)
    policy = WorkerPolicyBinding(schemaVersion=1, workerPolicyVersion=1, workerPolicyDigest='d' * 64)
    plan = build_resource_plan(stack, catalog, policy)
    return dict(plan=plan, stack=stack, catalog=catalog, policy=policy)


def prepared(journal, source, index=0):
    return journal.prepare(**source, resource_id=source['plan'].resources[index].resourceId)


def observation(intent, status='matched', identity=None):
    resource = intent.resource
    if status == 'matched' and identity is None:
        if resource.kind == 'ensure_image':
            identity = ImageIdentity(resource.image.configDigest)
        elif resource.kind == 'prepare_control_network':
            identity = NetworkIdentity('e' * 64)
        else:
            identity = AppdataIdentity(DirectoryIdentity(1, 2, 1000, 1000, 0o700),
                tuple(DirectoryIdentity(1, n + 3, 1000, 1000, 0o700) for n in range(len(resource.mounts))))
    return ResourceObservation(status=status, resource_id=resource.resourceId,
        journal_id=intent.journal_id, ownership_nonce=intent.ownership_nonce,
        specification_digest=intent.specification_digest, identity=identity)


@pytest.mark.parametrize('index', [0, 1, 12])
def test_full_plan_rederived_intent_is_durable_before_effect_and_receipt_is_internal(journal, source, index):
    with journal.locked():
        receipt = prepared(journal, source, index)
        assert (receipt.state, receipt.revision, receipt.code) == ('prepared', 1, 'resource_prepared')
        assert prepared(journal, source, index) == receipt
        intent = journal.begin(receipt.resource_id, 1, **source)
        assert intent.receipt.state == 'mutating' and intent.receipt.revision == 2
        assert intent.resource == source['plan'].resources[index]
        assert len(intent.ownership_nonce) == 32
        assert intent.specification_digest == hashlib.sha256(json.dumps(
            intent.resource.model_dump(mode='json'), sort_keys=True,
            separators=(',', ':'), ensure_ascii=False, allow_nan=False).encode()).hexdigest()
        with sqlite3.connect(journal.directory / 'journal.sqlite') as independent:
            assert independent.execute('SELECT state,revision FROM resources').fetchone() == ('mutating', 2)
        def read_only_adapter(actual):
            assert actual == intent
            # Observation is outside a SQLite write transaction but inside the
            # caller's whole-effect lease. It cannot prove physical identity here.
            with sqlite3.connect(journal.directory / 'journal.sqlite', timeout=0) as independent:
                independent.execute('BEGIN IMMEDIATE')
                independent.rollback()
            return observation(actual)
        ready = journal.reconcile(receipt.resource_id, 2, read_only_adapter, **source)
        assert (ready.state, ready.revision, ready.code) == ('ready', 3, 'resource_matched')
        assert journal.get(receipt.resource_id) == ready
        assert journal.list() == (ready,)
        assert intent.ownership_nonce not in repr(intent)
        assert 'relativePath' not in repr(ready) and '/larenor' not in repr(ready)
        rejected('invalid_transition', lambda: journal.begin(receipt.resource_id, 3, **source))
        rejected('invalid_transition', lambda: journal.reconcile(receipt.resource_id, 3, read_only_adapter, **source))


def test_restart_after_lost_response_can_only_reconcile_not_repeat_effect(tmp_path, source):
    directory = tmp_path / 'resources-v1'
    with ResourceJournal(directory, initialize=True) as first, first.locked():
        receipt = prepared(first, source)
        before = first.begin(receipt.resource_id, 1, **source)
    with ResourceJournal(directory) as second, second.locked():
        assert second.get(receipt.resource_id) == before.receipt
        rejected('reconciliation_required', lambda: second.begin(receipt.resource_id, 2, **source))
        def match(intent):
            assert intent == before
            return observation(intent)
        assert second.reconcile(receipt.resource_id, 2, match, **source).state == 'ready'


@pytest.mark.parametrize('status,state,code', [
    ('missing', 'needs_attention', 'resource_missing'),
    ('conflict', 'needs_attention', 'resource_conflict'),
    ('multiple', 'needs_attention', 'resource_multiple'),
    ('unavailable', 'uncertain', 'observation_unavailable'),
])
def test_reconciliation_never_adopts_or_recreates_unmatched_resources(journal, source, status, state, code):
    with journal.locked():
        receipt = prepared(journal, source)
        journal.begin(receipt.resource_id, 1, **source)
        result = journal.reconcile(receipt.resource_id, 2, lambda intent: observation(intent, status), **source)
        assert (result.state, result.revision, result.code) == (state, 3, code)
        rejected('reconciliation_required' if state == 'uncertain' else 'invalid_transition',
            lambda: journal.begin(receipt.resource_id, 3, **source))
        if state == 'uncertain':
            assert journal.reconcile(receipt.resource_id, 3, observation, **source).state == 'ready'


def test_explicit_uncertainty_and_observer_errors_are_static_and_leave_no_effect_retry(journal, source):
    with journal.locked():
        receipt = prepared(journal, source)
        rejected('invalid_transition', lambda: journal.mark_uncertain(receipt.resource_id, 1))
        journal.begin(receipt.resource_id, 1, **source)
        receipt = journal.mark_uncertain(receipt.resource_id, 2)
        assert (receipt.state, receipt.code, receipt.revision) == ('uncertain', 'effect_uncertain', 3)
        def broken(_):
            raise OSError('/private/secret.token actual-password')
        receipt = journal.reconcile(receipt.resource_id, 3, broken, **source)
        assert (receipt.state, receipt.code, receipt.revision) == ('uncertain', 'observation_unavailable', 4)
        assert b'actual-password' not in (journal.directory / 'journal.sqlite').read_bytes()


@pytest.mark.parametrize('damage', ['resource_id', 'journal_id', 'ownership_nonce', 'specification_digest', 'kind', 'image_id', 'mapping', 'raw', 'hidden'])
def test_observation_binding_identity_and_type_are_rechecked(journal, source, damage):
    with journal.locked():
        receipt = prepared(journal, source)
        journal.begin(receipt.resource_id, 1, **source)
        def bad(intent):
            result = observation(intent)
            if damage in ('resource_id', 'journal_id', 'ownership_nonce', 'specification_digest'):
                return replace(result, **{damage: 'f' * (64 if damage == 'specification_digest' else 32)})
            if damage == 'kind':
                return replace(result, identity=NetworkIdentity('f' * 64))
            if damage == 'image_id':
                return replace(result, identity=ImageIdentity('sha256:' + 'f' * 64))
            if damage == 'mapping':
                return replace(result, identity=None)
            if damage == 'hidden':
                object.__setattr__(result, 'secret', 'secret-value')
                return result
            return {'status': 'matched'}
        result = journal.reconcile(receipt.resource_id, 2, bad, **source)
        assert (result.state, result.code) == ('needs_attention', 'observation_invalid')


@pytest.mark.parametrize('damage', ['plan_hash', 'policy', 'stack', 'bool', 'unknown_resource'])
def test_untrusted_source_rejected_before_first_receipt_or_observer(journal, source, damage):
    altered = dict(source)
    resource_id = source['plan'].resources[0].resourceId
    if damage == 'plan_hash':
        altered['plan'] = source['plan'].model_copy(update={'planHash': 'f' * 64})
    elif damage == 'policy':
        altered['policy'] = source['policy'].model_copy(update={'workerPolicyDigest': 'f' * 64})
    elif damage == 'stack':
        altered['stack'] = source['stack'].model_copy(update={'preparationId': 'f' * 32})
    elif damage == 'bool':
        altered['plan'] = source['plan'].model_copy(update={'workerPolicyVersion': True})
    else:
        resource_id = 'f' * 32
    with journal.locked():
        rejected('invalid_binding', lambda: journal.prepare(**altered, resource_id=resource_id))
        assert journal.list() == ()


def test_current_catalog_and_policy_are_required_for_effect_and_reconcile_but_not_history(journal, source, monkeypatch):
    with journal.locked():
        receipt = prepared(journal, source)
        different = dict(source)
        different['policy'] = source['policy'].model_copy(update={'workerPolicyVersion': 2})
        different['plan'] = build_resource_plan(different['stack'], different['catalog'], different['policy'])
        rejected('idempotency_conflict', lambda: prepared(journal, different))
        rejected('idempotency_conflict', lambda: journal.begin(receipt.resource_id, 1, **different))
        journal.begin(receipt.resource_id, 1, **source)
        rejected('idempotency_conflict', lambda: journal.reconcile(receipt.resource_id, 2,
            lambda _: pytest.fail('observer must not run'), **different))
    journal.close()
    import larenor_server.plugins.resource_journal as module
    monkeypatch.setattr(module, 'verify_resource_plan', lambda *args: pytest.fail('history must not use current catalog'))
    with ResourceJournal(journal.directory) as reopened, reopened.locked():
        assert reopened.get(receipt.resource_id).state == 'mutating'


@pytest.mark.parametrize('column,value', [('state', 'ready'), ('revision', 9), ('code', 'resource_matched'),
    ('preparation_id', 'f' * 32), ('kind', 'prepare_appdata'), ('nonce', 'f' * 32),
    ('payload', '{}'), ('observation', '{}'), ('digest', 'f' * 64)])
def test_every_stored_receipt_field_is_integrity_bound(tmp_path, source, column, value):
    directory = tmp_path / 'resources-v1'
    with ResourceJournal(directory, initialize=True) as journal, journal.locked():
        prepared(journal, source)
    with sqlite3.connect(directory / 'journal.sqlite') as db:
        db.execute(f'UPDATE resources SET {column}=?', (value,))
    rejected('journal_unavailable', lambda: ResourceJournal(directory))


def test_deleted_rows_and_concurrent_stale_revisions_are_not_replayed(journal, source):
    with journal.locked():
        receipt = prepared(journal, source)
        rejected('revision_conflict', lambda: journal.begin(receipt.resource_id, True, **source))
        journal.begin(receipt.resource_id, 1, **source)
        rejected('revision_conflict', lambda: journal.mark_uncertain(receipt.resource_id, 1))
        rejected('resource_not_found', lambda: journal.get('f' * 32))
    directory = journal.directory
    journal.close()
    with sqlite3.connect(directory / 'journal.sqlite') as db:
        db.execute('DELETE FROM resources')
    rejected('journal_unavailable', lambda: ResourceJournal(directory))


def test_resource_capacity_is_bounded_and_existing_replay_still_works(journal, source, monkeypatch):
    import larenor_server.plugins.resource_journal as module
    monkeypatch.setattr(module, 'MAX_RESOURCES', 1)
    with journal.locked():
        first = prepared(journal, source)
        rejected('journal_capacity', lambda: prepared(journal, source, 1))
        assert prepared(journal, source) == first


def _try_process_lock(directory, send):
    try:
        with ResourceJournal(directory) as other, other.locked():
            send.send('incorrectly_acquired')
    except ResourceJournalError as error:
        send.send(error.code)
    finally:
        send.close()


def test_actual_child_process_cannot_acquire_live_effect_lease(journal):
    context = multiprocessing.get_context('spawn')
    receiving, sending = context.Pipe(duplex=False)
    with journal.locked():
        child = context.Process(target=_try_process_lock, args=(journal.directory, sending))
        child.start()
        sending.close()
        try:
            assert receiving.poll(5)
            assert receiving.recv() == 'worker_busy'
            child.join(5)
            assert not child.is_alive() and child.exitcode == 0
        finally:
            if child.is_alive():
                child.kill()
                child.join(5)
            receiving.close()


def test_sqlite_failure_rolls_back_receipt_and_metadata_before_effect(journal, source):
    with journal.locked():
        receipt = prepared(journal, source)
        def deny_metadata(operation, first, *_):
            return sqlite3.SQLITE_DENY if operation == sqlite3.SQLITE_UPDATE and first == 'metadata' else sqlite3.SQLITE_OK
        journal._db.set_authorizer(deny_metadata)
        try:
            rejected('journal_unavailable', lambda: journal.begin(receipt.resource_id, 1, **source))
        finally:
            journal._db.set_authorizer(None)
        assert journal.get(receipt.resource_id) == receipt
    directory = journal.directory
    journal.close()
    with ResourceJournal(directory) as reopened, reopened.locked():
        assert reopened.get(receipt.resource_id) == receipt


def test_process_exit_during_observation_leaves_mutating_intent_and_releases_lease(journal, source):
    with journal.locked():
        receipt = prepared(journal, source)
        journal.begin(receipt.resource_id, 1, **source)
    def dies(_):
        raise SystemExit(23)
    with pytest.raises(SystemExit) as caught:
        with journal.locked():
            journal.reconcile(receipt.resource_id, 2, dies, **source)
    assert caught.value.code == 23
    directory = journal.directory
    journal.close()
    with ResourceJournal(directory) as reopened, reopened.locked():
        assert reopened.get(receipt.resource_id).state == 'mutating'
        rejected('reconciliation_required', lambda: reopened.begin(receipt.resource_id, 2, **source))
        assert reopened.reconcile(receipt.resource_id, 2, observation, **source).state == 'ready'


def test_reentrant_observer_cannot_overwrite_a_newer_revision(journal, source):
    with journal.locked():
        receipt = prepared(journal, source)
        journal.begin(receipt.resource_id, 1, **source)
        def nested(intent):
            journal.mark_uncertain(receipt.resource_id, 2)
            return observation(intent)
        rejected('revision_conflict', lambda: journal.reconcile(receipt.resource_id, 2, nested, **source))
        assert (journal.get(receipt.resource_id).state, journal.get(receipt.resource_id).revision) == ('uncertain', 3)


@pytest.mark.parametrize('index', [0, 1, 12])
def test_ready_and_attention_receipts_survive_restart_with_private_bound_observation(journal, source, index):
    with journal.locked():
        first = prepared(journal, source, index)
        journal.begin(first.resource_id, 1, **source)
        ready = journal.reconcile(first.resource_id, 2, observation, **source)
        missing = prepared(journal, source, 2)
        journal.begin(missing.resource_id, 1, **source)
        attention = journal.reconcile(missing.resource_id, 2, lambda intent: observation(intent, 'missing'), **source)
    directory = journal.directory
    journal.close()
    with ResourceJournal(directory) as reopened, reopened.locked():
        assert reopened.get(first.resource_id) == ready
        assert reopened.get(missing.resource_id) == attention
        assert prepared(reopened, source, index) == ready


@pytest.mark.parametrize('damage', ['duplicate_inode', 'wrong_mount_count', 'bool_inode', 'hidden_field', 'uid_overflow', 'raw_mounts'])
def test_appdata_identity_is_a_bounded_strict_tuple_not_an_unchecked_mapping(journal, source, damage):
    with journal.locked():
        receipt = prepared(journal, source, 1)
        journal.begin(receipt.resource_id, 1, **source)
        def bad(intent):
            value = observation(intent)
            identity = value.identity
            if damage == 'duplicate_inode':
                identity = replace(identity, mounts=(identity.root,))
            elif damage == 'wrong_mount_count':
                identity = replace(identity, mounts=())
            elif damage == 'bool_inode':
                identity = replace(identity, root=replace(identity.root, inode=True))
            elif damage == 'hidden_field':
                object.__setattr__(identity.root, 'secret', 'no-storage')
            elif damage == 'uid_overflow':
                identity = replace(identity, root=replace(identity.root, uid=2**64))
            else:
                identity = replace(identity, mounts=[identity.root])
            return replace(value, identity=identity)
        assert journal.reconcile(receipt.resource_id, 2, bad, **source).code == 'observation_invalid'


def test_full_payload_rows_stream_and_receipt_lookup_is_targeted(journal, source):
    with journal.locked():
        first = prepared(journal, source)
        prepared(journal, source, 1)
        original = journal._db
        queries = []
        class StreamingCursor:
            def __init__(self, cursor):
                self.cursor = cursor
            def __iter__(self):
                return iter(self.cursor)
            def fetchall(self):
                pytest.fail('full private payload rows must stream, never fetchall')
        class StreamingConnection:
            def execute(self, query, parameters=()):
                cursor = original.execute(query, parameters)
                if query.startswith('SELECT resource_id,preparation_id'):
                    queries.append(query)
                    return StreamingCursor(cursor)
                return cursor
            def __getattr__(self, name):
                return getattr(original, name)
        journal._db = StreamingConnection()
        try:
            journal._validate()
            assert len(journal.list()) == 2
            queries.clear()
            assert journal.get(first.resource_id) == first
            assert prepared(journal, source) == first
            assert queries and all('WHERE resource_id=?' in query for query in queries)
        finally:
            journal._db = original


@pytest.mark.parametrize('name,content', [('identity.json', b'{"schemaVersion":1,"identity":"no"}'),
    ('identity.json', b'{"schemaVersion":1,"schemaVersion":1,"identity":"' + b'a' * 32 + b'"}'),
    ('identity.json', b'x' * 513), ('journal.sqlite', b'not-sqlite')])
def test_malformed_private_files_are_static_failure_without_reinitialization(tmp_path, name, content):
    directory = tmp_path / 'resources-v1'
    with ResourceJournal(directory, initialize=True):
        pass
    (directory / name).write_bytes(content)
    rejected('journal_unavailable', lambda: ResourceJournal(directory, initialize=True))
    assert (directory / name).read_bytes() == content


@pytest.mark.parametrize('damage', ['trigger', 'collation', 'partial_index', 'foreign_key', 'empty_database', 'wal'])
def test_altered_sqlite_semantics_fail_before_any_empty_history_is_adopted(tmp_path, damage):
    directory = tmp_path / 'resources-v1'
    with ResourceJournal(directory, initialize=True):
        pass
    with sqlite3.connect(directory / 'journal.sqlite') as db:
        if damage == 'trigger':
            db.execute('CREATE TRIGGER unsafe AFTER UPDATE ON resources BEGIN DELETE FROM metadata; END')
        elif damage == 'partial_index':
            db.execute('CREATE UNIQUE INDEX unsafe ON resources(resource_id) WHERE revision>1')
        elif damage == 'wal':
            db.execute('PRAGMA journal_mode=WAL')
        elif damage == 'empty_database':
            db.execute('DROP TABLE resources')
            db.execute('DROP TABLE metadata')
        else:
            sql = db.execute("SELECT sql FROM sqlite_master WHERE name='resources'").fetchone()[0]
            db.execute('DROP TABLE resources')
            if damage == 'collation':
                db.execute(sql.replace('resource_id TEXT NOT NULL', 'resource_id TEXT COLLATE NOCASE NOT NULL'))
            else:
                db.execute(sql[:-1] + ',FOREIGN KEY(preparation_id) REFERENCES metadata(identity))')
    rejected('journal_unavailable', lambda: ResourceJournal(directory, initialize=True))


def test_identity_anchor_changed_in_place_is_rejected_before_new_effect(journal, source):
    with journal.locked():
        receipt = prepared(journal, source)
        (journal.directory / 'identity.json').write_text(json.dumps({'schemaVersion': 1, 'identity': 'f' * 32}))
        rejected('journal_unavailable', lambda: journal.begin(receipt.resource_id, 1, **source))
        with sqlite3.connect(journal.directory / 'journal.sqlite') as db:
            assert db.execute('SELECT state FROM resources').fetchone() == ('prepared',)


def test_invalid_operator_directory_input_has_only_static_error():
    rejected('journal_unavailable', lambda: ResourceJournal(None, initialize=True))
