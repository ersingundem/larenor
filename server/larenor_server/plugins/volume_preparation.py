"""Private journaled managed-volume CREATE, not a production installer.

A complete locked lease spans source validation, durable begin, a fresh probe,
one explicitly gated POST and a separate fresh GET. Only an absence from this
newly begun call may reach CREATE. Restarted mutating/uncertain records reconcile
read-only, including when the volume is absent; there is no POST replay, adopt,
delete, bootstrap or container mount. An observed result still requires bootstrap.

The engine and synchronous literal-True authorizer are trusted private seams,
not real actor/daemon/storage-budget grant issuers. No API/IPC/runtime uses them.
Transport limits are per exchange: up to three exchanges (each at most 10s,
including /version). This is not a hard whole-operation deadline: callbacks and
SQLite/filesystem calls are not preempted here. No probe.during mutator exists.
"""
from dataclasses import replace
import threading

from .resource_journal import ResourceJournalError
from .volume_create_journal import VolumeCreateJournal, _exact
from .volume_effects import (
    VolumeAbsent, VolumeCreateAcknowledgement, VolumeEffectError, _inputs,
)
from .volume_plan import verify_volume_plan
from .volume_resources import VolumeObservation, VolumeResourceError
from .resource_journal import _digest


class VolumePreparationError(Exception):
    def __init__(self, code='invalid_volume_preparation'):
        self.code = code if code in {'invalid_volume_preparation', 'volume_create_not_authorized',
                                    'volume_cancelled'} else 'invalid_volume_preparation'
        super().__init__(self.code)


class _Unavailable(Exception):
    pass


def _allowed(callback):
    try:
        return callable(callback) and callback() is True
    except Exception:
        return False


class JournaledVolumeCreates:
    def __init__(self, journal, engine):
        if (type(journal) is not VolumeCreateJournal
                or not callable(getattr(engine, 'probe', None))
                or not callable(getattr(engine, 'create', None))):
            raise VolumePreparationError()
        self._journal, self._engine = journal, engine

    def _uncertain(self, receipt):
        current = self._journal.get(receipt.resource_id)
        if current != receipt or current.state != 'mutating':
            return current
        return self._journal.mark_uncertain(receipt.resource_id, receipt.revision)

    def _live(self, receipt, source, event, intent=None, token=None):
        if event.is_set() or self._journal.get(receipt.resource_id) != receipt:
            raise _Unavailable()
        try:
            fresh = self._journal.bind(receipt.resource_id, receipt.revision, **source)
            if fresh.receipt != receipt:
                raise _Unavailable()
            if intent is None:
                return None
            if intent.receipt != receipt:
                raise _Unavailable()
            labels = _inputs(intent)[1]
            if labels != _inputs(fresh)[1]:
                raise _Unavailable()
            actual = tuple(sorted(labels.items()))
            if token is not None and actual != token:
                raise _Unavailable()
            return actual
        except VolumeEffectError:
            raise _Unavailable() from None
        except ResourceJournalError as error:
            if error.code in {'invalid_volume_binding', 'idempotency_conflict', 'revision_conflict'}:
                raise _Unavailable() from None
            raise

    def _reconcile(self, receipt, source, event, *, conflict=False):
        try:
            self._live(receipt, source, event)
        except _Unavailable:
            return self._uncertain(receipt)

        def observe(intent):
            token = self._live(receipt, source, event, intent)
            if conflict:
                raise VolumeResourceError('volume_conflict')
            result = self._engine.probe(intent, cancelled=event)
            self._live(receipt, source, event, intent, token)
            if type(result) is VolumeAbsent:
                # An absent restarted/post-create target is never permission to
                # attempt CREATE. Keep it unresolved for explicit inspection.
                raise _Unavailable()
            return result

        try:
            return self._journal.reconcile(receipt.resource_id, receipt.revision,
                observe, **source, cancelled=event)
        except ResourceJournalError as error:
            if error.code == 'revision_conflict':
                current = self._journal.get(receipt.resource_id)
                if current != receipt:
                    return current
            if error.code in {'invalid_volume_binding', 'idempotency_conflict', 'volume_cancelled'}:
                return self._uncertain(receipt)
            raise

    def apply(self, plan, stack, catalog, policy, resource_id, *, authorize_create=None, cancelled=None):
        event = threading.Event() if cancelled is None else cancelled
        if type(event) is not threading.Event:
            raise VolumePreparationError()
        if event.is_set():
            raise VolumePreparationError('volume_cancelled')
        try:
            verify_volume_plan(plan, stack, catalog, policy)
        except (ValueError, TypeError, AttributeError):
            raise VolumePreparationError() from None
        source = dict(plan=plan, stack=stack, catalog=catalog, policy=policy)
        with self._journal.locked():
            receipt = replace(self._journal.prepare(**source, resource_id=resource_id))
            if receipt.state in {'observed_requires_bootstrap', 'needs_attention'}:
                if event.is_set():
                    raise VolumePreparationError('volume_cancelled')
                return receipt
            if receipt.state in {'mutating', 'uncertain'}:
                return self._reconcile(receipt, source, event)
            if not _allowed(authorize_create):
                raise VolumePreparationError('volume_create_not_authorized')
            try:
                self._live(receipt, source, event)
            except _Unavailable:
                raise VolumePreparationError('volume_cancelled') from None
            # If durable begin fails or its acknowledgement is lost, do not call
            # the Engine. A later apply reads the actual stored phase first.
            intent = self._journal.begin_create(resource_id, receipt.revision, **source)
            receipt = replace(intent.receipt)
            try:
                token = self._live(receipt, source, event, intent)
                expected = _digest(dict(token))
                result = self._engine.probe(intent, cancelled=event)
                self._live(receipt, source, event, intent, token)
                if _exact(result, VolumeObservation):
                    return self._reconcile(receipt, source, event)
                if (not _exact(result, VolumeAbsent)
                        or result != VolumeAbsent(resource_id, expected)):
                    raise _Unavailable()
                gate_used = False
                gate_accepted = False
                def gate():
                    nonlocal gate_used, gate_accepted
                    if gate_used:
                        return False
                    gate_used = True
                    self._live(receipt, source, event, intent, token)
                    allowed = _allowed(authorize_create)
                    self._live(receipt, source, event, intent, token)
                    gate_accepted = allowed
                    return allowed
                acknowledgement = self._engine.create(intent, before_dispatch=gate, cancelled=event)
                self._live(receipt, source, event, intent, token)
                if (not gate_accepted or not _exact(acknowledgement, VolumeCreateAcknowledgement)
                        or acknowledgement != VolumeCreateAcknowledgement(resource_id, expected)):
                    raise _Unavailable()
                return self._reconcile(receipt, source, event)
            except VolumeResourceError as error:
                if error.code == 'volume_conflict':
                    return self._reconcile(receipt, source, event, conflict=True)
                return self._uncertain(receipt)
            except ResourceJournalError:
                raise
            except Exception:
                # Unknown/late acknowledgements never produce a receipt from the
                # POST body and never cause a retry or an automatic cleanup.
                return self._uncertain(receipt)
