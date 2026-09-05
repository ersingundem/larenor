"""Private durable network composition; only temporary journals and fake engines."""

from collections import deque
import json
import os
import socket
import sqlite3
import threading

import pytest

from larenor_server.plugins.network_effects import NetworkCreateAcknowledgement, NetworkCreateError
from larenor_server.plugins.network_resources import NetworkListObservation, NetworkResourceError
from larenor_server.plugins.resource_journal import NetworkIdentity, ResourceJournal, ResourceJournalError

from test_image_preparation import source, journal


NETWORK_ID = '1' * 64


def resource_id(source):
    return source['plan'].resources[-1].resourceId


def current(journal, source):
    with journal.locked():
        return journal.get(resource_id(source))


class Reader:
    def __init__(self, observations=(), *, on_read=None):
        self.observations = deque(observations)
        self.calls = []
        self.on_read = on_read

    def _read(self, method, binding, intent, cancelled, expected_id=None):
        self.calls.append((method, expected_id))
        if self.on_read:
            self.on_read(method, binding, intent, cancelled)
        value = self.observations.popleft()
        if isinstance(value, BaseException):
            raise value
        return value

    def list(self, binding, intent, *, cancelled):
        return self._read('list', binding, intent, cancelled)

    def inspect(self, binding, intent, network_id, *, cancelled):
        return self._read('inspect', binding, intent, cancelled, network_id)


class Creator:
    def __init__(self, *, on_version=None, on_create=None):
        self.calls = []
        self.on_version, self.on_create = on_version, on_create

    def create(self, binding, intent, *, before_dispatch, cancelled):
        self.calls.append('version')
        if self.on_version:
            self.on_version(binding, intent, cancelled)
        if before_dispatch() is not True:
            raise NetworkCreateError('network_create_not_authorized')
        self.calls.append('create')
        if self.on_create:
            return self.on_create(binding, intent, cancelled)
        return NetworkCreateAcknowledgement(NETWORK_ID)


def apply(journal, reader, creator, source, **options):
    from larenor_server.plugins.network_preparation import JournaledNetworkOperations
    return JournaledNetworkOperations(journal, reader, creator).apply(
        **source, resource_id=resource_id(source), **options)


def success_reader(**options):
    return Reader([NetworkListObservation('missing'), NetworkListObservation('candidate', NETWORK_ID),
                   NetworkIdentity(NETWORK_ID)], **options)


def test_fresh_create_has_durable_begin_before_list_and_ack_requires_fresh_list_inspect(journal, source):
    order = []
    def authorize():
        order.append('authorize:' + journal.get(resource_id(source)).state)
        return True
    def read(method, binding, intent, cancelled):
        assert journal.get(resource_id(source)) == intent.receipt
        with sqlite3.connect(journal.directory / 'journal.sqlite') as db:
            assert db.execute('SELECT state,revision FROM resources').fetchone() == ('mutating', 2)
            db.execute('BEGIN IMMEDIATE')
            db.rollback()
        with pytest.raises(ResourceJournalError, match='^worker_busy$'):
            ResourceJournal(journal.directory)
        order.append(method)
    reader = success_reader(on_read=read)
    creator = Creator(on_create=lambda *_: order.append('create') or NetworkCreateAcknowledgement(NETWORK_ID))
    receipt = apply(journal, reader, creator, source, authorize_create=authorize)
    assert order == ['authorize:prepared', 'list', 'authorize:mutating', 'create', 'list', 'inspect']
    assert (receipt.state, receipt.code, receipt.revision) == ('ready', 'resource_matched', 3)
    assert reader.calls == [('list', None), ('list', None), ('inspect', NETWORK_ID)]
    assert creator.calls == ['version', 'create'] and current(journal, source) == receipt


def test_absent_authority_keeps_prepared_without_even_reading_network(journal, source):
    from larenor_server.plugins.network_preparation import NetworkPreparationError
    reader, creator = Reader(), Creator()
    with pytest.raises(NetworkPreparationError, match='^network_create_not_authorized$'):
        apply(journal, reader, creator, source)
    assert current(journal, source).state == 'prepared' and reader.calls == creator.calls == []


