"""Real private journal and synthetic image engine: no Docker or network calls."""

from collections import deque
from dataclasses import replace
import sqlite3
import threading

import pytest

from larenor_server.context import ContextResponse
from larenor_server.plugins.catalog import load_catalog
from larenor_server.plugins.image_preparation import ImagePreparationError, JournaledImageOperations
from larenor_server.plugins.image_resources import ImageObservation, ImageResourceError, image_binding
from larenor_server.plugins.resource_journal import ResourceJournal, ResourceJournalError
from larenor_server.plugins.resource_models import WorkerPolicyBinding
from larenor_server.plugins.resource_plan import build_resource_plan
from larenor_server.plugins.stack_plan import build_media_stack_plan


@pytest.fixture
def source():
    catalog = load_catalog()
    stack = build_media_stack_plan(catalog, {}, 'linux/amd64',
        ContextResponse(schemaVersion=1, coreId='a' * 32, homeId='b' * 32), 'c' * 32)
    policy = WorkerPolicyBinding(schemaVersion=1, workerPolicyVersion=3, workerPolicyDigest='d' * 64)
    return dict(plan=build_resource_plan(stack, catalog, policy), stack=stack, catalog=catalog, policy=policy)


@pytest.fixture
def journal(tmp_path):
    with ResourceJournal(tmp_path / 'resources-v1', initialize=True) as value:
        yield value


def identity(source):
    return source['plan'].resources[0].resourceId


def matched(source):
    binding = image_binding(**source, resource_id=identity(source))
    return ImageObservation(binding.config_digest, b'{"Env":[]}')


class Engine:
    def __init__(self, observations=(), *, on_inspect=None, on_pull=None):
        self.observations = deque(observations)
        self.calls = []
        self.on_inspect, self.on_pull = on_inspect, on_pull

    def inspect(self, binding, *, cancelled):
        self.calls.append('inspect')
        if self.on_inspect:
            self.on_inspect(binding, cancelled)
        value = self.observations.popleft()
        if isinstance(value, Exception):
            raise value
        return value

    def pull(self, binding, *, cancelled):
        self.calls.append('pull')
        if self.on_pull:
            return self.on_pull(binding, cancelled)


def apply(journal, engine, source, **options):
    return JournaledImageOperations(journal, engine).apply(**source, resource_id=identity(source), **options)


def current(journal, source):
    with journal.locked():
        return journal.get(identity(source))


def rejected(code, action):
    with pytest.raises(ImagePreparationError) as caught:
        action()
    assert caught.value.code == str(caught.value) == code


def test_authorized_pull_is_durable_before_effect_and_freshly_verified(journal, source):
    order = []

    def authorize():
        receipt = journal.get(identity(source))
        order.append('authorize:' + receipt.state)
        return True

    def pull(binding, cancelled):
        assert binding == image_binding(**source, resource_id=identity(source))
        assert not cancelled.is_set()
        with sqlite3.connect(journal.directory / 'journal.sqlite') as db:
            assert db.execute('SELECT state,revision FROM resources').fetchone() == ('mutating', 2)
            # The process lease remains held, but no SQLite write transaction spans I/O.
            db.execute('BEGIN IMMEDIATE')
            db.rollback()
        with ResourceJournal(journal.directory) as other:
            with pytest.raises(ResourceJournalError, match='^worker_busy$'):
                with other.locked():
                    pass
        order.append('pull')

    engine = Engine([None, matched(source)], on_pull=pull)
    receipt = apply(journal, engine, source, authorize_pull=authorize)
    assert order == ['authorize:prepared', 'authorize:mutating', 'pull']
    assert engine.calls == ['inspect', 'pull', 'inspect']
    assert (receipt.state, receipt.code, receipt.revision) == ('ready', 'resource_matched', 3)
    assert current(journal, source) == receipt


def test_cache_hit_begins_then_reobserves_without_asking_for_pull_authority(journal, source):
    states = []
    engine = Engine([matched(source), matched(source)],
                    on_inspect=lambda *_: states.append(journal.get(identity(source)).state))
    receipt = apply(journal, engine, source, authorize_pull=lambda: pytest.fail('cache needs no pull'))
    assert engine.calls == ['inspect', 'inspect'] and states == ['prepared', 'mutating']
    assert receipt.state == 'ready'
    assert apply(journal, Engine(), source) == receipt


@pytest.mark.parametrize('authority', [None, lambda: False, lambda: 1, lambda: 'true', lambda: None])
def test_missing_or_nonliteral_authority_never_pulls(journal, source, authority):
    engine = Engine([None])
    rejected('image_pull_not_authorized', lambda: apply(journal, engine, source, authorize_pull=authority))
    assert engine.calls == ['inspect'] and current(journal, source).state == 'prepared'


