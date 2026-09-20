"""Fixed-endpoint authenticated Music Assistant player runtime."""

import http.client
import json
import math
import threading
import time

from pydantic import ValidationError

from .music_playback_models import (
    MusicCatalogItem, MusicCatalogWorkerResult, MusicPlaybackReadback,
    MusicPlaybackWorkerResult, PrivateMusicCatalogAction,
    PrivateMusicPlaybackAction, PrivateMusicPlaybackAuthority,
    VerifiedMusicPlayer, VerifiedMusicQueue,
)


class MusicPlaybackRuntimeError(Exception):
    """Static error that never carries an upstream body or credential."""


class MusicPlaybackRuntime:
    def __init__(self, connection_factory=None):
        self.connection_factory = connection_factory or (
            lambda timeout: http.client.HTTPConnection(
                '127.0.0.1', 8095, timeout=timeout))

    @staticmethod
    def _check(deadline, cancelled):
        if (type(deadline) not in (int, float) or not math.isfinite(deadline)
                or time.monotonic() >= deadline or cancelled.is_set()):
            raise MusicPlaybackRuntimeError('music_playback_cancelled')

    def _command(self, request_id, token, command, args, deadline, cancelled):
        self._check(deadline, cancelled)
        message_id = request_id + '-' + command.rsplit('/', 1)[-1]
        connection = self.connection_factory(
            max(.001, deadline - time.monotonic()))
        try:
            connection.request('POST', '/api', body=json.dumps({
                'message_id': message_id, 'command': command, 'args': args,
            }, separators=(',', ':'), allow_nan=False).encode(), headers={
                'Authorization': 'Bearer ' + token,
                'Content-Type': 'application/json', 'Accept': 'application/json',
                'Connection': 'close',
            })
            response = connection.getresponse()
            raw = response.read(262145)
            if response.status != 200 or len(raw) > 262144:
                raise ValueError()
            # Music Assistant 2.10.4 POST /api returns the serialized command
            # result directly. Result envelopes belong to its WebSocket
            # transport and accepting only that shape makes every native HTTP
            # read fail after a successful bootstrap.
            parsed = json.loads(raw)
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
            protocol = provider.split('--', 1)[0]
            airplay = protocol == 'airplay'
            cast = protocol in {'cast', 'chromecast'}
            if group:
                kind = ('airplay_group' if airplay else 'cast_group'
                        if cast else 'group')
            elif airplay and 'homepod' in model:
                kind = 'homepod'
            elif airplay:
                kind = 'airplay'
            elif cast:
                kind = 'cast'
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
            if 'seek' in features and queue_id is not None:
                capabilities.append('seek')
            if 'next_previous' in features:
                capabilities.append('next_previous')
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
                queueId=queue_id, positionSeconds=raw.get('elapsed_time'),
                capabilities=capabilities)
        except (KeyError, TypeError, ValueError, ValidationError):
            raise MusicPlaybackRuntimeError(
                'music_player_readback_changed') from None

    @staticmethod
    def _queue(raw):
        try:
            if type(raw) is not dict:
                raise ValueError()
            active = raw.get('active', False)
            if type(active) is not bool:
                raise ValueError()
            count = raw.get('items')
            if type(count) is not int:
                count = raw.get('items_count', 0)
            current = raw.get('current_item')
            if current is not None and type(current) is not dict:
                raise ValueError()
            media = None if current is None else current.get('media_item')
            if media is not None and type(media) is not dict:
                raise ValueError()
            uri = None if current is None else (
                current.get('uri') or (media or {}).get('uri'))
            return VerifiedMusicQueue(
                queueId=raw['queue_id'], active=active,
                itemCount=count, currentItemUri=uri,
                positionSeconds=raw.get('elapsed_time', 0))
        except (KeyError, TypeError, ValueError, ValidationError):
            raise MusicPlaybackRuntimeError(
                'music_queue_readback_changed') from None

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
            queue_ids = {item['queue_id'] for item in queues
                         if type(item) is dict and type(item.get('queue_id')) is str}
            return MusicPlaybackReadback(
                players=[self._player(item, queue_ids) for item in players],
                queues=[self._queue(item) for item in queues])
        except ValidationError:
            raise MusicPlaybackRuntimeError(
                'music_player_readback_changed') from None

    def search(self, action, *, deadline, cancelled=None):
        if type(action) is not PrivateMusicCatalogAction:
            raise MusicPlaybackRuntimeError('invalid_music_playback_action')
        cancelled = threading.Event() if cancelled is None else cancelled
        request = action.request
        raw = self._command(
            request.requestId, action.token, 'music/search', {
                'search_query': request.query,
                'media_types': request.mediaTypes,
                'limit': request.limit,
                'library_only': request.libraryOnly,
                'providers': [request.providerInstanceId],
            }, deadline, cancelled)
        if type(raw) is not dict:
            raise MusicPlaybackRuntimeError('music_catalog_readback_changed')
        items = []
        allowed = request.mediaTypes or [
            'artist', 'album', 'track', 'playlist', 'radio', 'audiobook',
            'podcast']
        result_keys = {
            'artist': 'artists', 'album': 'albums', 'track': 'tracks',
            'playlist': 'playlists', 'radio': 'radio',
            'audiobook': 'audiobooks', 'podcast': 'podcasts',
        }
        try:
            for media_type in allowed:
                values = raw.get(result_keys[media_type], [])
                if type(values) is not list:
                    raise ValueError()
                for value in values:
                    if type(value) is not dict:
                        raise ValueError()
                    provider = value.get('provider')
                    if provider not in {
                            request.providerInstanceId,
                            request.providerDomain}:
                        continue
                    artists = []
                    for artist in value.get('artists') or []:
                        name = (artist.get('name') if type(artist) is dict
                                else artist)
                        if type(name) is not str:
                            raise ValueError()
                        artists.append(name)
                    items.append(MusicCatalogItem(
                        uri=value['uri'], name=value['name'],
                        mediaType=media_type,
                        providerInstanceId=request.providerInstanceId,
                        artists=artists))
                    if len(items) > request.limit:
                        raise ValueError()
            return MusicCatalogWorkerResult(items=items)
        except (KeyError, TypeError, ValueError, ValidationError):
            raise MusicPlaybackRuntimeError(
                'music_catalog_readback_changed') from None

    def execute(self, action, *, deadline, cancelled=None):
        if type(action) is not PrivateMusicPlaybackAction:
            raise MusicPlaybackRuntimeError('invalid_music_playback_action')
        cancelled = threading.Event() if cancelled is None else cancelled
        request = action.request
        before_raw = self._command(
            request.requestId, action.token, 'players/get', {
                'player_id': request.targetId, 'raise_unavailable': True},
            deadline, cancelled)
        queues = self._command(
            request.requestId, action.token, 'player_queues/all', {}, deadline,
            cancelled)
        if type(queues) is not list:
            raise MusicPlaybackRuntimeError('music_player_readback_changed')
        queue_ids = {item['queue_id'] for item in queues
                     if type(item) is dict and type(item.get('queue_id')) is str}
        before = self._player(before_raw, queue_ids)
        queue_map = {item['queue_id']: self._queue(item) for item in queues
                     if type(item) is dict and type(item.get('queue_id')) is str}
        before_queue = queue_map.get(before.queueId)
        if (not before.available or not before.enabled
                or before.groupMembers != request.expectedGroupMembers
                or before.provider != request.expectedProvider
                or before.targetKind != request.expectedTargetKind
                or before.queueId != request.expectedQueueId):
            raise MusicPlaybackRuntimeError('music_player_changed')
        expected_capability = {
            'play': 'play', 'pause': 'pause', 'seek': 'seek', 'stop': 'stop',
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
            'seek': ('player_queues/seek', {
                'queue_id': before.queueId,
                'position': request.positionSeconds}),
            'stop': ('players/cmd/stop', {'player_id': request.targetId}),
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
            request.requestId, action.token, command, args, deadline, cancelled)
        if result is not None:
            raise MusicPlaybackRuntimeError('music_playback_upstream_changed')
        after_raw = self._command(
            request.requestId, action.token, 'players/get', {
                'player_id': request.targetId, 'raise_unavailable': True},
            deadline, cancelled)
        after = self._player(after_raw, queue_ids)
        if (after.groupMembers != request.expectedGroupMembers
                or after.provider != request.expectedProvider
                or after.targetKind != request.expectedTargetKind
                or after.queueId != request.expectedQueueId):
            raise MusicPlaybackRuntimeError('music_player_changed')
        after_queue = None
        if request.operation == 'seek' or request.operation.startswith('queue_'):
            after_queues = self._command(
                request.requestId, action.token, 'player_queues/all', {},
                deadline, cancelled)
            if type(after_queues) is not list:
                raise MusicPlaybackRuntimeError('music_queue_readback_changed')
            after_queue = next((self._queue(item) for item in after_queues
                                if type(item) is dict
                                and item.get('queue_id') == before.queueId), None)
            if after_queue is None:
                raise MusicPlaybackRuntimeError('music_queue_readback_changed')
        verified = True
        if request.operation == 'play':
            verified = after.playbackState == 'playing'
        elif request.operation == 'pause':
            verified = after.playbackState == 'paused'
        elif request.operation == 'seek':
            verified = (after_queue is not None
                        and abs(after_queue.positionSeconds
                                - request.positionSeconds) <= 2)
        elif request.operation == 'queue_add':
            verified = (before_queue is not None and after_queue is not None
                        and after_queue.itemCount > before_queue.itemCount)
        elif request.operation == 'queue_replace':
            verified = (after_queue is not None
                        and after_queue.itemCount == len(request.mediaUris)
                        and after_queue.currentItemUri in request.mediaUris)
        elif request.operation == 'queue_clear':
            verified = (after_queue is not None and after_queue.itemCount == 0
                        and after_queue.currentItemUri is None)
        if not verified:
            raise MusicPlaybackRuntimeError('music_playback_readback_unverified')
        return MusicPlaybackWorkerResult(
            state='succeeded', target=after, queue=after_queue)
