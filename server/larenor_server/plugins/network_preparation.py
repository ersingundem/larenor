"""Private journaled control-network preparation; no API/IPC/dispatcher wiring.

The complete process lease spans authorization, durable begin, list and effect.
Only a missing list from a newly begun call can reach one create. Restart and
uncertain states only reconcile by fresh list/full-ID inspect; no retry, adopt,
attach, delete or prune occurs. A 201 ACK is never a matched ownership receipt.

The reader, creator and synchronous literal-True authorizer are trusted private
dependencies. This seam does not issue real actor/session, daemon namespace,
host, disk or network grants. In particular, no mutator runs in a probe callback.
Transport budgets are per exchange (at most four); this is not five-second IPC.
Ready records a past full inspection, not installation or continuing exclusivity.
"""

import re
import threading

from .network_effects import NetworkCreateAcknowledgement
from .network_resources import (
    NetworkListObservation, NetworkResourceError, _inputs, build_network_create_body, network_binding,
)
from .resource_journal import (
    NetworkIdentity, ResourceJournal, ResourceJournalError, ResourceObservation, ResourceReceipt,
)


_CODES = frozenset({'invalid_network_preparation', 'invalid_network_binding',
                    'network_create_not_authorized', 'network_cancelled'})


class NetworkPreparationError(Exception):
    """Only a static code; no daemon warning, path, labels or callback message."""

    def __init__(self, code='invalid_network_preparation'):
        self.code = code if code in _CODES else 'invalid_network_preparation'
        super().__init__(self.code)


class _Unavailable(Exception):
    """Private observer failure, converted by the journal to uncertain."""


def _allowed(callback):
    if callback is None:
        return False
    try:
        return callback() is True
    except Exception:
        return False


def _network_id(value):
    return type(value) is str and re.fullmatch(r'[0-9a-f]{64}', value) is not None


def _exact(value, cls, names):
    return type(value) is cls and set(vars(value)) == set(names)


def _failure(error):
    if type(error) is NetworkResourceError:
        return {'network_conflict': 'conflict', 'network_multiple': 'multiple'}.get(error.code, 'unavailable')
    return 'unavailable'


