"""Real private SQLite history; synthetic label observations, no Docker effects."""
from dataclasses import asdict
import sqlite3
import threading
import pytest

from larenor_server.plugins.resource_journal import ResourceJournal, ResourceJournalError
from larenor_server.plugins.volume_journal import VolumeJournal
from larenor_server.plugins.volume_plan import build_volume_plan
from larenor_server.plugins.volume_resources import validate_volume_inspect, volume_expected_labels, volume_inspect_target
from test_volume_plan import source
from test_volume_resources import body, response


def inputs(source):
    stack, catalog, policy = source
    return dict(plan=build_volume_plan(*source), stack=stack, catalog=catalog, policy=policy)


def observe(intent):
    b = intent.binding
    return validate_volume_inspect(response(body(b)), b, request_target=volume_inspect_target(b))


def error(code, operation):
    with pytest.raises(ResourceJournalError) as caught:
        operation()
    assert str(caught.value) == caught.value.code == code


@pytest.mark.parametrize('index', range(7))
def test_each_target_is_durable_without_an_execution_grant(tmp_path, source, index):
    data = inputs(source)
    resource = data['plan'].resources[index]
    path = tmp_path / 'volume-v1'
    with VolumeJournal(path, initialize=True) as j:
        identity = j.identity
        with j.locked():
            p = j.prepare(**data, resource_id=resource.resourceId)
            assert (p.state, p.revision, p.code) == ('prepared', 1, 'volume_prepared')
            assert p.operation_id == resource.operationId
            intent = j.begin_observation(resource.resourceId, 1, **data)
            assert (intent.receipt.state, intent.receipt.revision) == ('observing', 2)
            assert intent.binding.journal_id == identity
            nonce = intent.binding.ownership_nonce
            assert len(nonce) == 32 and nonce != identity
            seen = j.reconcile(resource.resourceId, 2, observe, **data)
            assert (seen.state, seen.revision, seen.code) == ('labels_observed', 3, 'volume_labels_observed')
            assert not {'ready', 'created', 'lease', 'writeable', 'ownership_nonce', 'name'} & set(asdict(seen))
            assert j.prepare(**data, resource_id=resource.resourceId) == seen
            error('invalid_transition', lambda: j.begin_observation(resource.resourceId, 3, **data))
    with VolumeJournal(path) as j:
        assert j.identity == identity
        with j.locked():
            assert j.get(resource.resourceId) == seen and j.list() == (seen,)
            binding = j.bind(resource.resourceId, 3, **data).binding
            assert binding.ownership_nonce == nonce
            assert volume_expected_labels(binding)['org.larenor.volume-journal'] == identity
    assert b'DO-NOT-EXPOSE' not in (path / 'journal.sqlite').read_bytes()


def test_empty_native_and_volume_domains_are_not_interpreted_as_each_other(tmp_path):
    for first, second, name in [(ResourceJournal, VolumeJournal, 'native'), (VolumeJournal, ResourceJournal, 'volume')]:
        path = tmp_path / name
        with first(path, initialize=True):
            pass
        before = {p.name: p.read_bytes() for p in path.iterdir()}
        error('journal_unavailable', lambda: second(path, initialize=True))
        assert {p.name: p.read_bytes() for p in path.iterdir()} == before


def test_lock_required_and_native_effect_entry_is_disabled(tmp_path, source):
    data = inputs(source)
    rid = data['plan'].resources[0].resourceId
    with VolumeJournal(tmp_path / 'volumes', initialize=True) as j:
        error('lock_required', lambda: j.prepare(**data, resource_id=rid))
        with j.locked():
            p = j.prepare(**data, resource_id=rid)
            error('volume_effects_disabled', lambda: j.begin(rid, 1, **data))
            error('worker_busy', j.close)
            assert j.get(rid) == p
        error('lock_required', lambda: j.bind(rid, 1, **data))


def test_interrupted_observation_only_reconciles_after_restart(tmp_path, source):
    data = inputs(source)
    rid = data['plan'].resources[0].resourceId
    path = tmp_path / 'volumes'
    with VolumeJournal(path, initialize=True) as j:
        with j.locked():
            j.prepare(**data, resource_id=rid)
            started = j.begin_observation(rid, 1, **data)
    with VolumeJournal(path) as j:
        with j.locked():
            assert j.get(rid) == started.receipt
            error('reconciliation_required', lambda: j.begin_observation(rid, 2, **data))
            unknown = j.mark_uncertain(rid, 2)
            assert (unknown.state, unknown.revision) == ('uncertain', 3)
            error('revision_conflict', lambda: j.reconcile(rid, 2, observe, **data))
            result = j.reconcile(rid, 3, observe, **data)
            assert (result.state, result.revision) == ('labels_observed', 4)