def test_authorization_exception_is_static_and_never_persisted(journal, source):
    def fail():
        raise RuntimeError('private-password-and-host-path')
    rejected('image_pull_not_authorized', lambda: apply(journal, Engine([None]), source, authorize_pull=fail))
    assert b'private-password' not in (journal.directory / 'journal.sqlite').read_bytes()


@pytest.mark.parametrize('options', [{'authorize_pull': True}, {'cancelled': True}, {'cancelled': object()}])
def test_invalid_private_call_options_fail_before_any_io(journal, source, options):
    engine = Engine()
    rejected('invalid_image_preparation', lambda: apply(journal, engine, source, **options))
    assert not engine.calls
    with journal.locked():
        assert journal.list() == ()


@pytest.mark.parametrize('failure', [ImageResourceError('image_unverified'),
    ImageObservation('sha256:' + 'f' * 64, b'{}'), object(),
    ImageObservation(True, b'{}'), ImageObservation('sha256:' + 'a' * 64, 'not-bytes')])
def test_wrong_cache_is_terminal_conflict_and_never_overwritten(journal, source, failure):
    engine = Engine([failure])
    receipt = apply(journal, engine, source, authorize_pull=lambda: pytest.fail('wrong cache'))
    assert (receipt.state, receipt.code) == ('needs_attention', 'resource_conflict')
    assert engine.calls == ['inspect']
    assert apply(journal, Engine(), source) == receipt


@pytest.mark.parametrize('configuration', [b'[]', b'{"x":1,"x":2}', b'{"x":NaN}', b'{"x":1e999}',
    b'{broken', b'{"x": 1}', b'\xff', b'{' + b' ' * 65536 + b'}'])
def test_invalid_inspection_configuration_never_becomes_a_ready_receipt(journal, source, configuration):
    engine = Engine([replace(matched(source), configuration=configuration)])
    assert apply(journal, engine, source).code == 'resource_conflict'
    assert engine.calls == ['inspect']


def test_inspection_dataclass_hidden_extra_field_is_rejected(journal, source):
    observation = matched(source)
    object.__setattr__(observation, 'untrusted', 'secret')
    assert apply(journal, Engine([observation]), source).code == 'resource_conflict'


@pytest.mark.parametrize('failure', [ImageResourceError(), ImageResourceError('image_timeout'),
                                   RuntimeError('secret upstream payload')])
def test_initial_unavailable_observation_does_not_start_an_effect(journal, source, failure):
    engine = Engine([failure])
    rejected('image_observation_unavailable', lambda: apply(journal, engine, source, authorize_pull=lambda: True))
    assert engine.calls == ['inspect'] and current(journal, source).state == 'prepared'


def test_lost_pull_response_restarts_with_inspection_only(journal, source):
    def lose_response(*_):
        raise RuntimeError('secret connection detail')
    engine = Engine([None], on_pull=lose_response)
    receipt = apply(journal, engine, source, authorize_pull=lambda: True)
    assert (receipt.state, receipt.code, receipt.revision) == ('uncertain', 'effect_uncertain', 3)
    assert engine.calls == ['inspect', 'pull'] and 'secret' not in repr(receipt)
    with ResourceJournal(journal.directory) as restarted:
        second = Engine([matched(source)])
        ready = apply(restarted, second, source, authorize_pull=lambda: pytest.fail('never retry uncertain pull'))
    assert (ready.state, ready.revision) == ('ready', 4) and second.calls == ['inspect']


@pytest.mark.parametrize('state', ['mutating', 'uncertain'])
@pytest.mark.parametrize('observed,expected', [(None, 'needs_attention'), (RuntimeError('private'), 'uncertain')])
def test_existing_intent_never_pulls_even_when_cache_is_missing(journal, source, state, observed, expected):
    with journal.locked():
        journal.prepare(**source, resource_id=identity(source))
        journal.begin(identity(source), 1, **source)
        if state == 'uncertain':
            journal.mark_uncertain(identity(source), 2)
    engine = Engine([observed])
    receipt = apply(journal, engine, source, authorize_pull=lambda: pytest.fail('replay authority is irrelevant'))
    assert receipt.state == expected and engine.calls == ['inspect']


@pytest.mark.parametrize('observed,code', [(None, 'resource_missing'),
    (ImageResourceError('image_unverified'), 'resource_conflict'),
    (ImageResourceError(), 'observation_unavailable')])
def test_successful_pull_stream_is_not_itself_a_verified_image(journal, source, observed, code):
    engine = Engine([None, observed])
    receipt = apply(journal, engine, source, authorize_pull=lambda: True)
    assert receipt.code == code and receipt.state != 'ready'
    assert engine.calls == ['inspect', 'pull', 'inspect']