@pytest.mark.parametrize('state', ['mutating', 'uncertain'])
def test_restart_missing_never_creates_even_if_authorized(journal, source, state):
    with journal.locked():
        journal.prepare(**source, resource_id=resource_id(source))
        journal.begin(resource_id(source), 1, **source)
        if state == 'uncertain':
            journal.mark_uncertain(resource_id(source), 2)
    reader, creator = Reader([NetworkListObservation('missing')]), Creator()
    with ResourceJournal(journal.directory) as restarted:
        receipt = apply(restarted, reader, creator, source,
                        authorize_create=lambda: pytest.fail('replay must not request mutation authority'))
    assert (receipt.state, receipt.code) == ('needs_attention', 'resource_missing')
    assert reader.calls == [('list', None)] and creator.calls == []


def test_lost_create_response_stays_uncertain_and_restart_only_observes(journal, source):
    def interrupted(*_):
        raise NetworkCreateError('network_create_timeout')
    reader = Reader([NetworkListObservation('missing')])
    creator = Creator(on_create=interrupted)
    receipt = apply(journal, reader, creator, source, authorize_create=lambda: True)
    assert (receipt.state, receipt.code, receipt.revision) == ('uncertain', 'effect_uncertain', 3)
    with ResourceJournal(journal.directory) as restarted:
        reader = Reader([NetworkListObservation('candidate', NETWORK_ID), NetworkIdentity(NETWORK_ID)])
        unused = Creator()
        receipt = apply(restarted, reader, unused, source)
    assert receipt.state == 'ready' and receipt.revision == 4 and unused.calls == []


def test_different_final_id_cannot_adopt_a_network_after_created_ack(journal, source):
    reader = Reader([NetworkListObservation('missing'), NetworkListObservation('candidate', '2' * 64)])
    creator = Creator()
    receipt = apply(journal, reader, creator, source, authorize_create=lambda: True)
    assert (receipt.state, receipt.code) == ('needs_attention', 'resource_conflict')
    assert reader.calls == [('list', None), ('list', None)]


def test_candidate_is_relisted_with_fresh_intent_before_final_inspect(journal, source):
    reader = Reader([NetworkListObservation('candidate', NETWORK_ID),
                     NetworkListObservation('candidate', NETWORK_ID), NetworkIdentity(NETWORK_ID)])
    creator = Creator()
    receipt = apply(journal, reader, creator, source, authorize_create=lambda: True)
    assert receipt.state == 'ready' and creator.calls == []
    assert reader.calls == [('list', None), ('list', None), ('inspect', NETWORK_ID)]


def test_cancellation_immediately_after_durable_begin_becomes_uncertain(journal, source, monkeypatch):
    event = threading.Event()
    begin = journal.begin
    def committed(*args, **kwargs):
        intent = begin(*args, **kwargs)
        event.set()
        return intent
    monkeypatch.setattr(journal, 'begin', committed)
    reader, creator = Reader(), Creator()
    receipt = apply(journal, reader, creator, source, authorize_create=lambda: True, cancelled=event)
    assert (receipt.state, receipt.code, receipt.revision) == ('uncertain', 'effect_uncertain', 3)
    assert reader.calls == creator.calls == []


def test_binding_change_during_first_body_derivation_after_begin_becomes_uncertain(journal, source, monkeypatch):
    from larenor_server.plugins import network_preparation
    original = network_preparation.build_network_create_body
    def changed(binding, intent):
        object.__setattr__(intent, 'specification_digest', 'f' * 64)
        return original(binding, intent)
    monkeypatch.setattr(network_preparation, 'build_network_create_body', changed)
    reader, creator = Reader(), Creator()
    receipt = apply(journal, reader, creator, source, authorize_create=lambda: True)
    assert (receipt.state, receipt.code, receipt.revision) == ('uncertain', 'effect_uncertain', 3)
    assert reader.calls == creator.calls == []


