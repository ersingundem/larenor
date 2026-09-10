"""Fixed-endpoint authenticated Music Assistant player runtime."""

import hashlib
import http.client
import json
import math
import re
import threading
import time

from pydantic import ValidationError

from .music_playback_models import (
    MusicPlaybackReadback, MusicPlaybackWorkerResult,
    PrivateMusicPlaybackAction, PrivateMusicPlaybackAuthority,
    PrivateMusicAssistantServiceBinding,
    VerifiedMusicPlayer,
)
from .music_target_transport import (
    MAX_MUSIC_ASSISTANT_FRAME, MusicAssistantHTTPConnection,
    decode_music_assistant_frame,
)


class MusicPlaybackRuntimeError(Exception):
    """Static error that never carries an upstream body or credential."""


class MusicPlaybackRuntime:
    def __init__(self, connection_factory=None):
        self._uses_default_connection = connection_factory is None
        self.connection_factory = connection_factory or (
            lambda timeout: http.client.HTTPConnection(
                '127.0.0.1', 8095, timeout=timeout))

    @staticmethod
    def _check(deadline, cancelled):
        if (type(deadline) not in (int, float) or not math.isfinite(deadline)
                or time.monotonic() >= deadline or cancelled.is_set()):
            raise MusicPlaybackRuntimeError('music_playback_cancelled')

    def _connection(self, binding, timeout):
        if binding is None:
            return self.connection_factory(timeout)
        if self._uses_default_connection:
            return MusicAssistantHTTPConnection(
                binding.endpoint, binding.pinnedPeer, timeout)
        return self.connection_factory(timeout)

    def _command(self, request_id, token, command, args, deadline, cancelled,
                 binding=None):
        self._check(deadline, cancelled)
        message_id = request_id + '-' + hashlib.sha256(
            command.encode('ascii')).hexdigest()[:16]
        connection = self._connection(
            binding, max(.001, deadline - time.monotonic()))
        try:
            connection.request('POST', '/api', body=json.dumps({
                'message_id': message_id, 'command': command, 'args': args,
            }, separators=(',', ':'), allow_nan=False).encode(), headers={
                'Authorization': 'Bearer ' + token,
                'Content-Type': 'application/json', 'Accept': 'application/json',
                'Connection': 'close',
            })
            response = connection.getresponse()
            raw = response.read(MAX_MUSIC_ASSISTANT_FRAME + 1)
            if response.status != 200 or len(raw) > MAX_MUSIC_ASSISTANT_FRAME:
                raise ValueError()
            # Music Assistant's authenticated POST /api returns the command
            # result directly; the message_id only belongs to CommandMessage.
            # Source: music-assistant/server webserver controller.
            parsed = decode_music_assistant_frame(raw)
            self._check(deadline, cancelled)
            return parsed
        except MusicPlaybackRuntimeError:
            raise
        except Exception:
            raise MusicPlaybackRuntimeError(
                'music_playback_upstream_unavailable') from None
        finally:
            try:
                connection.close()
            except Exception:
                pass

    @staticmethod
    def _player(raw, queue_ids):
        try:
            if type(raw) is not dict:
                raise ValueError()
            player_id, provider = raw['player_id'], raw['provider']
            group = raw.get('group_members') or []
            if type(group) is not list:
                raise ValueError()
            device = raw.get('device_info') or {}
            if type(device) is not dict:
                raise ValueError()
            model = str(device.get('model') or '').lower()
            domain = provider.split('--', 1)[0]
            airplay = domain == 'airplay'
            chromecast = domain in {'chromecast', 'cast'}
            if group and airplay:
                kind = 'airplay_group'
            elif group and chromecast:
                kind = 'chromecast_group'
            elif airplay and 'homepod' in model:
                kind = 'homepod'
            elif airplay:
                kind = 'airplay'
            elif chromecast:
                kind = 'chromecast'
            else:
                kind = 'other'
            source = raw.get('active_source')
            queue_id = (source if source in queue_ids else player_id
                        if player_id in queue_ids else None)
            features = {str(item).lower() for item in
                        raw.get('supported_features', [])}
            capabilities = ['play', 'stop']
            if 'pause' in features:
                capabilities.append('pause')
            if 'next_previous' in features:
                capabilities.append('next_previous')
            if 'seek' in features:
                capabilities.append('seek')
            if raw.get('volume_control') not in (None, 'none'):
                capabilities.append('volume_set')
            if raw.get('mute_control') not in (None, 'none'):
                capabilities.append('volume_mute')
            if queue_id is not None:
                capabilities.append('queue')
            state = str(raw.get('playback_state', 'idle')).lower()
            if state not in {'idle', 'playing', 'paused'}:
                state = 'idle'
            return VerifiedMusicPlayer(
                playerId=player_id, name=raw['name'], provider=provider,
                targetKind=kind, available=raw['available'],
                enabled=raw['enabled'], playbackState=state,
                volumeLevel=raw.get('volume_level'),
                muted=raw.get('volume_muted'), groupMembers=group,
                queueId=queue_id, capabilities=capabilities)
        except (KeyError, TypeError, ValueError, ValidationError):
            raise MusicPlaybackRuntimeError(
                'music_player_readback_changed') from None

    @staticmethod
    def _queue_ids(raw):
        try:
            if type(raw) is not list or len(raw) > 256:
                raise ValueError()
            values = []
            for item in raw:
                if type(item) is not dict or 'queue_id' not in item:
                    raise ValueError()
                identifier = item['queue_id']
                if (type(identifier) is not str or re.fullmatch(
                        r'[A-Za-z0-9][A-Za-z0-9_.:\-]{0,127}',
                        identifier) is None):
                    raise ValueError()
                values.append(identifier)
            if len(values) != len(set(values)):
                raise ValueError()
            return set(values)
        except (TypeError, ValueError):
            raise MusicPlaybackRuntimeError(
                'music_player_readback_changed') from None

    def read(self, authority, *, deadline, cancelled=None):
        if type(authority) is not PrivateMusicPlaybackAuthority:
            raise MusicPlaybackRuntimeError('invalid_music_playback_action')
        cancelled = threading.Event() if cancelled is None else cancelled
        queues = self._command(
            authority.installationId, authority.token, 'player_queues/all', {},
            deadline, cancelled)
        players = self._command(
            authority.installationId, authority.token, 'players/all', {
                'return_unavailable': True, 'return_disabled': False,
                'return_protocol_players': False}, deadline, cancelled)
        if type(queues) is not list or type(players) is not list:
            raise MusicPlaybackRuntimeError('music_player_readback_changed')
        try:
            queue_ids = self._queue_ids(queues)
            return MusicPlaybackReadback(
                players=[self._player(item, queue_ids) for item in players])
        except ValidationError:
            raise MusicPlaybackRuntimeError(
                'music_player_readback_changed') from None

    def execute(self, action, *, deadline, cancelled=None, binding=None):
        if type(action) is not PrivateMusicPlaybackAction:
            raise MusicPlaybackRuntimeError('invalid_music_playback_action')
        cancelled = threading.Event() if cancelled is None else cancelled
        request = action.request
        if binding is not None:
            if (type(binding) is not PrivateMusicAssistantServiceBinding
                    or binding.installationId != request.installationId
                    or binding.installationRevision
                    != request.expectedInstallationRevision
                    or binding.coreRevision != request.expectedCoreRevision
                    or binding.token != action.token):
                raise MusicPlaybackRuntimeError('invalid_music_playback_action')
            info = self._command(
                request.requestId, action.token, 'info', {}, deadline,
                cancelled, binding)
            if (type(info) is not dict or set(info) != {
                    'server_id', 'server_version', 'schema_version'}
                    or info['server_id'] != binding.serverId
                    or info['server_version'] != binding.serverVersion
                    or info['schema_version'] != binding.schemaVersion):
                raise MusicPlaybackRuntimeError('music_service_binding_changed')
        before_raw = self._command(
            request.requestId, action.token, 'players/get', {
                'player_id': request.targetId, 'raise_unavailable': True},
            deadline, cancelled, binding)
        queues = self._command(
            request.requestId, action.token, 'player_queues/all', {}, deadline,
            cancelled, binding)
        if type(queues) is not list:
            raise MusicPlaybackRuntimeError('music_player_readback_changed')
        queue_ids = self._queue_ids(queues)
        before = self._player(before_raw, queue_ids)
        if (not before.available or not before.enabled
                or before.groupMembers != request.expectedGroupMembers
                or before.provider != request.expectedProvider
                or before.targetKind != request.expectedTargetKind
                or before.queueId != request.expectedQueueId):
            raise MusicPlaybackRuntimeError('music_player_changed')
        expected_capability = {
            'play': 'play', 'pause': 'pause', 'resume': 'play', 'stop': 'stop',
            'seek': 'seek',
            'next': 'next_previous', 'previous': 'next_previous',
            'volume': 'volume_set', 'mute': 'volume_mute',
            'queue_add': 'queue', 'queue_replace': 'queue',
            'queue_clear': 'queue',
        }[request.operation]
        if expected_capability not in before.capabilities:
            raise MusicPlaybackRuntimeError('music_player_changed')
        commands = {
            'play': ('players/cmd/play', {'player_id': request.targetId}),
            'pause': ('players/cmd/pause', {'player_id': request.targetId}),
            'resume': ('players/cmd/resume', {'player_id': request.targetId}),
            'stop': ('players/cmd/stop', {'player_id': request.targetId}),
            'seek': ('players/cmd/seek', {
                'player_id': request.targetId,
                'position': request.seekPosition}),
            'next': ('players/cmd/next', {'player_id': request.targetId}),
            'previous': ('players/cmd/previous', {'player_id': request.targetId}),
            'volume': ('players/cmd/volume_set', {
                'player_id': request.targetId,
                'volume_level': request.volumeLevel}),
            'mute': ('players/cmd/volume_mute', {
                'player_id': request.targetId, 'muted': request.muted}),
            'queue_add': ('player_queues/play_media', {
                'queue_id': before.queueId, 'media': request.mediaUris,
                'option': 'add', 'radio_mode': False}),
            'queue_replace': ('player_queues/play_media', {
                'queue_id': before.queueId, 'media': request.mediaUris,
                'option': 'replace', 'radio_mode': False}),
            'queue_clear': ('player_queues/clear', {
                'queue_id': before.queueId, 'skip_stop': False}),
        }
        command, args = commands[request.operation]
        if request.operation.startswith('queue_') and before.queueId is None:
            raise MusicPlaybackRuntimeError('music_player_changed')
        result = self._command(
            request.requestId, action.token, command, args, deadline, cancelled,
            binding)
        if result is not None:
            raise MusicPlaybackRuntimeError('music_playback_upstream_changed')
        after_raw = self._command(
            request.requestId, action.token, 'players/get', {
                'player_id': request.targetId, 'raise_unavailable': True},
            deadline, cancelled, binding)
        after = self._player(after_raw, queue_ids)
        if (after.groupMembers != request.expectedGroupMembers
                or after.provider != request.expectedProvider
                or after.targetKind != request.expectedTargetKind
                or after.queueId != request.expectedQueueId):
            raise MusicPlaybackRuntimeError('music_player_changed')
        return MusicPlaybackWorkerResult(state='succeeded', target=after)
