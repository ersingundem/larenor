"""Private durable network composition; only temporary journals and fake engines."""

from collections import deque
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


def test_callback_cannot_mutate_the_bridge_expected_receipt_via_intent_alias(journal, source):
    def change_receipt(_method, _binding, intent, _event):
        object.__setattr__(intent.receipt, 'revision', 99)
    reader = Reader([NetworkListObservation('missing')], on_read=change_receipt)
    creator = Creator()
    receipt = apply(journal, reader, creator, source, authorize_create=lambda: True)
    assert (receipt.state, receipt.code, receipt.revision) == ('uncertain', 'effect_uncertain', 3)
    assert creator.calls == []
