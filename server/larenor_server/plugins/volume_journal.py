"""Separate volume observation history; no Engine effects or execution grants."""
from .resource_journal import ResourceJournal, ResourceJournalError


class VolumeJournalError(ResourceJournalError):
    """Only static volume journal diagnostics."""


class VolumeJournal(ResourceJournal):
    def prepare(self, plan, stack, catalog, policy, resource_id):
        raise VolumeJournalError('invalid_volume_binding')

    def begin_observation(self, resource_id, expected_revision, **source):
        raise VolumeJournalError('invalid_volume_binding')

    def bind(self, resource_id, expected_revision, **source):
        raise VolumeJournalError('invalid_volume_binding')
