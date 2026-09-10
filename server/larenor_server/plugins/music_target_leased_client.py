"""Core-side lease issuance in front of the secret-free worker IPC."""

import time

from .music_target_effect_models import MusicTargetEffectEnvelope
from .music_target_lease import MusicTargetCredentialLeaseError


class LeasedMusicTargetWorkerClient:
    def __init__(self, delegate, store, resolver, *, clock=time.time,
                 health_guard=None, health_binding=None):
        if not callable(resolver) or not callable(clock):
            raise MusicTargetCredentialLeaseError('music_target_lease_unavailable')
        self.delegate, self.store = delegate, store
        self.resolver, self.clock = resolver, clock
        self.health_guard, self.health_binding = health_guard, health_binding

    def _health(self):
        if self.health_guard is not None:
            self.health_guard.check(self.health_binding)

    def execute_music_target_effect(self, action, *, deadline, gate):
        if type(action) is not MusicTargetEffectEnvelope or gate() is not True:
            raise MusicTargetCredentialLeaseError('music_target_lease_invalid')
        remaining = deadline - time.monotonic()
        if not 0 < remaining <= 5:
            raise MusicTargetCredentialLeaseError('music_target_lease_invalid')
        self._health()
        binding = self.resolver(action)
        self.store.issue(
            action, binding,
            expires_at=self.clock() + min(remaining, 5))
        try:
            self._health()
            if gate() is not True or self.resolver(action) != binding:
                raise MusicTargetCredentialLeaseError('music_target_lease_invalid')
            result = self.delegate.execute_music_target_effect(
                action, deadline=deadline, gate=gate)
            self._health()
            if gate() is not True or self.resolver(action) != binding:
                raise MusicTargetCredentialLeaseError('music_target_lease_invalid')
            return result
        finally:
            self.store.retire(action.executionId)
