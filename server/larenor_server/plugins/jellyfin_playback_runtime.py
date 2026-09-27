"""Strict Jellyfin remote-play protocol over preverified private streams."""

import base64
import hashlib
import json
import math
import re
import socket
import time
from urllib.parse import urlencode

from pydantic import ValidationError

from ..services.transport import ProbeTransportError, _request_bytes
from .jellyfin_startup import (
    JellyfinStartupError,
    _StartupReader,
    _headers,
    _json,
    _response,
)
from .media_playback_models import (
    MediaPlaybackReadback,
    MediaPlaybackTarget,
    MediaPlaybackWorkerResult,
    OfflineMediaChunkReadback,
    MediaSegment,
    MediaSegmentsReadback,
    PrivateMediaPlaybackAction,
)


_ID = re.compile(r'[0-9a-f]{32}\Z')
_API_KEY = re.compile(r'[A-Za-z0-9_-]{32,128}\Z')
_QUALITY_TOKEN = re.compile(r'[A-Za-z0-9][A-Za-z0-9_.+,\-]{0,63}\Z')
_GUID = re.compile(
    r'(?:[0-9a-fA-F]{32}|[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-'
    r'[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\Z')
_SEGMENT_TYPES = {'Unknown', 'Intro', 'Outro', 'Recap', 'Preview', 'Commercial'}
_BASE_AUTH = ('MediaBrowser Client="Larenor%20Core", Device="Larenor%20Core", '
              'DeviceId="{device}", Version="0.1.0", Token={token}')


class JellyfinPlaybackRuntimeError(Exception):
    """One static error without upstream payloads or credentials."""

    def __init__(self, code='jellyfin_playback_unavailable', *,
                 uncertain_effect=False):
        self.code = code
        self.uncertain_effect = uncertain_effect is True
        super().__init__(code)