@pytest.mark.parametrize('field,value', [('revision', 99), ('resource_id', 'f' * 32), ('state', 'ready')])
def test_callback_cannot_mutate_the_bridge_expected_receipt_via_intent_alias(journal, source, field, value):
    def change_receipt(_method, _binding, intent, _event):
        object.__setattr__(intent.receipt, field, value)
    reader = Reader([NetworkListObservation('missing')], on_read=change_receipt)
    creator = Creator()
    receipt = apply(journal, reader, creator, source, authorize_create=lambda: True)
    assert (receipt.state, receipt.code, receipt.revision) == ('uncertain', 'effect_uncertain', 3)
    assert creator.calls == []


@pytest.mark.parametrize('authority', [lambda: False, lambda: 1, lambda: 'true', lambda: None])
def test_nonliteral_authority_before_begin_leaves_prepared_without_io(journal, source, authority):
    from larenor_server.plugins.network_preparation import NetworkPreparationError
    reader, creator = Reader(), Creator()
    with pytest.raises(NetworkPreparationError, match='^network_create_not_authorized$'):
        apply(journal, reader, creator, source, authorize_create=authority)
    assert current(journal, source).state == 'prepared' and reader.calls == creator.calls == []


@pytest.mark.parametrize('options', [{'authorize_create': True}, {'cancelled': True}, {'cancelled': object()}])
def test_invalid_call_options_fail_before_journal_or_engine_io(journal, source, options):
    from larenor_server.plugins.network_preparation import NetworkPreparationError
    reader, creator = Reader(), Creator()
    with pytest.raises(NetworkPreparationError, match='^invalid_network_preparation$'):
        apply(journal, reader, creator, source, **options)
    with journal.locked():
        assert journal.list() == ()
    assert reader.calls == creator.calls == []


def test_authority_exception_is_static_and_not_stored(journal, source):
    from larenor_server.plugins.network_preparation import NetworkPreparationError
    def fail():
        raise RuntimeError('secret-token /operator/path')
    with pytest.raises(NetworkPreparationError, match='^network_create_not_authorized$'):
        apply(journal, Reader(), Creator(), source, authorize_create=fail)
    assert b'secret-token' not in (journal.directory / 'journal.sqlite').read_bytes()


@pytest.mark.parametrize('state', ['ready', 'needs_attention'])
def test_terminal_receipt_replay_returns_history_without_authority_or_io(journal, source, state):
    reader = success_reader() if state == 'ready' else Reader([NetworkResourceError('network_conflict')])
    receipt = apply(journal, reader, Creator(), source, authorize_create=lambda: True)
    assert receipt.state == state
    reader, creator = Reader(), Creator()
    with ResourceJournal(journal.directory) as reopened:
        assert apply(reopened, reader, creator, source) == receipt
    assert reader.calls == creator.calls == []


@pytest.mark.parametrize('where', ['first_list', 'final_list', 'inspect'])
@pytest.mark.parametrize('error,expected', [
    (NetworkResourceError('network_conflict'), ('needs_attention', 'resource_conflict')),
    (NetworkResourceError('network_multiple'), ('needs_attention', 'resource_multiple')),
    (NetworkResourceError('network_protocol'), ('uncertain', 'observation_unavailable')),
    (RuntimeError('private daemon detail'), ('uncertain', 'observation_unavailable')),
])
def test_observation_failure_classification_never_recreates_or_persists_details(journal, source, where, error, expected):
    values = [NetworkListObservation('missing'), NetworkListObservation('candidate', NETWORK_ID), NetworkIdentity(NETWORK_ID)]
    values[{'first_list': 0, 'final_list': 1, 'inspect': 2}[where]] = error
    reader, creator = Reader(values), Creator()
    receipt = apply(journal, reader, creator, source, authorize_create=lambda: True)
    assert (receipt.state, receipt.code) == expected
    assert creator.calls == ([] if where == 'first_list' else ['version', 'create'])
    assert b'private daemon detail' not in (journal.directory / 'journal.sqlite').read_bytes()