def test_other_journal_observation_is_not_adopted(tmp_path, source):
    data = inputs(source)
    rid = data['plan'].resources[0].resourceId
    with VolumeJournal(tmp_path / 'a', initialize=True) as a, VolumeJournal(tmp_path / 'b', initialize=True) as b:
        with a.locked(), b.locked():
            a.prepare(**data, resource_id=rid)
            b.prepare(**data, resource_id=rid)
            ai = a.begin_observation(rid, 1, **data)
            bi = b.begin_observation(rid, 1, **data)
            assert ai.binding.ownership_nonce != bi.binding.ownership_nonce
            foreign = observe(ai)
            result = b.reconcile(rid, 2, lambda _: foreign, **data)
            assert (result.state, result.code) == ('needs_attention', 'volume_observation_invalid')


def test_changed_policy_cannot_rebind_existing_receipt(tmp_path, source):
    data = inputs(source)
    rid = data['plan'].resources[0].resourceId
    with VolumeJournal(tmp_path / 'volumes', initialize=True) as j:
        with j.locked():
            p = j.prepare(**data, resource_id=rid)
            changed = dict(data)
            changed['policy'] = changed['policy'].model_copy(update={'workerPolicyDigest': 'e' * 64})
            changed['plan'] = build_volume_plan(changed['stack'], changed['catalog'], changed['policy'])
            error('idempotency_conflict', lambda: j.prepare(**changed, resource_id=rid))
            error('idempotency_conflict', lambda: j.begin_observation(rid, 1, **changed))
            assert j.get(rid) == p


def test_observer_cancel_and_reentrant_revision_cannot_publish_old_success(tmp_path, source):
    data = inputs(source)
    rid = data['plan'].resources[0].resourceId
    event = threading.Event()
    with VolumeJournal(tmp_path / 'volumes', initialize=True) as j:
        with j.locked():
            j.prepare(**data, resource_id=rid)
            j.begin_observation(rid, 1, **data)
            def reenter(intent):
                j.mark_uncertain(rid, 2)
                return observe(intent)
            error('revision_conflict', lambda: j.reconcile(rid, 2, reenter, **data))
            assert j.get(rid).revision == 3
            def cancel(intent):
                event.set()
                return observe(intent)
            result = j.reconcile(rid, 3, cancel, cancelled=event, **data)
            assert (result.state, result.code, result.revision) == ('uncertain', 'volume_observation_unavailable', 4)


def test_corrupt_row_fails_static_without_reset(tmp_path, source):
    data = inputs(source)
    rid = data['plan'].resources[0].resourceId
    path = tmp_path / 'volumes'
    with VolumeJournal(path, initialize=True) as j:
        with j.locked():
            j.prepare(**data, resource_id=rid)
    with sqlite3.connect(path / 'journal.sqlite') as db:
        db.execute('UPDATE resources SET payload=?', ('synthetic-private-broken',))
    before = (path / 'journal.sqlite').read_bytes()
    error('journal_unavailable', lambda: VolumeJournal(path, initialize=True))
    assert (path / 'journal.sqlite').read_bytes() == before


def test_native_public_methods_and_effect_bridges_cannot_issuance_native_receipts(tmp_path, source):
    from larenor_server.plugins.resource_plan import build_resource_plan
    from larenor_server.plugins.network_preparation import JournaledNetworkOperations, NetworkPreparationError
    from larenor_server.plugins.image_preparation import JournaledImageOperations, ImagePreparationError
    data = inputs(source)
    rid = data['plan'].resources[0].resourceId
    native = build_resource_plan(*source)
    with VolumeJournal(tmp_path / 'volumes', initialize=True) as j:
        with j.locked():
            original = j.prepare(**data, resource_id=rid)
            for action in (
                lambda: ResourceJournal.prepare(j, native, *source, native.resources[0].resourceId),
                lambda: ResourceJournal.begin(j, rid, 1, **data),
                lambda: ResourceJournal.mark_uncertain(j, rid, 1),
                lambda: j.prepare(native, *source, native.resources[0].resourceId),
            ):
                with pytest.raises(ResourceJournalError):
                    action()
                assert j.get(rid) == original and j.list() == (original,)
            j.begin_observation(rid, 1, **data)
            j.mark_uncertain(rid, 2)
            original = j.get(rid)
            with pytest.raises(ResourceJournalError):
                ResourceJournal.reconcile(j, rid, 3, observe, **data)
            assert j.get(rid) == original
        with pytest.raises(NetworkPreparationError):
            JournaledNetworkOperations(j, object(), object())
        with pytest.raises(ImagePreparationError):
            JournaledImageOperations(j, object())