def test_cancelled_before_start_has_no_journal_or_engine_io(journal, source):
    event = threading.Event()
    event.set()
    engine = Engine()
    rejected('image_cancelled', lambda: apply(journal, engine, source, cancelled=event))
    assert not engine.calls
    with journal.locked():
        assert journal.list() == ()


def test_cancel_during_initial_inspect_keeps_prepared_without_pull(journal, source):
    event = threading.Event()
    engine = Engine([None], on_inspect=lambda *_: event.set())
    rejected('image_cancelled', lambda: apply(journal, engine, source, cancelled=event, authorize_pull=lambda: True))
    assert engine.calls == ['inspect'] and current(journal, source).state == 'prepared'


@pytest.mark.parametrize('second', ['denied', 'throws', 'cancelled', 'reentrant'])
def test_dispatch_rechecks_authority_and_cancellation_after_durable_begin(journal, source, second):
    event = threading.Event()
    count = 0
    def authorize():
        nonlocal count
        count += 1
        if count == 1:
            return True
        assert journal.get(identity(source)).state == 'mutating'
        if second == 'denied':
            return False
        if second == 'throws':
            raise RuntimeError('secret')
        if second == 'cancelled':
            event.set()
        if second == 'reentrant':
            journal.mark_uncertain(identity(source), 2)
        return True
    engine = Engine([None])
    receipt = apply(journal, engine, source, cancelled=event, authorize_pull=authorize)
    assert (receipt.state, receipt.revision) == ('uncertain', 3)
    assert engine.calls == ['inspect'] and count == 2


def test_cancellation_during_pull_cannot_publish_success(journal, source):
    event = threading.Event()
    engine = Engine([None], on_pull=lambda *_: event.set())
    receipt = apply(journal, engine, source, cancelled=event, authorize_pull=lambda: True)
    assert receipt.state == 'uncertain' and engine.calls == ['inspect', 'pull']


@pytest.mark.parametrize('field', ['plan', 'stack', 'policy', 'resource'])
def test_changed_binding_is_rejected_before_engine_access(journal, source, field):
    damaged = dict(source)
    if field == 'plan':
        damaged['plan'] = source['plan'].model_copy(update={'installAvailable': True})
    elif field == 'stack':
        damaged['stack'] = source['stack'].model_copy(update={'homeId': 'e' * 32})
    elif field == 'policy':
        damaged['policy'] = source['policy'].model_copy(update={'workerPolicyDigest': 'e' * 64})
    engine = Engine()
    resource = source['plan'].resources[1].resourceId if field == 'resource' else identity(source)
    rejected('invalid_image_binding', lambda: JournaledImageOperations(journal, engine).apply(
        **damaged, resource_id=resource, authorize_pull=lambda: True))
    assert engine.calls == []


def test_changed_current_policy_cannot_rebind_an_existing_receipt(journal, source):
    apply(journal, Engine([matched(source), matched(source)]), source)
    changed = dict(source)
    changed['policy'] = source['policy'].model_copy(update={'workerPolicyDigest': 'e' * 64})
    changed['plan'] = build_resource_plan(source['stack'], source['catalog'], changed['policy'])
    engine = Engine()
    with pytest.raises(ResourceJournalError, match='^idempotency_conflict$'):
        apply(journal, engine, changed, authorize_pull=lambda: True)
    assert not engine.calls and current(journal, source).state == 'ready'


@pytest.mark.parametrize('failing_state', ['mutating', 'ready', 'uncertain'])
def test_journal_write_failure_never_creates_unrecorded_or_repeated_effect(journal, source, monkeypatch, failing_state):
    original = journal._write
    def write(row, **kwargs):
        if row['state'] == failing_state:
            raise ResourceJournalError('journal_unavailable')
        return original(row, **kwargs)
    monkeypatch.setattr(journal, '_write', write)
    def pull(*_):
        if failing_state == 'uncertain':
            raise RuntimeError('lost response')
    engine = Engine([None, matched(source)], on_pull=pull)
    with pytest.raises(ResourceJournalError, match='^journal_unavailable$'):
        apply(journal, engine, source, authorize_pull=lambda: True)
    monkeypatch.setattr(journal, '_write', original)
    state = 'prepared' if failing_state == 'mutating' else 'mutating'
    assert current(journal, source).state == state
    assert engine.calls.count('pull') == (0 if failing_state == 'mutating' else 1)
    if state == 'mutating':
        with ResourceJournal(journal.directory) as restarted:
            retry = Engine([matched(source)])
            assert apply(restarted, retry, source).state == 'ready'
            assert retry.calls == ['inspect']