@pytest.mark.parametrize('value', [None, object(), NetworkListObservation('matched', NETWORK_ID),
    NetworkListObservation('missing', NETWORK_ID), NetworkListObservation('candidate', None),
    NetworkListObservation('candidate', True), NetworkListObservation('candidate', '1' * 12)])
def test_malformed_readonly_list_result_cannot_establish_absence(journal, source, value):
    reader, creator = Reader([value]), Creator()
    receipt = apply(journal, reader, creator, source, authorize_create=lambda: True)
    assert (receipt.state, receipt.code) == ('uncertain', 'observation_unavailable')
    assert creator.calls == []


@pytest.mark.parametrize('value,expected', [(None, 'observation_unavailable'), (object(), 'observation_unavailable'),
    (NetworkIdentity(True), 'observation_unavailable'), (NetworkIdentity('2' * 64), 'resource_conflict')])
def test_full_id_inspect_requires_exact_typed_matching_identity(journal, source, value, expected):
    reader = Reader([NetworkListObservation('missing'), NetworkListObservation('candidate', NETWORK_ID), value])
    receipt = apply(journal, reader, Creator(), source, authorize_create=lambda: True)
    assert receipt.code == expected and receipt.state != 'ready'


@pytest.mark.parametrize('which', ['list', 'inspect', 'ack'])
def test_hidden_extra_fields_in_private_adapter_return_are_rejected(journal, source, which):
    value = {'list': NetworkListObservation('missing'), 'inspect': NetworkIdentity(NETWORK_ID),
             'ack': NetworkCreateAcknowledgement(NETWORK_ID)}[which]
    object.__setattr__(value, 'extra', 'private-value')
    reader = success_reader()
    if which == 'list':
        reader.observations[0] = value
    elif which == 'inspect':
        reader.observations[2] = value
    creator = Creator(on_create=(lambda *_: value) if which == 'ack' else None)
    receipt = apply(journal, reader, creator, source, authorize_create=lambda: True)
    assert receipt.state == 'uncertain'
    assert b'private-value' not in (journal.directory / 'journal.sqlite').read_bytes()


def test_initial_candidate_replaced_before_fresh_relist_is_not_adopted(journal, source):
    reader = Reader([NetworkListObservation('candidate', NETWORK_ID),
                     NetworkListObservation('candidate', '2' * 64)])
    creator = Creator()
    receipt = apply(journal, reader, creator, source, authorize_create=lambda: True)
    assert (receipt.state, receipt.code) == ('needs_attention', 'resource_conflict')
    assert reader.calls == [('list', None), ('list', None)] and creator.calls == []


def test_ack_followed_by_missing_is_uncertain_and_never_retryable_create(journal, source):
    reader = Reader([NetworkListObservation('missing'), NetworkListObservation('missing')])
    receipt = apply(journal, reader, Creator(), source, authorize_create=lambda: True)
    assert (receipt.state, receipt.code) == ('uncertain', 'observation_unavailable')
    creator = Creator()
    with ResourceJournal(journal.directory) as reopened:
        second = apply(reopened, Reader([NetworkListObservation('missing')]), creator, source,
                       authorize_create=lambda: pytest.fail('no replay grant'))
    assert second.code == 'resource_missing' and creator.calls == []