@pytest.mark.parametrize('revision', [True, False, 1.0, '1', 0, -1, 2**63 - 1])
def test_expected_revision_is_strict_and_does_not_advance_on_rejection(tmp_path, source, revision):
    data = inputs(source)
    rid = data['plan'].resources[0].resourceId
    with VolumeJournal(tmp_path / 'volumes', initialize=True) as j:
        with j.locked():
            original = j.prepare(**data, resource_id=rid)
            error('revision_conflict', lambda: j.begin_observation(rid, revision, **data))
            error('revision_conflict', lambda: j.bind(rid, revision, **data))
            assert j.get(rid) == original


@pytest.mark.parametrize('field,value', [
    ('resource_id', 'e' * 32), ('name', 'foreign'), ('plan_hash', 'e' * 64),
    ('labels_digest', 'e' * 64), ('state', 'ready'), ('extra', 'synthetic-private'),
])
def test_forged_typed_observation_does_not_adopt_volume(tmp_path, source, field, value):
    data = inputs(source)
    rid = data['plan'].resources[0].resourceId
    with VolumeJournal(tmp_path / 'volumes', initialize=True) as j:
        with j.locked():
            j.prepare(**data, resource_id=rid)
            j.begin_observation(rid, 1, **data)
            def invalid(intent):
                result = observe(intent)
                object.__setattr__(result, field, value)
                return result
            result = j.reconcile(rid, 2, invalid, **data)
            assert (result.state, result.code) == ('needs_attention', 'volume_observation_invalid')
            assert 'synthetic-private' not in repr(result)


@pytest.mark.parametrize('scenario', ['foreign_labels', 'created_ack', 'missing', 'raw_exception', 'dict', 'none'])
def test_unproven_or_unavailable_volume_never_becomes_ready(tmp_path, source, scenario):
    data = inputs(source)
    rid = data['plan'].resources[0].resourceId
    with VolumeJournal(tmp_path / 'volumes', initialize=True) as j:
        with j.locked():
            j.prepare(**data, resource_id=rid)
            j.begin_observation(rid, 1, **data)
            def read(intent):
                binding = intent.binding
                value = body(binding)
                if scenario == 'foreign_labels':
                    value['Labels']['org.larenor.ownership-nonce'] = 'e' * 32
                if scenario == 'raw_exception':
                    raise RuntimeError('synthetic-private-host/error')
                if scenario == 'dict':
                    return asdict(observe(intent))
                if scenario == 'none':
                    return None
                status = {'created_ack': 201, 'missing': 404}.get(scenario, 200)
                return validate_volume_inspect(response(value, status=status), binding,
                    request_target=volume_inspect_target(binding))
            result = j.reconcile(rid, 2, read, **data)
            expected = ('needs_attention', 'volume_conflict') if scenario == 'foreign_labels' else (
                ('needs_attention', 'volume_observation_invalid') if scenario in {'dict', 'none'} else
                ('uncertain', 'volume_observation_unavailable'))
            assert (result.state, result.code) == expected
            assert 'synthetic-private' not in repr(result)


def test_cancel_before_callback_performs_no_observation_and_leaves_revision(tmp_path, source):
    data = inputs(source)
    rid = data['plan'].resources[0].resourceId
    cancelled = threading.Event()
    cancelled.set()
    with VolumeJournal(tmp_path / 'volumes', initialize=True) as j:
        with j.locked():
            j.prepare(**data, resource_id=rid)
            started = j.begin_observation(rid, 1, **data)
            def forbidden(_):
                pytest.fail('cancelled observer executed')
            error('volume_cancelled', lambda: j.reconcile(rid, 2, forbidden, cancelled=cancelled, **data))
            error('invalid_binding', lambda: j.reconcile(rid, 2, forbidden, cancelled=True, **data))
            error('invalid_binding', lambda: j.reconcile(rid, 2, None, **data))
            assert j.get(rid) == started.receipt


