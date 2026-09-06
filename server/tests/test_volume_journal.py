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