@pytest.mark.parametrize('point', ['before', 'first_authority', 'list', 'version', 'second_authority', 'create', 'inspect'])
def test_cancellation_discards_result_without_second_create(journal, source, point):
    from larenor_server.plugins.network_preparation import NetworkPreparationError
    event = threading.Event()
    if point == 'before':
        event.set()
    count = 0
    def authorize():
        nonlocal count
        count += 1
        if point == ('first_authority' if count == 1 else 'second_authority'):
            event.set()
        return True
    def read(method, *_):
        if point == method:
            event.set()
    def version(*_):
        if point == 'version':
            event.set()
    def create(*_):
        if point == 'create':
            event.set()
        return NetworkCreateAcknowledgement(NETWORK_ID)
    reader = success_reader(on_read=read)
    creator = Creator(on_version=version, on_create=create)
    if point in {'before', 'first_authority'}:
        with pytest.raises(NetworkPreparationError, match='^network_cancelled$'):
            apply(journal, reader, creator, source, authorize_create=authorize, cancelled=event)
        with journal.locked():
            assert len(journal.list()) == (0 if point == 'before' else 1)
    else:
        receipt = apply(journal, reader, creator, source, authorize_create=authorize, cancelled=event)
        assert receipt.state == 'uncertain'
    assert creator.calls.count('create') == (1 if point in {'create', 'inspect'} else 0)


@pytest.mark.parametrize('point', ['list', 'version', 'second_authority', 'create', 'inspect'])
@pytest.mark.parametrize('field', ['plan', 'policy'])
def test_original_apply_source_is_rederived_after_callbacks(journal, source, point, field):
    def mutate():
        object.__setattr__(source[field], 'workerPolicyVersion', True)
    count = 0
    def authorize():
        nonlocal count
        count += 1
        if count == 2 and point == 'second_authority':
            mutate()
        return True
    def read(method, *_):
        if method == point:
            mutate()
    def version(*_):
        if point == 'version':
            mutate()
    def create(*_):
        if point == 'create':
            mutate()
        return NetworkCreateAcknowledgement(NETWORK_ID)
    reader = success_reader(on_read=read)
    creator = Creator(on_version=version, on_create=create)
    receipt = apply(journal, reader, creator, source, authorize_create=authorize)
    assert receipt.state == 'uncertain'
    assert creator.calls.count('create') == (1 if point in {'create', 'inspect'} else 0)


@pytest.mark.parametrize('point', ['first_authority', 'second_authority', 'list', 'version', 'inspect'])
def test_reentrant_journal_write_preserves_newer_receipt(journal, source, point):
    latest = []
    def change():
        before = journal.get(resource_id(source))
        if before.state == 'prepared':
            latest.append(journal.begin(resource_id(source), before.revision, **source).receipt)
        else:
            latest.append(journal.mark_uncertain(resource_id(source), before.revision))
    count = 0
    def authorize():
        nonlocal count
        count += 1
        if point == ('first_authority' if count == 1 else 'second_authority'):
            change()
        return True
    def read(method, *_):
        if method == point:
            change()
    def version(*_):
        if point == 'version':
            change()
    reader = success_reader(on_read=read)
    creator = Creator(on_version=version)
    receipt = apply(journal, reader, creator, source, authorize_create=authorize)
    assert receipt == latest[-1] == current(journal, source)
    assert creator.calls.count('create') == (1 if point == 'inspect' else 0)


@pytest.mark.parametrize('answer', [False, 1, None, 'true', RuntimeError('private grant error')])
def test_revocation_at_post_version_gate_keeps_uncertain_without_post(journal, source, answer):
    count = 0
    def authorize():
        nonlocal count
        count += 1
        if count == 1:
            return True
        if isinstance(answer, Exception):
            raise answer
        return answer
    reader, creator = Reader([NetworkListObservation('missing')]), Creator()
    receipt = apply(journal, reader, creator, source, authorize_create=authorize)
    assert receipt.state == 'uncertain' and creator.calls == ['version']