def test_alias_change_during_observer_cannot_publish_old_success(tmp_path, source):
    data = inputs(source)
    rid = data['plan'].resources[0].resourceId
    with VolumeJournal(tmp_path / 'volumes', initialize=True) as j:
        with j.locked():
            j.prepare(**data, resource_id=rid)
            original = j.begin_observation(rid, 1, **data).receipt
            def change(intent):
                value = observe(intent)
                object.__setattr__(data['policy'], 'workerPolicyDigest', 'e' * 64)
                return value
            error('invalid_volume_binding', lambda: j.reconcile(rid, 2, change, **data))
            assert j.get(rid) == original


def test_saved_source_is_detached_from_caller_aliases(tmp_path, source):
    data = inputs(source)
    rid = data['plan'].resources[0].resourceId
    with VolumeJournal(tmp_path / 'volumes', initialize=True) as j:
        with j.locked():
            original = j.prepare(**data, resource_id=rid)
            old = j.bind(rid, 1, **data)
            object.__setattr__(old.binding.source[0], 'planHash', 'e' * 64)
            fresh = j.bind(rid, 1, **data)
            assert fresh.receipt == original
            assert fresh.binding.source[0].planHash == data['plan'].planHash


@pytest.mark.parametrize('field', ['core', 'home', 'preparation'])
def test_wrong_authoritative_context_is_rejected_before_observer(tmp_path, source, field):
    from larenor_server.context import ContextResponse
    from larenor_server.plugins.stack_plan import build_media_stack_plan
    data = inputs(source)
    rid = data['plan'].resources[0].resourceId
    context = ContextResponse(schemaVersion=1,
        coreId='e' * 32 if field == 'core' else data['stack'].coreId,
        homeId='e' * 32 if field == 'home' else data['stack'].homeId)
    changed = dict(data)
    changed['stack'] = build_media_stack_plan(data['catalog'], {}, data['stack'].platform,
        context, 'e' * 32 if field == 'preparation' else data['stack'].preparationId)
    changed['plan'] = build_volume_plan(changed['stack'], changed['catalog'], changed['policy'])
    with VolumeJournal(tmp_path / 'volumes', initialize=True) as j:
        with j.locked():
            j.prepare(**data, resource_id=rid)
            original = j.begin_observation(rid, 1, **data).receipt
            def forbidden(_):
                pytest.fail('wrong context observer executed')
            error('invalid_volume_binding', lambda: j.reconcile(rid, 2, forbidden, **changed))
            assert j.get(rid) == original


@pytest.mark.parametrize('name', ['identity.json', 'journal.sqlite', 'journal.lock'])
def test_missing_files_fail_without_reinitialization(tmp_path, name):
    path = tmp_path / 'volumes'
    with VolumeJournal(path, initialize=True):
        pass
    (path / name).unlink()
    error('journal_unavailable', lambda: VolumeJournal(path, initialize=True))
    assert not (path / name).exists()


def test_empty_existing_directory_is_not_adopted(tmp_path):
    path = tmp_path / 'volumes'
    path.mkdir(mode=0o700)
    error('journal_unavailable', lambda: VolumeJournal(path, initialize=True))
    assert list(path.iterdir()) == []


def test_volume_lock_rejects_reentry_other_thread_and_other_connection(tmp_path):
    from concurrent.futures import ThreadPoolExecutor
    path = tmp_path / 'volumes'
    with VolumeJournal(path, initialize=True) as first, VolumeJournal(path) as second:
        def acquire(journal):
            with journal.locked():
                pytest.fail('overlapping lock acquired')
        with first.locked():
            error('worker_busy', lambda: acquire(first))
            error('worker_busy', lambda: acquire(second))
            with ThreadPoolExecutor(max_workers=1) as pool:
                pool.submit(lambda: error('lock_required', first.list)).result()
        with second.locked():
            assert second.list() == ()


