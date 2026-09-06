"""Compiling, fail-closed SQLite composition boundary for runtime RED tests."""


class VolumeObservationError(Exception):
    def __init__(self, code='invalid_volume_observation'):
        self.code = 'invalid_volume_observation'
        super().__init__(self.code)


class JournaledVolumeObservations:
    def __init__(self, journal, reader):
        pass

    def observe(self, plan, stack, catalog, policy, resource_id, *, cancelled=None):
        raise VolumeObservationError()