@pytest.mark.parametrize('point', ['first_list', 'post_bytes', 'after_ack', 'inspect', 'ready_write'])
def test_process_interruption_recovers_with_reads_only(journal, source, point, monkeypatch):
    def read(method, *_):
        if (point == 'first_list' and method == 'list') or (point == 'inspect' and method == 'inspect'):
            raise SystemExit()
    def create(*_):
        if point == 'post_bytes':
            raise SystemExit()
        return NetworkCreateAcknowledgement(NETWORK_ID)
    reader = success_reader(on_read=read)
    if point == 'after_ack':
        reader.observations[1] = SystemExit()
    original = journal._write
    def write(row, **kwargs):
        if point == 'ready_write' and row['state'] == 'ready':
            raise SystemExit()
        return original(row, **kwargs)
    monkeypatch.setattr(journal, '_write', write)
    with pytest.raises(SystemExit):
        apply(journal, reader, Creator(on_create=create), source, authorize_create=lambda: True)
    assert current(journal, source).state == 'mutating'
    with ResourceJournal(journal.directory) as restarted:
        reader = Reader([NetworkListObservation('candidate', NETWORK_ID), NetworkIdentity(NETWORK_ID)])
        creator = Creator()
        receipt = apply(restarted, reader, creator, source)
    assert receipt.state == 'ready' and creator.calls == []


@pytest.mark.parametrize('value', [None, True, {}, NetworkIdentity(NETWORK_ID)])
def test_creator_return_shape_is_not_an_ack_and_never_certifies_ready(journal, source, value):
    creator = Creator(on_create=lambda *_: value)
    reader = Reader([NetworkListObservation('missing')])
    receipt = apply(journal, reader, creator, source, authorize_create=lambda: True)
    assert receipt.state == 'uncertain' and reader.calls == [('list', None)]


def test_creator_returning_ack_without_calling_gate_cannot_become_ready(journal, source):
    class BrokenCreator:
        def create(self, *_args, **_kwargs):
            return NetworkCreateAcknowledgement(NETWORK_ID)
    reader = Reader([NetworkListObservation('missing')])
    receipt = apply(journal, reader, BrokenCreator(), source, authorize_create=lambda: True)
    assert receipt.state == 'uncertain' and reader.calls == [('list', None)]


@pytest.mark.parametrize('separate_instance', [False, True])
def test_whole_effect_lease_rejects_concurrent_application(journal, source, separate_instance):
    entered, release = threading.Event(), threading.Event()
    results, errors = [], []
    second = ResourceJournal(journal.directory) if separate_instance else journal
    def paused(*_):
        entered.set()
        assert release.wait(3)
        return NetworkCreateAcknowledgement(NETWORK_ID)
    def run():
        try:
            results.append(apply(journal, success_reader(), Creator(on_create=paused), source, authorize_create=lambda: True))
        except BaseException as error:
            errors.append(error)
    thread = threading.Thread(target=run)
    thread.start()
    try:
        assert entered.wait(3)
        reader, creator = Reader(), Creator()
        with pytest.raises(ResourceJournalError, match='^worker_busy$'):
            apply(second, reader, creator, source, authorize_create=lambda: True)
        assert reader.calls == creator.calls == []
    finally:
        release.set()
        thread.join(3)
        if separate_instance:
            second.close()
    assert not thread.is_alive() and errors == [] and len(results) == 1 and results[0].state == 'ready'


@pytest.mark.parametrize('point', ['list', 'version', 'inspect'])
def test_correct_shape_nonce_change_cannot_rebind_observation_or_dispatch(journal, source, point):
    def change(_binding, intent, _event):
        object.__setattr__(intent, 'ownership_nonce', 'f' * 32)
    def read(method, *args):
        if method == point:
            change(*args)
    reader = success_reader(on_read=read)
    creator = Creator(on_version=change if point == 'version' else None)
    receipt = apply(journal, reader, creator, source, authorize_create=lambda: True)
    assert receipt.state == 'uncertain'
    assert creator.calls.count('create') == (1 if point == 'inspect' else 0)


@pytest.mark.parametrize('which', ['journal', 'reader', 'creator'])
def test_constructor_rejects_missing_private_dependencies_without_io(journal, which):
    from larenor_server.plugins.network_preparation import JournaledNetworkOperations, NetworkPreparationError
    inputs = dict(journal=journal, reader=Reader(), creator=Creator())
    inputs[which] = object()
    with pytest.raises(NetworkPreparationError, match='^invalid_network_preparation$'):
        JournaledNetworkOperations(**inputs)
    assert str(NetworkPreparationError('secret')) == 'invalid_network_preparation'


