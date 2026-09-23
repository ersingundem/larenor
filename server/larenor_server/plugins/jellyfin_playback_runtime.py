"""Strict Jellyfin remote-play protocol over preverified private streams."""

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
    _json,
    _response,
)
from .media_playback_models import (
    MediaPlaybackReadback,
    MediaPlaybackTarget,
    MediaPlaybackWorkerResult,
    PrivateMediaPlaybackAction,
)


_ID = re.compile(r'[0-9a-f]{32}\Z')
_API_KEY = re.compile(r'[A-Za-z0-9_-]{32,128}\Z')
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
        if now is not None:
            if (type(now) is not dict or type(now.get('Id')) is not str
                    or _ID.fullmatch(now['Id']) is None):
                raise ValueError()
            current = now['Id']
        return {
            'targetId': identifier,
            'name': name,
            'available': available,
            'currentItemId': current,
            'positionSeconds': ticks // 10_000_000,
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
                'jellyfin_playback_effect_unknown')
        return MediaPlaybackWorkerResult(
            state='succeeded', playbackRevision=after.playbackRevision,
            target=selected)
