"""Private journaled image operations; deliberately not wired to API/IPC/CLI.

The complete process lease spans inspect, authorization and pull. A committed
intent precedes every possible pull; interrupted/uncertain intents can only be
observed again. Cache hits also receive a durable intent followed by a fresh
inspection. A ready receipt records that inspection, not exclusive ownership,
current availability, container creation or permission to install anything.

The engine and authorization callback are trusted in-process dependencies, not
wire inputs. Pull requires literal True both before recording intent and again
immediately before dispatch. This seam is NOT a production authorization policy:
actor/session, daemon context, image-store budget and runtime cancellation gates
remain future dispatcher requirements. Shared cache images are never deleted.
"""

import threading

from .image_resources import ImageObservation, ImageResourceError, image_binding
from .resource_journal import (
    ImageIdentity, ResourceJournal, ResourceObservation, ResourceReceipt,
)
from .worker import DockerWorkerError, _canonical, _decode


_CODES = frozenset({'invalid_image_preparation', 'invalid_image_binding',
                    'image_cancelled', 'image_pull_not_authorized',
                    'image_observation_unavailable'})


class ImagePreparationError(Exception):
    """Static diagnostic without an upstream message, configuration or path."""

    def __init__(self, code='invalid_image_preparation'):
        self.code = code if code in _CODES else 'invalid_image_preparation'
        super().__init__(self.code)


def _allowed(callback):
    if callback is None:
        return False
    try:
        return callback() is True
    except Exception:
        return False


def _cancelled(event):
    if event.is_set():
        raise ImagePreparationError('image_cancelled')


def _valid_observation(value, binding):
    if (type(value) is not ImageObservation
            or set(vars(value)) != {'image_id', 'configuration'}
            or type(value.image_id) is not str or value.image_id != binding.config_digest
            or type(value.configuration) is not bytes):
        return False
    try:
        return _canonical(_decode(value.configuration, limit=65536)) == value.configuration
    except DockerWorkerError:
        return False


class JournaledImageOperations:
    """Compose a private ResourceJournal and an inspect/pull engine dependency.

    Construction has no side effects. The caller owns both dependencies and
    their lifetime. ``apply`` is synchronous; no background retry is scheduled.
    """

    def __init__(self, journal: ResourceJournal, engine):
        if (type(journal) is not ResourceJournal
                or not callable(getattr(engine, 'inspect', None))
                or not callable(getattr(engine, 'pull', None))):
            raise ImagePreparationError()
        self._journal, self._engine = journal, engine

    def _inspect(self, binding, event):
        if event.is_set():
            return 'unavailable'
        try:
            value = self._engine.inspect(binding, cancelled=event)
        except ImageResourceError as error:
            return 'conflict' if error.code == 'image_unverified' and not event.is_set() else 'unavailable'
        except Exception:
            return 'unavailable'
        if event.is_set():
            return 'unavailable'
        if value is None:
            return 'missing'
        return 'matched' if _valid_observation(value, binding) else 'conflict'

    def _reconcile(self, receipt, binding, event, source, *, known_conflict=False):
        def observe(intent):
            status = 'conflict' if known_conflict else self._inspect(binding, event)
            return ResourceObservation(status, intent.resource.resourceId, intent.journal_id,
                intent.ownership_nonce, intent.specification_digest,
                ImageIdentity(binding.config_digest) if status == 'matched' else None)
        return self._journal.reconcile(receipt.resource_id, receipt.revision, observe, **source)

    def _uncertain(self, receipt):
        # A trusted callback may have reentered the held lease. Never overwrite
        # its newer receipt or dispatch an effect based on the older revision.
        current = self._journal.get(receipt.resource_id)
        if current != receipt:
            return current
        return self._journal.mark_uncertain(receipt.resource_id, receipt.revision)

    def apply(self, plan, stack, catalog, policy, resource_id, *,
              authorize_pull=None, cancelled=None) -> ResourceReceipt:
        try:
            binding = image_binding(plan, stack, catalog, policy, resource_id)
        except ImageResourceError:
            raise ImagePreparationError('invalid_image_binding') from None
        if ((authorize_pull is not None and not callable(authorize_pull))
                or (cancelled is not None and type(cancelled) is not threading.Event)):
            raise ImagePreparationError()
        event = cancelled if cancelled is not None else threading.Event()
        _cancelled(event)
        source = dict(plan=plan, stack=stack, catalog=catalog, policy=policy)
        with self._journal.locked():
            receipt = self._journal.prepare(**source, resource_id=resource_id)
            if receipt.state in {'ready', 'needs_attention'}:
                return receipt
            if receipt.state in {'mutating', 'uncertain'}:
                return self._reconcile(receipt, binding, event, source)

            status = self._inspect(binding, event)
            _cancelled(event)
            if status == 'unavailable':
                raise ImagePreparationError('image_observation_unavailable')
            if status == 'missing':
                if not _allowed(authorize_pull):
                    raise ImagePreparationError('image_pull_not_authorized')
                _cancelled(event)

            intent = self._journal.begin(resource_id, receipt.revision, **source)
            receipt = intent.receipt
            if status != 'missing':
                return self._reconcile(receipt, binding, event, source,
                                       known_conflict=status == 'conflict')

            if event.is_set() or not _allowed(authorize_pull) or event.is_set():
                return self._uncertain(receipt)
            current = self._journal.get(resource_id)
            if current != receipt:
                return current
            try:
                # Revalidate after the callback as well; model_copy/unsafe local
                # mutation cannot turn this into a different authorized effect.
                fresh = image_binding(**source, resource_id=resource_id)
            except Exception:
                return self._uncertain(receipt)
            if fresh != binding or event.is_set():
                return self._uncertain(receipt)
            try:
                result = self._engine.pull(fresh, cancelled=event)
            except Exception:
                return self._uncertain(receipt)
            if result is not None or event.is_set():
                return self._uncertain(receipt)
            return self._reconcile(receipt, binding, event, source)