def test_invalid_current_source_is_rejected_before_journal_prepare(journal, source):
    from larenor_server.plugins.network_preparation import NetworkPreparationError
    object.__setattr__(source['plan'], 'workerPolicyVersion', True)
    reader, creator = Reader(), Creator()
    with pytest.raises(NetworkPreparationError, match='^invalid_network_binding$'):
        apply(journal, reader, creator, source, authorize_create=lambda: True)
    with journal.locked():
        assert journal.list() == ()
    assert reader.calls == creator.calls == []


def test_source_mutation_during_initial_authority_keeps_prepared(journal, source):
    from larenor_server.plugins.network_preparation import NetworkPreparationError
    def authorize():
        object.__setattr__(source['policy'], 'workerPolicyVersion', True)
        return True
    reader, creator = Reader(), Creator()
    with pytest.raises(NetworkPreparationError, match='^invalid_network_binding$'):
        apply(journal, reader, creator, source, authorize_create=authorize)
    assert current(journal, source).state == 'prepared' and reader.calls == creator.calls == []


def test_mutated_source_while_uncertain_reconcile_keeps_uncertain(journal, source):
    with journal.locked():
        journal.prepare(**source, resource_id=resource_id(source))
        journal.begin(resource_id(source), 1, **source)
        journal.mark_uncertain(resource_id(source), 2)
    def read(*_):
        object.__setattr__(source['plan'], 'workerPolicyVersion', True)
    creator = Creator()
    receipt = apply(journal, Reader([NetworkListObservation('candidate', NETWORK_ID)], on_read=read), creator, source)
    assert (receipt.state, receipt.code, receipt.revision) == ('uncertain', 'observation_unavailable', 4)
    assert creator.calls == []


def test_failed_uncertain_write_is_not_retried_or_hidden_as_success(journal, source, monkeypatch):
    calls = []
    def fail(*_):
        calls.append(True)
        raise ResourceJournalError('journal_unavailable')
    monkeypatch.setattr(journal, 'mark_uncertain', fail)
    def lost(*_):
        raise RuntimeError('private transport error')
    with pytest.raises(ResourceJournalError, match='^journal_unavailable$'):
        apply(journal, Reader([NetworkListObservation('missing')]), Creator(on_create=lost), source,
              authorize_create=lambda: True)
    assert len(calls) == 1 and current(journal, source).state == 'mutating'


def _platform_source(source, platform):
    from larenor_server.context import ContextResponse
    from larenor_server.plugins.stack_plan import build_media_stack_plan
    from larenor_server.plugins.resource_plan import build_resource_plan
    stack = build_media_stack_plan(source['catalog'], {}, platform,
        ContextResponse(schemaVersion=1, coreId='a' * 32, homeId='b' * 32), 'c' * 32)
    return {**source, 'stack': stack,
            'plan': build_resource_plan(stack, source['catalog'], source['policy'])}


def _network_document(body):
    return {**json.loads(body), 'Id': NETWORK_ID, 'Containers': {}, 'Options': None,
            'ConfigFrom': {'Network': ''}, 'IPAM': {'Driver': 'default', 'Options': None,
            'Config': [{'Subnet': '172.28.0.0/16', 'Gateway': '172.28.0.1'}]}}


