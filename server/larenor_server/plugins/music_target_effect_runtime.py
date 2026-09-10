"""Lease-consuming Music Assistant target effect runtime."""

from .music_playback_models import (
    MusicPlaybackCommandRequest, PrivateMusicPlaybackAction,
)
from .music_target_authority_models import MusicTarget
from .music_target_effect_models import MusicTargetEffectResult


class MusicTargetEffectRuntime:
    def __init__(self, playback_runtime, lease_store):
        self.playback_runtime, self.lease_store = playback_runtime, lease_store

    @staticmethod
    def _kind(target):
        if target.homePod:
            return 'homepod'
        if target.transport == 'airplay':
            return 'airplay_group' if target.kind == 'group' else 'airplay'
        return 'chromecast_group' if target.kind == 'group' else 'chromecast'

    @staticmethod
    def _target(player):
        if player.targetKind in {'homepod', 'airplay'}:
            transport, kind = 'airplay', 'device'
        elif player.targetKind == 'airplay_group':
            transport, kind = 'airplay', 'group'
        elif player.targetKind == 'chromecast':
            transport, kind = 'chromecast', 'device'
        elif player.targetKind == 'chromecast_group':
            transport, kind = 'chromecast', 'group'
        else:
            raise ValueError('music_target_effect_readback_changed')
        return MusicTarget(
            id=player.playerId, name=player.name, provider=player.provider,
            transport=transport, kind=kind, homePod=player.targetKind == 'homepod',
            available=player.available, enabled=player.enabled,
            playbackState=player.playbackState, volumeLevel=player.volumeLevel,
            muted=player.muted, groupMemberIds=player.groupMembers,
            queueId=player.queueId, capabilities=player.capabilities)

    def execute(self, envelope, *, deadline, cancelled=None):
        binding = self.lease_store.consume(envelope)
        target = envelope.target
        request = MusicPlaybackCommandRequest(
            requestId=envelope.executionId,
            installationId=envelope.installationId,
            expectedInstallationRevision=envelope.installationRevision,
            expectedCoreRevision=envelope.coreRevision,
            expectedPlayerRevision=envelope.playerRevision,
            targetId=target.id, expectedProvider=target.provider,
            expectedTargetKind=self._kind(target),
            expectedQueueId=target.queueId,
            expectedGroupMembers=target.groupMemberIds,
            operation=envelope.operation, volumeLevel=envelope.volumeLevel,
            muted=envelope.muted, seekPosition=envelope.seekPosition,
            mediaUris=envelope.mediaUris)
        result = self.playback_runtime.execute(
            PrivateMusicPlaybackAction(request=request, token=binding.token),
            deadline=deadline, cancelled=cancelled, binding=binding)
        observed = self._target(result.target)
        if (observed.id != target.id or observed.provider != target.provider
                or observed.transport != target.transport
                or observed.kind != target.kind or observed.homePod != target.homePod
                or observed.groupMemberIds != target.groupMemberIds
                or observed.queueId != target.queueId):
            raise ValueError('music_target_effect_readback_changed')
        return MusicTargetEffectResult(
            state='succeeded', executionId=envelope.executionId,
            commandId=envelope.commandId, requestId=envelope.requestId,
            target=observed)

    def execute_music_target_effect(self, action, *, deadline, gate):
        if gate() is not True:
            raise ValueError('music_target_effect_authority_changed')
        result = self.execute(action, deadline=deadline)
        if gate() is not True:
            raise ValueError('music_target_effect_authority_changed')
        return result