class JournaledNetworkOperations:
    """Caller-owned journal and private adapters; construction performs no I/O."""

    def __init__(self, journal: ResourceJournal, reader, creator):
        if (type(journal) is not ResourceJournal
                or not callable(getattr(reader, 'list', None))
                or not callable(getattr(reader, 'inspect', None))
                or not callable(getattr(creator, 'create', None))):
            raise NetworkPreparationError()
        self._journal, self._reader, self._creator = journal, reader, creator

    def _uncertain(self, receipt):
        current = self._journal.get(receipt.resource_id)
        if current != receipt or current.state != 'mutating':
            return current
        return self._journal.mark_uncertain(receipt.resource_id, receipt.revision)

    def _live(self, receipt, source, binding, event, intent=None, token=None):
        if event.is_set() or self._journal.get(receipt.resource_id) != receipt:
            raise _Unavailable()
        try:
            fresh = network_binding(**source, resource_id=receipt.resource_id)
            # Existing prepare is read-only and compares the complete stored
            # source snapshot, not just resource ID or a mutable object alias.
            if self._journal.prepare(**source, resource_id=receipt.resource_id) != receipt:
                raise _Unavailable()
            if intent is None:
                return None
            if intent.receipt != receipt:
                raise _Unavailable()
            _, labels = _inputs(binding, intent)
            _, current_labels = _inputs(fresh, intent)
            actual = tuple(sorted(labels.items()))
            if labels != current_labels or (token is not None and actual != token):
                raise _Unavailable()
            return actual
        except NetworkResourceError:
            raise _Unavailable() from None
        except ResourceJournalError as error:
            if error.code in {'invalid_binding', 'idempotency_conflict'}:
                raise _Unavailable() from None
            raise

    def _list(self, receipt, source, binding, event, intent, token):
        self._live(receipt, source, binding, event, intent, token)
        try:
            value = self._reader.list(binding, intent, cancelled=event)
        except Exception as error:
            state, network_id = _failure(error), None
        else:
            state, network_id = 'unavailable', None
            if _exact(value, NetworkListObservation, ('state', 'network_id')):
                if value.state == 'missing' and value.network_id is None:
                    state = 'missing'
                elif value.state == 'candidate' and _network_id(value.network_id):
                    state, network_id = 'candidate', value.network_id
        self._live(receipt, source, binding, event, intent, token)
        return state, network_id

    def _observe(self, receipt, source, binding, event, intent, token, expected_id, after_create):
        state, network_id = self._list(receipt, source, binding, event, intent, token)
        if state != 'candidate':
            return ('unavailable' if after_create and state == 'missing' else state), None
        if expected_id is not None and network_id != expected_id:
            return 'conflict', None
        try:
            value = self._reader.inspect(binding, intent, network_id, cancelled=event)
        except Exception as error:
            state, identity = _failure(error), None
        else:
            state, identity = 'unavailable', None
            if _exact(value, NetworkIdentity, ('network_id',)) and _network_id(value.network_id):
                if value.network_id == network_id:
                    state, identity = 'matched', NetworkIdentity(network_id)
                else:
                    state = 'conflict'
        self._live(receipt, source, binding, event, intent, token)
        return state, identity

    def _reconcile(self, receipt, source, binding, event, *, known_status=None, expected_id=None, after_create=False):
        try:
            self._live(receipt, source, binding, event)
        except _Unavailable:
            return self._uncertain(receipt)

        def observe(intent):
            token = self._live(receipt, source, binding, event, intent)
            if known_status is None:
                status, identity = self._observe(receipt, source, binding, event, intent, token, expected_id, after_create)
            else:
                status, identity = known_status, None
            # Recheck original apply inputs after all I/O; the journal itself
            # rechecks revision, but does not rederive source after its observer.
            self._live(receipt, source, binding, event, intent, token)
            return ResourceObservation(status, intent.resource.resourceId, intent.journal_id,
                intent.ownership_nonce, intent.specification_digest, identity)

        try:
            return self._journal.reconcile(receipt.resource_id, receipt.revision, observe, **source)
        except ResourceJournalError as error:
            if error.code == 'revision_conflict':
                current = self._journal.get(receipt.resource_id)
                if current != receipt:
                    return current
            raise

    def apply(self, plan, stack, catalog, policy, resource_id, *, authorize_create=None,
              cancelled=None) -> ResourceReceipt:
        if ((authorize_create is not None and not callable(authorize_create))
                or (cancelled is not None and type(cancelled) is not threading.Event)):
            raise NetworkPreparationError()
        try:
            binding = network_binding(plan, stack, catalog, policy, resource_id)
        except NetworkResourceError:
            raise NetworkPreparationError('invalid_network_binding') from None
        event = threading.Event() if cancelled is None else cancelled
        if event.is_set():
            raise NetworkPreparationError('network_cancelled')
        source = dict(plan=plan, stack=stack, catalog=catalog, policy=policy)
        with self._journal.locked():
            receipt = self._journal.prepare(**source, resource_id=resource_id)
            if receipt.state in {'ready', 'needs_attention'}:
                return receipt
            if receipt.state in {'mutating', 'uncertain'}:
                return self._reconcile(receipt, source, binding, event)
            if not _allowed(authorize_create):
                raise NetworkPreparationError('network_create_not_authorized')
            if event.is_set():
                raise NetworkPreparationError('network_cancelled')
            try:
                self._live(receipt, source, binding, event)
            except _Unavailable:
                current = self._journal.get(resource_id)
                if current != receipt:
                    return current
                raise NetworkPreparationError('invalid_network_binding') from None
            intent = self._journal.begin(resource_id, receipt.revision, **source)
            receipt = intent.receipt
            token = self._live(receipt, source, binding, event, intent)
            expected_body = build_network_create_body(binding, intent)
            try:
                state, candidate_id = self._list(receipt, source, binding, event, intent, token)
            except _Unavailable:
                return self._uncertain(receipt)
            if state != 'missing':
                return self._reconcile(receipt, source, binding, event,
                    known_status=None if state == 'candidate' else state, expected_id=candidate_id)

            gate_passed = False
            def gate():
                nonlocal gate_passed
                self._live(receipt, source, binding, event, intent, token)
                if not _allowed(authorize_create):
                    return False
                self._live(receipt, source, binding, event, intent, token)
                if build_network_create_body(binding, intent) != expected_body:
                    return False
                gate_passed = True
                return True

            try:
                self._live(receipt, source, binding, event, intent, token)
                ack = self._creator.create(binding, intent, before_dispatch=gate, cancelled=event)
                self._live(receipt, source, binding, event, intent, token)
            except Exception:
                return self._uncertain(receipt)
            if (not gate_passed or not _exact(ack, NetworkCreateAcknowledgement, ('network_id',))
                    or not _network_id(ack.network_id)):
                return self._uncertain(receipt)
            return self._reconcile(receipt, source, binding, event, expected_id=ack.network_id, after_create=True)