@pytest.mark.parametrize('platform', ['linux/amd64', 'linux/arm64'])
@pytest.mark.parametrize('chunked', [False, True])
def test_real_unix_composition_uses_four_versioned_operations_and_verified_final_identity(journal, source, platform, chunked):
    from larenor_server.plugins.network_effects import UnixNetworkCreator
    from larenor_server.plugins.network_transport import UnixNetworkEngine
    from test_engine_http import VERSION, response
    from test_network_effects import create_server, ack_response
    from test_network_transport import framed
    source = _platform_source(source, platform)
    created = []
    grants = []
    def reply(connection):
        call = calls[-1]
        if call['head'].startswith(b'POST '):
            # Server fixture runs on another thread and cannot borrow the
            # caller's journal lease. Observe committed state independently.
            with sqlite3.connect(journal.directory / 'journal.sqlite') as db:
                assert db.execute('SELECT state,revision FROM resources').fetchone() == ('mutating', 2)
            created.append(_network_document(call['body']))
            connection.sendall(ack_response(chunked=chunked))
        elif b'/v1.47/networks?' in call['head']:
            connection.sendall(framed(created, chunked=chunked))
        else:
            assert call['head'].startswith(('GET /v1.47/networks/' + NETWORK_ID + ' ').encode())
            connection.sendall(framed(created[0], chunked=chunked))
    def authorize():
        grants.append(len(calls))
        return True
    with create_server(version=response({**VERSION, 'Arch': platform.split('/')[1]}), reply=reply) as (endpoint, calls):
        reader = UnixNetworkEngine(endpoint, peer_uid=lambda _: os.getuid())
        creator = UnixNetworkCreator(endpoint, peer_uid=lambda _: os.getuid())
        receipt = apply(journal, reader, creator, source, authorize_create=authorize)
        assert receipt.state == 'ready' and receipt.revision == 3
    assert grants == [0, 3] and len(calls) == 8
    assert all(calls[index]['head'].startswith(b'GET /version ') for index in (0, 2, 4, 6))
    assert sum(call['head'].startswith(b'POST ') for call in calls) == 1
    assert created[0]['Labels']['org.larenor.resource'] == resource_id(source)
    with ResourceJournal(journal.directory) as reopened:
        reader, creator = Reader(), Creator()
        assert apply(reopened, reader, creator, source) == receipt
        assert reader.calls == creator.calls == []


def test_actual_handshake_revocation_sends_no_create_post(journal, source):
    from larenor_server.plugins.network_effects import UnixNetworkCreator
    from larenor_server.plugins.network_transport import UnixNetworkEngine
    from test_engine_http import VERSION, response
    from test_network_effects import create_server
    from test_network_transport import framed
    allowed = True
    def version(connection):
        nonlocal allowed
        if len(calls) == 3:
            allowed = False
        connection.sendall(response(VERSION))
    with create_server(version=version, reply=framed([])) as (endpoint, calls):
        receipt = apply(journal, UnixNetworkEngine(endpoint, peer_uid=lambda _: os.getuid()),
                        UnixNetworkCreator(endpoint, peer_uid=lambda _: os.getuid()), source,
                        authorize_create=lambda: allowed)
    assert receipt.state == 'uncertain' and len(calls) == 3
    assert all(call['head'].startswith(b'GET ') for call in calls)


def test_actual_unix_lost_ack_reopens_journal_and_only_reads(journal, source):
    from larenor_server.plugins.network_effects import UnixNetworkCreator
    from larenor_server.plugins.network_transport import UnixNetworkEngine
    from test_engine_http import response
    from test_network_effects import create_server
    from test_network_transport import framed
    created = []
    def reply(connection):
        call = calls[-1]
        if call['head'].startswith(b'POST '):
            created.append(_network_document(call['body']))
            connection.shutdown(socket.SHUT_RDWR)
        elif b'/v1.47/networks?' in call['head']:
            connection.sendall(framed(created))
        else:
            connection.sendall(response(created[0]))
    with create_server(reply=reply) as (endpoint, calls):
        reader = UnixNetworkEngine(endpoint, peer_uid=lambda _: os.getuid())
        creator = UnixNetworkCreator(endpoint, peer_uid=lambda _: os.getuid())
        receipt = apply(journal, reader, creator, source, authorize_create=lambda: True)
        assert receipt.state == 'uncertain' and len(calls) == 4
        with ResourceJournal(journal.directory) as reopened:
            ready = apply(reopened, reader, creator, source,
                          authorize_create=lambda: pytest.fail('no recreate'))
        assert ready.state == 'ready' and ready.revision == 4
    assert len(calls) == 8 and sum(call['head'].startswith(b'POST ') for call in calls) == 1
