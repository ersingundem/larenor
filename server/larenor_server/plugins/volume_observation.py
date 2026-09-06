"""Private durable volume-label observations, without Engine effect authority.

One caller-owned journal lease spans prepare, durable observation intent, bounded
read and revision/source-checked reconciliation. Interrupted or uncertain reads
can only be observed again. Terminal receipts are historical and are returned
without claiming a fresh Engine observation, exclusive ownership or readiness.

The reader is a trusted in-process dependency (normally UnixVolumeReader), not
wire input. This module exposes no worker/API/IPC/CLI, create/delete, bootstrap,
actor authorization or installation grant. Both dependencies remain caller-owned.
"""
import threading

from .volume_journal import VolumeJournal, VolumeReceipt

_CODES = frozenset({'invalid_volume_observation', 'volume_cancelled'})


class VolumeObservationError(Exception):
    """Static boundary diagnostic; journal/transport payloads are never exposed."""

    def __init__(self, code='invalid_volume_observation'):
        self.code = code if code in _CODES else 'invalid_volume_observation'
        super().__init__(self.code)


class JournaledVolumeObservations:
    """Synchronous SQLite + read-only observer composition; no background retry."""

    def __init__(self, journal: VolumeJournal, reader):
        try:
            valid = type(journal) is VolumeJournal and callable(getattr(reader, 'inspect', None))
        except Exception:
            valid = False
        if not valid:
            raise VolumeObservationError()
        self._journal, self._reader = journal, reader

    def observe(self, plan, stack, catalog, policy, resource_id, *, cancelled=None) -> VolumeReceipt:
        if cancelled is not None and type(cancelled) is not threading.Event:
            raise VolumeObservationError()
        event = cancelled if cancelled is not None else threading.Event()
        if event.is_set():
            raise VolumeObservationError('volume_cancelled')
        source = dict(plan=plan, stack=stack, catalog=catalog, policy=policy)
        journal, reader = self._journal, self._reader
        with journal.locked():
            if event.is_set():
                raise VolumeObservationError('volume_cancelled')
            receipt = journal.prepare(**source, resource_id=resource_id)
            if event.is_set():
                raise VolumeObservationError('volume_cancelled')
            if receipt.state in {'labels_observed', 'needs_attention'}:
                return receipt
            if receipt.state == 'prepared':
                receipt = journal.begin_observation(resource_id, receipt.revision, **source).receipt

            # reconcile binds this journal's nonce and exact revision, validates
            # typed output, then rechecks source/CAS/cancellation before commit.
            return journal.reconcile(resource_id, receipt.revision,
                lambda intent: reader.inspect(intent.binding, cancelled=event),
                cancelled=event, **source)
