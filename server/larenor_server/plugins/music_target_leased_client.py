"""Core-side lease issuance in front of the secret-free worker IPC."""

import time

from .music_target_effect_models import MusicTargetEffectEnvelope
from .music_target_lease import MusicTargetCredentialLeaseError


class LeasedMusicTargetWorkerClient:
    def __init__(self, delegate, store, resolver, *, clock=time.time):
        if not callable(resolver) or not callable(clock):
            raise MusicTargetCredentialLeaseError('music_target_lease_unavailable')
        self.delegate, self.store = delegate, store
        self.resolver, self.clock = resolver, clock

    def execute_music_target_effect(self, action, *, deadline, gate):
        if type(action) is not MusicTargetEffectEnvelope or gate() is not True:
            raise MusicTargetCredentialLeaseError('music_target_lease_invalid')
        remaining = deadline - time.monotonic()
        if not 0 < remaining <= 5:
            raise MusicTargetCredentialLeaseError('music_target_lease_invalid')
        binding = self.resolver(action)
        self.store.issue(
            action, binding,
            expires_at=self.clock() + min(remaining, 5))
        try:
            if gate() is not True:
                raise MusicTargetCredentialLeaseError('music_target_lease_invalid')
            return self.delegate.execute_music_target_effect(
                action, deadline=deadline, gate=gate)
        finally:
            self.store.retire(action.executionId)