@pytest.mark.parametrize('target', ['directory', 'identity.json', 'journal.sqlite', 'journal.lock'])
def test_open_path_replacement_retires_volume_history(tmp_path, target):
    path = tmp_path / 'volumes'
    with VolumeJournal(path, initialize=True) as j:
        chosen = path if target == 'directory' else path / target
        chosen.rename(chosen.with_name(chosen.name + '.old'))
        if target == 'directory':
            chosen.mkdir(mode=0o700)
        else:
            chosen.write_bytes(b'synthetic-foreign')
            chosen.chmod(0o600)
        def read():
            with j.locked():
                j.list()
        error('unsafe_worker_path', read)


def test_volume_metadata_count_limit_is_enforced_before_another_record(tmp_path, source, monkeypatch):
    import larenor_server.plugins.volume_journal as module
    data = inputs(source)
    monkeypatch.setattr(module, 'MAX_VOLUMES', 1)
    with VolumeJournal(tmp_path / 'volumes', initialize=True) as j:
        with j.locked():
            first = j.prepare(**data, resource_id=data['plan'].resources[0].resourceId)
            error('journal_capacity', lambda: j.prepare(**data, resource_id=data['plan'].resources[1].resourceId))
            assert j.list() == (first,)


def test_journal_and_pure_observer_have_no_transport_or_host_effects(tmp_path, source, monkeypatch):
    import os
    import socket
    import subprocess
    data = inputs(source)
    rid = data['plan'].resources[0].resourceId
    def forbidden(*args, **kwargs):
        pytest.fail('journal attempted transport or host ownership mutation')
    for owner, name in [(socket, 'socket'), (subprocess, 'Popen'), (os, 'chown')]:
        monkeypatch.setattr(owner, name, forbidden)
    with VolumeJournal(tmp_path / 'volumes', initialize=True) as j:
        assert str(tmp_path) not in repr(j)
        with j.locked():
            j.prepare(**data, resource_id=rid)
            j.begin_observation(rid, 1, **data)
            result = j.reconcile(rid, 2, observe, **data)
            assert result.state == 'labels_observed'


def test_mutated_observer_intent_is_rejected_by_fresh_row_decoder(tmp_path, source):
    from larenor_server.plugins.volume_resources import volume_binding
    data = inputs(source)
    rid = data['plan'].resources[0].resourceId
    with VolumeJournal(tmp_path / 'volumes', initialize=True) as j:
        with j.locked():
            j.prepare(**data, resource_id=rid)
            original = j.begin_observation(rid, 1, **data).receipt
            def change(intent):
                foreign = volume_binding(data['plan'], data['stack'], data['catalog'], data['policy'], rid,
                    journal_id=j.identity, ownership_nonce='f' * 32)
                object.__setattr__(intent, 'binding', foreign)
                return observe(intent)
            error('journal_unavailable', lambda: j.reconcile(rid, 2, change, **data))
            assert j.get(rid) == original
            assert j.reconcile(rid, 2, observe, **data).state == 'labels_observed'


def test_full_snapshot_limit_is_checked_before_storing_any_partial_record(tmp_path, source, monkeypatch):
    import larenor_server.plugins.volume_journal as module
    data = inputs(source)
    with VolumeJournal(tmp_path / 'volumes', initialize=True) as j:
        with j.locked():
            monkeypatch.setattr(module, 'MAX_PAYLOAD_BYTES', 100)
            error('invalid_volume_binding', lambda: j.prepare(**data, resource_id=data['plan'].resources[0].resourceId))
            assert j.list() == ()


def test_native_typed_observer_and_malformed_method_inputs_never_leak_attributes(tmp_path, source):
    from larenor_server.plugins.resource_journal import ResourceObservation, ImageIdentity
    data = inputs(source)
    rid = data['plan'].resources[0].resourceId
    with VolumeJournal(tmp_path / 'volumes', initialize=True) as j:
        with j.locked():
            j.prepare(**data, resource_id=rid)
            intent = j.begin_observation(rid, 1, **data)
            j.mark_uncertain(rid, 2)
            original = j.get(rid)
            native = ResourceObservation('matched', rid, j.identity, intent.binding.ownership_nonce,
                intent.specification_digest, ImageIdentity('sha256:' + 'f' * 64))
            error('journal_unavailable', lambda: ResourceJournal.reconcile(j, rid, 3, lambda _: native, **data))
            assert j.get(rid) == original
            malformed = dict(data, plan=object())
            error('invalid_volume_binding', lambda: ResourceJournal.prepare(j, **malformed, resource_id=rid))
            error('invalid_binding', lambda: ResourceJournal.get(j, object()))
            assert j.list() == (original,)