class JellyfinPlaybackProtocol:
    """Translate exact Session API bytes into revisioned Larenor readback."""

    def __init__(self, *, revision_seed=None):
        if revision_seed is None:
            revision_seed = int.from_bytes(__import__('secrets').token_bytes(6), 'big') << 10
        if (type(revision_seed) is not int or not 1 <= revision_seed < 2**63 - 65536):
            raise JellyfinPlaybackRuntimeError('invalid_jellyfin_playback_runtime')
        self._seed = revision_seed
        self._installations = {}

    def __repr__(self):
        return 'JellyfinPlaybackProtocol(<private>)'

    @staticmethod
    def _inputs(api_key, installation_id, deadline):
        if (type(api_key) is not str or _API_KEY.fullmatch(api_key) is None
                or type(installation_id) is not str
                or _ID.fullmatch(installation_id) is None
                or type(deadline) not in (int, float) or type(deadline) is bool
                or not math.isfinite(deadline) or time.monotonic() >= deadline):
            raise JellyfinPlaybackRuntimeError('invalid_jellyfin_playback_request')

    @staticmethod
    def _request(connection, method, path, authorization, deadline, *, status,
                 effect=False):
        reader = _StartupReader(connection, deadline)
        attempted = False
        try:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise ValueError()
            connection.settimeout(remaining)
            request = _request_bytes(
                method, path, 'jellyfin', {
                    'Accept': 'application/json',
                    'Authorization': authorization,
                }, None,
            )
            attempted = True
            connection.sendall(request)
            observed_status, body, closed = _response(reader, 262144)
            if observed_status != status or closed is not True:
                raise ValueError()
            if reader.receive(1) != b'':
                raise ValueError()
            return body
        except JellyfinPlaybackRuntimeError:
            raise
        except (OSError, ValueError, TypeError, ProbeTransportError,
                socket.timeout):
            raise JellyfinPlaybackRuntimeError(
                uncertain_effect=effect and attempted) from None
        finally:
            try:
                connection.close()
            except Exception:
                pass

    @staticmethod
    def _segment_request(connection, path, authorization, deadline):
        reader = _StartupReader(connection, deadline)
        try:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise ValueError()
            connection.settimeout(remaining)
            connection.sendall(_request_bytes(
                'GET', path, 'jellyfin', {
                    'Accept': 'application/json',
                    'Authorization': authorization,
                }, None,
            ))
            status, body, closed = _response(reader, 65536)
            if status not in {200, 400, 404} or closed is not True:
                raise ValueError()
            if reader.receive(1) != b'':
                raise ValueError()
            return status, body
        except (OSError, ValueError, TypeError, ProbeTransportError,
                socket.timeout):
            raise JellyfinPlaybackRuntimeError() from None
        finally:
            try:
                connection.close()
            except Exception:
                pass

    @staticmethod
    def _close(connections):
        for connection in connections:
            try:
                connection.close()
            except Exception:
                pass

    @classmethod
    def _pre_effect(cls, connections, deadline, gate):
        try:
            if not callable(gate) or gate() is not True:
                raise ValueError()
            if time.monotonic() >= deadline:
                raise ValueError()
        except Exception:
            cls._close(connections)
            raise JellyfinPlaybackRuntimeError(
                'jellyfin_playback_authority_changed') from None

    @staticmethod
    def _quality_token(value):
        if value is None:
            return None
        if type(value) is not str or _QUALITY_TOKEN.fullmatch(value) is None:
            raise ValueError()
        return value

    @staticmethod
    def _quality_bitrate(value):
        if value is None:
            return None
        if (type(value) is not int
                or not 1 <= value <= 1_000_000_000):
            raise ValueError()
        return value

    @classmethod
    def _quality_observation(cls, state, now, raw_transcoding):
        play_method = state.get('PlayMethod')
        if play_method is None:
            method = 'unknown'
        else:
            methods = {
                'DirectPlay': 'direct_play',
                'DirectStream': 'direct_stream',
                'Transcode': 'transcode',
            }
            if type(play_method) is not str or play_method not in methods:
                raise ValueError()
            method = methods[play_method]

        streams = now.get('MediaStreams')
        if streams is None:
            streams = []
        if type(streams) is not list or len(streams) > 128:
            raise ValueError()
        video_codecs, audio_codecs, video_ranges = set(), set(), set()
        for stream in streams:
            if type(stream) is not dict:
                raise ValueError()
            stream_type = stream.get('Type')
            if (type(stream_type) is not str or not 1 <= len(stream_type) <= 32
                    or any(ord(char) < 32 or ord(char) == 127
                           for char in stream_type)):
                raise ValueError()
            if stream_type not in {'Video', 'Audio'}:
                continue
            codec = cls._quality_token(stream.get('Codec'))
            if codec is not None:
                (video_codecs if stream_type == 'Video'
                 else audio_codecs).add(codec)
            if stream_type == 'Video':
                video_range = cls._quality_token(stream.get('VideoRange'))
                if video_range is not None:
                    video_ranges.add(video_range)
        if any(len(values) > 8 for values in (
                video_codecs, audio_codecs, video_ranges)):
            raise ValueError()

        transcoding = None
        if raw_transcoding is not None:
            if type(raw_transcoding) is not dict:
                raise ValueError()
            reasons = raw_transcoding.get('TranscodeReasons')
            if reasons is None:
                reasons = []
            if (type(reasons) is not list or len(reasons) > 16
                    or any(cls._quality_token(reason) is None
                           for reason in reasons)
                    or len(reasons) != len(set(reasons))):
                raise ValueError()
            transcoding = {
                'container': cls._quality_token(
                    raw_transcoding.get('Container')),
                'videoCodec': cls._quality_token(
                    raw_transcoding.get('VideoCodec')),
                'audioCodec': cls._quality_token(
                    raw_transcoding.get('AudioCodec')),
                'bitrate': cls._quality_bitrate(
                    raw_transcoding.get('Bitrate')),
                'reasons': reasons,
            }
        return {
            'schemaVersion': 1,
            'itemId': now['Id'],
            'playMethod': method,
            'source': {
                'container': cls._quality_token(now.get('Container')),
                'bitrate': cls._quality_bitrate(now.get('Bitrate')),
                'videoCodecs': sorted(video_codecs),
                'audioCodecs': sorted(audio_codecs),
                'videoRanges': sorted(video_ranges),
            },
            'transcoding': transcoding,
        }

    @staticmethod
    def _target(raw):
        if type(raw) is not dict:
            raise ValueError()
        identifier = raw.get('Id')
        name = raw.get('DeviceName')
        available = raw.get('SupportsMediaControl')
        commands = raw.get('SupportedCommands')
        state = raw.get('PlayState')
        now = raw.get('NowPlayingItem')
        if (type(identifier) is not str or _ID.fullmatch(identifier) is None
                or type(name) is not str or not 1 <= len(name) <= 128
                or name != name.strip()
                or any(ord(char) < 32 or ord(char) == 127 for char in name)
                or type(available) is not bool
                or type(commands) is not list
                or any(type(command) is not str for command in commands)
                or len(commands) != len(set(commands))
                or 'Play' not in commands
                or type(state) is not dict):
            raise ValueError()
        ticks = state.get('PositionTicks')
        if (type(ticks) is not int
                or not 0 <= ticks <= 86_400_000_000_000):
            raise ValueError()
        current = None
        quality = None
        if now is not None:
            if (type(now) is not dict or type(now.get('Id')) is not str
                    or _ID.fullmatch(now['Id']) is None):
                raise ValueError()
            current = now['Id']
            quality = JellyfinPlaybackProtocol._quality_observation(
                state, now, raw.get('TranscodingInfo'))
        return {
            'targetId': identifier,
            'name': name,
            'available': available,
            'currentItemId': current,
            'positionSeconds': ticks // 10_000_000,
            'qualityObservation': quality,
        }

    @classmethod
    def _parse(cls, body):
        raw = _json(body)
        if type(raw) is not list or not 1 <= len(raw) <= 64:
            raise ValueError()
        targets = [cls._target(item) for item in raw]
        if len({item['targetId'] for item in targets}) != len(targets):
            raise ValueError()
        targets.sort(key=lambda item: item['targetId'])
        return targets

    @staticmethod
    def _digest(value):
        return hashlib.sha256(json.dumps(
            value, sort_keys=True, separators=(',', ':'), allow_nan=False,
        ).encode()).hexdigest()

    def _observe(self, installation_id, targets):
        fingerprint = self._digest(targets)
        state = self._installations.get(installation_id)
        if state is None:
            state = {
                'revision': self._seed,
                'fingerprint': fingerprint,
                'targets': {},
            }
            self._installations[installation_id] = state
        elif state['fingerprint'] != fingerprint:
            state['revision'] += 1
            state['fingerprint'] = fingerprint
        target_states = state['targets']
        result = []
        current_ids = set()
        for target in targets:
            target_id = target['targetId']
            current_ids.add(target_id)
            target_fingerprint = self._digest(target)
            target_state = target_states.get(target_id)
            if target_state is None:
                target_state = {
                    'revision': self._seed,
                    'fingerprint': target_fingerprint,
                }
                target_states[target_id] = target_state
            elif target_state['fingerprint'] != target_fingerprint:
                target_state['revision'] += 1
                target_state['fingerprint'] = target_fingerprint
            result.append(MediaPlaybackTarget(
                **target, targetRevision=target_state['revision']))
        for target_id in set(target_states) - current_ids:
            del target_states[target_id]
        return MediaPlaybackReadback(
            playbackRevision=state['revision'], targets=result)

    def read(self, connection, *, api_key, installation_id, deadline):
        self._inputs(api_key, installation_id, deadline)
        authorization = _BASE_AUTH.format(
            device=installation_id, token=api_key)
        body = self._request(
            connection, 'GET', '/Sessions', authorization, deadline, status=200)
        try:
            return self._observe(installation_id, self._parse(body))
        except (ValueError, TypeError, ValidationError, JellyfinStartupError,
                JellyfinPlaybackRuntimeError):
            raise JellyfinPlaybackRuntimeError(
                'jellyfin_playback_readback_changed') from None

    @staticmethod
    def _guid(value):
        if type(value) is not str or _GUID.fullmatch(value) is None:
            raise ValueError()
        return value.replace('-', '').lower()

    @classmethod
    def _segments(cls, body, item_id):
        raw = _json(body)
        if (type(raw) is not dict or set(raw) != {
                'Items', 'TotalRecordCount', 'StartIndex'}
                or type(raw['Items']) is not list
                or len(raw['Items']) > 32
                or type(raw['TotalRecordCount']) is not int
                or type(raw['TotalRecordCount']) is bool
                or raw['TotalRecordCount'] != len(raw['Items'])
                or type(raw['StartIndex']) is not int
                or type(raw['StartIndex']) is bool
                or raw['StartIndex'] != 0):
            raise ValueError()
        selected = []
        seen_ids = set()
        for value in raw['Items']:
            if (type(value) is not dict or set(value) != {
                    'Id', 'ItemId', 'Type', 'StartTicks', 'EndTicks'}
                    or cls._guid(value['ItemId']) != item_id
                    or type(value['Type']) is not str
                    or value['Type'] not in _SEGMENT_TYPES
                    or type(value['StartTicks']) is not int
                    or type(value['StartTicks']) is bool
                    or type(value['EndTicks']) is not int
                    or type(value['EndTicks']) is bool
                    or not 0 <= value['StartTicks'] <= 86_400_000_000_000
                    or not 0 <= value['EndTicks'] <= 86_400_000_000_000):
                raise ValueError()
            segment_id = cls._guid(value['Id'])
            if segment_id in seen_ids:
                raise ValueError()
            seen_ids.add(segment_id)
            if value['Type'] not in {'Intro', 'Outro'}:
                continue
            start = value['StartTicks'] // 10_000_000
            end = value['EndTicks'] // 10_000_000
            if start >= end:
                raise ValueError()
            selected.append(MediaSegment(
                kind=value['Type'].lower(), startSeconds=start,
                endSeconds=end))
        selected.sort(key=lambda item: (
            item.startSeconds, item.endSeconds, item.kind))
        if (len(selected) > 8
                or any(previous.endSeconds > current.startSeconds
                       for previous, current in zip(selected, selected[1:]))):
            raise ValueError()
        return MediaSegmentsReadback(
            supported=True,
            reason='available' if selected else 'no_segments',
            segments=selected)

    def read_segments(self, connection, *, api_key, installation_id, item_id,
                      deadline):
        self._inputs(api_key, installation_id, deadline)
        if type(item_id) is not str or _ID.fullmatch(item_id) is None:
            raise JellyfinPlaybackRuntimeError(
                'invalid_jellyfin_playback_request')
        authorization = _BASE_AUTH.format(
            device=installation_id, token=api_key)
        status, body = self._segment_request(
            connection, f'/MediaSegments/{item_id}', authorization, deadline)
        if status in {400, 404}:
            return MediaSegmentsReadback(
                supported=False, reason='endpoint_unsupported', segments=[])
        try:
            return self._segments(body, item_id)
        except (ValueError, TypeError, ValidationError, JellyfinStartupError,
                JellyfinPlaybackRuntimeError):
            return MediaSegmentsReadback(
                supported=False, reason='contract_unsupported', segments=[])

    @staticmethod
    def _offline_range_request(connection, path, authorization, deadline,
                               offset, length):
        reader = _StartupReader(connection, deadline)
        try:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise ValueError()
            connection.settimeout(remaining)
            end = offset + length - 1
            connection.sendall(_request_bytes(
                'GET', path, 'jellyfin', {
                    'Accept': 'application/octet-stream',
                    'Authorization': authorization,
                    'Range': f'bytes={offset}-{end}',
                }, None,
            ))
            status, pairs = _headers(reader)
            if status != 206:
                raise ValueError()
            headers = {}
            for name, value in pairs:
                if name in headers:
                    raise ValueError()
                headers[name] = value
            if (set(headers) & {'transfer-encoding', 'content-encoding'}
                    or 'content-length' not in headers
                    or 'content-range' not in headers
                    or 'content-type' not in headers):
                raise ValueError()
            content_length = headers['content-length']
            if (re.fullmatch(r'[0-9]{1,20}', content_length) is None
                    or not 1 <= int(content_length) <= length):
                raise ValueError()
            match = re.fullmatch(
                r'bytes ([0-9]{1,20})-([0-9]{1,20})/([0-9]{1,20})',
                headers['content-range'])
            if match is None:
                raise ValueError()
            start, observed_end, total = map(int, match.groups())
            size = int(content_length)
            if (start != offset or observed_end != offset + size - 1
                    or total < observed_end + 1 or total > 2**63 - 1):
                raise ValueError()
            content_type = headers['content-type']
            if (not 1 <= len(content_type) <= 128
                    or re.fullmatch(r'[A-Za-z0-9!#$&^_.+\-/;= ]+',
                                    content_type) is None):
                raise ValueError()
            return reader.exact(size), total, content_type
        except (OSError, ValueError, TypeError, ProbeTransportError,
                socket.timeout):
            raise JellyfinPlaybackRuntimeError() from None
        finally:
            try:
                connection.close()
            except Exception:
                pass

    def read_offline_chunk(self, connection, *, api_key, installation_id,
                           item_id, offset, length, deadline):
        self._inputs(api_key, installation_id, deadline)
        if (type(item_id) is not str or _ID.fullmatch(item_id) is None
                or type(offset) is not int or type(offset) is bool or offset < 0
                or type(length) is not int or type(length) is bool
                or not 1 <= length <= 32 * 1024):
            raise JellyfinPlaybackRuntimeError(
                'invalid_jellyfin_playback_request')
        authorization = _BASE_AUTH.format(
            device=installation_id, token=api_key)
        content, total, content_type = self._offline_range_request(
            connection, f'/Items/{item_id}/Download', authorization,
            deadline, offset, length)
        return OfflineMediaChunkReadback(
            itemId=item_id, offset=offset, contentLength=total,
            contentType=content_type,
            dataBase64=base64.b64encode(content).decode('ascii'))

    def execute(self, connections, action, *, api_key, deadline, gate):
        if (type(action) is not PrivateMediaPlaybackAction
                or type(connections) not in (tuple, list)
                or len(connections) != 3):
            raise JellyfinPlaybackRuntimeError('invalid_jellyfin_playback_request')
        self._inputs(api_key, action.installationId, deadline)
        before = self.read(
            connections[0], api_key=api_key,
            installation_id=action.installationId, deadline=deadline)
        target = next((item for item in before.targets
                       if item.targetId == action.targetId), None)
        if (before.playbackRevision != action.expectedPlaybackRevision
                or target is None or target.available is not True
                or target.targetRevision != action.expectedTargetRevision):
            self._close(connections[1:])
            raise JellyfinPlaybackRuntimeError(
                'jellyfin_playback_authority_changed')
        self._pre_effect(connections[1:], deadline, gate)
        authorization = _BASE_AUTH.format(
            device=action.installationId, token=api_key)
        query = urlencode(sorted({
            'itemIds': action.itemId,
            'playCommand': 'PlayNow',
            'startPositionTicks': str(action.startSeconds * 10_000_000),
        }.items()))
        self._request(
            connections[1], 'POST',
            f'/Sessions/{action.targetId}/Playing?{query}',
            authorization, deadline, status=204, effect=True)
        try:
            after = self.read(
                connections[2], api_key=api_key,
                installation_id=action.installationId, deadline=deadline)
        except JellyfinPlaybackRuntimeError:
            raise JellyfinPlaybackRuntimeError(
                'jellyfin_playback_effect_unknown',
                uncertain_effect=True) from None
        selected = next((item for item in after.targets
                         if item.targetId == action.targetId), None)
        if (after.playbackRevision <= before.playbackRevision
                or selected is None
                or selected.targetRevision <= target.targetRevision
                or selected.currentItemId != action.itemId
                or abs(selected.positionSeconds - action.startSeconds) > 2):
            raise JellyfinPlaybackRuntimeError(
                'jellyfin_playback_effect_unknown', uncertain_effect=True)
        return MediaPlaybackWorkerResult(
            state='succeeded', playbackRevision=after.playbackRevision,
            target=selected)
