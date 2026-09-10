"""Bounded first-run bootstrap for the pinned Music Assistant engine.

The adapter talks only to the loopback endpoint selected by the retained
worker. It creates the internal administrator, replaces the setup session with
a long-lived integration token, completes onboarding, revokes the short token,
and proves the same server identity afterwards. It never retries a mutation.
"""

import http.client
import json
import math
import re
import threading
import time

from pydantic import ValidationError

from .music_assistant_core_models import AuthenticatedMusicAssistantReadback


_ID = re.compile(r'[0-9a-f]{32}\Z')
_CREDENTIAL = re.compile(r'[A-Za-z0-9_-]{32,128}\Z')
_TOKEN = re.compile(r'[A-Za-z0-9_-]{10,2048}\Z')
_INFO_FIELDS = frozenset({
    'server_id', 'server_version', 'schema_version',
    'min_supported_schema_version', 'name', 'base_url', 'internal_url',
    'external_url', 'has_remote_access', 'homeassistant_addon',
    'onboard_done', 'status',
})
_EXPECTED_VERSION = '2.10.2'
_EXPECTED_SCHEMA = 65


class MusicAssistantBootstrapRuntimeError(Exception):
    """Static private-worker error without upstream data or credentials."""

    _CODES = frozenset({
        'invalid_music_assistant_bootstrap',
        'music_assistant_bootstrap_cancelled',
        'music_assistant_bootstrap_state_conflict',
        'music_assistant_bootstrap_readback_changed',
        'music_assistant_bootstrap_uncertain',
    })

    def __init__(self, code='music_assistant_bootstrap_uncertain', *,
                 uncertain_effect=False):
        self.code = code if code in self._CODES else (
            'music_assistant_bootstrap_uncertain')
        self.uncertain_effect = uncertain_effect is True
        super().__init__(self.code)

    def __repr__(self):
        return (f'MusicAssistantBootstrapRuntimeError({self.code!r}, '
                f'uncertain_effect={self.uncertain_effect!r})')


def _unique(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError()
        value[key] = item
    return value


class MusicAssistantBootstrapRuntime:
    def __init__(self, connection_factory=None):
        self.connection_factory = connection_factory or (
            lambda timeout: http.client.HTTPConnection(
                '127.0.0.1', 8095, timeout=timeout))

    @staticmethod
    def _check(deadline, cancelled):
        if (type(deadline) not in (int, float) or not math.isfinite(deadline)
                or time.monotonic() >= deadline or cancelled.is_set()):
            raise MusicAssistantBootstrapRuntimeError(
                'music_assistant_bootstrap_cancelled')

    def _request(self, path, body, token, deadline, cancelled):
        self._check(deadline, cancelled)
        connection = None
        try:
            connection = self.connection_factory(
                max(.001, deadline - time.monotonic()))
            headers = {
                'Content-Type': 'application/json',
                'Accept': 'application/json',
                'Connection': 'close',
            }
            if token is not None:
                headers['Authorization'] = 'Bearer ' + token
            connection.request(
                'POST', path,
                json.dumps(body, separators=(',', ':'),
                           allow_nan=False).encode('utf-8'),
                headers)
            response = connection.getresponse()
            raw = response.read(65537)
            if len(raw) > 65536:
                raise ValueError()
            parsed = json.loads(
                raw.decode('utf-8'), object_pairs_hook=_unique,
                parse_constant=lambda _value: (_ for _ in ()).throw(
                    ValueError()))
            self._check(deadline, cancelled)
            return response.status, parsed
        except MusicAssistantBootstrapRuntimeError:
            raise
        except Exception:
            raise MusicAssistantBootstrapRuntimeError(
                'music_assistant_bootstrap_uncertain',
                uncertain_effect=True) from None
        finally:
            try:
                if connection is not None:
                    connection.close()
            except Exception:
                pass

    def _rpc(self, installation_id, step, token, command, args, deadline,
             cancelled):
        status, value = self._request('/api', {
            'message_id': installation_id + '-' + step,
            'command': command,
            'args': args,
        }, token, deadline, cancelled)
        if (status != 200 or type(value) is not dict
                or set(value) != {'message_id', 'result'}
                or value['message_id'] != installation_id + '-' + step):
            raise MusicAssistantBootstrapRuntimeError(
                'music_assistant_bootstrap_uncertain',
                uncertain_effect=True)
        return value['result']

    @staticmethod
    def _user(value, username, expected_id=None):
        if (type(value) is not dict
                or type(value.get('user_id')) is not str
                or not value['user_id']
                or len(value['user_id']) > 128
                or value.get('username') != username
                or value.get('role') != 'admin'
                or (expected_id is not None
                    and value['user_id'] != expected_id)):
            raise MusicAssistantBootstrapRuntimeError(
                'music_assistant_bootstrap_readback_changed',
                uncertain_effect=True)
        return value['user_id']

    @staticmethod
    def _info(value, onboard_done, expected_id=None):
        if (type(value) is not dict or not set(value) <= _INFO_FIELDS
                or value.get('server_version') != _EXPECTED_VERSION
                or value.get('schema_version') != _EXPECTED_SCHEMA
                or value.get('onboard_done') is not onboard_done
                or type(value.get('server_id')) is not str
                or not value['server_id'] or len(value['server_id']) > 128
                or (expected_id is not None
                    and value['server_id'] != expected_id)):
            raise MusicAssistantBootstrapRuntimeError(
                'music_assistant_bootstrap_readback_changed',
                uncertain_effect=True)
        return value

    def create(self, *, installation_id, username, credential, deadline,
               cancelled=None):
        if (type(installation_id) is not str
                or _ID.fullmatch(installation_id) is None
                or username != 'larenor-core'
                or type(credential) is not str
                or _CREDENTIAL.fullmatch(credential) is None
                or type(deadline) not in (int, float)
                or not math.isfinite(deadline)):
            raise MusicAssistantBootstrapRuntimeError(
                'invalid_music_assistant_bootstrap')
        cancelled = threading.Event() if cancelled is None else cancelled
        if type(cancelled) is not threading.Event:
            raise MusicAssistantBootstrapRuntimeError(
                'invalid_music_assistant_bootstrap')
        self._check(deadline, cancelled)

        status, setup = self._request('/setup', {
            'username': username,
            'password': credential,
            'device_name': 'Larenor Core',
        }, None, deadline, cancelled)
        if status == 400:
            raise MusicAssistantBootstrapRuntimeError(
                'music_assistant_bootstrap_state_conflict')
        if (status != 200 or type(setup) is not dict
                or set(setup) != {'success', 'token', 'user'}
                or setup['success'] is not True
                or type(setup['token']) is not str
                or _TOKEN.fullmatch(setup['token']) is None):
            raise MusicAssistantBootstrapRuntimeError(
                'music_assistant_bootstrap_uncertain',
                uncertain_effect=True)
        short_token = setup['token']
        user_id = self._user(setup['user'], username)

        long_token = self._rpc(
            installation_id, 'long-token', short_token,
            'auth/token/create', {'name': 'Larenor Core'}, deadline,
            cancelled)
        if type(long_token) is not str or _TOKEN.fullmatch(long_token) is None:
            raise MusicAssistantBootstrapRuntimeError(
                'music_assistant_bootstrap_uncertain',
                uncertain_effect=True)
        self._user(self._rpc(
            installation_id, 'user', long_token, 'auth/me', {}, deadline,
            cancelled), username, user_id)
        before = self._info(self._rpc(
            installation_id, 'info-before', long_token, 'info', {}, deadline,
            cancelled), False)
        if self._rpc(
                installation_id, 'onboard', long_token,
                'config/onboard_complete', {}, deadline, cancelled) is not None:
            raise MusicAssistantBootstrapRuntimeError(
                'music_assistant_bootstrap_uncertain',
                uncertain_effect=True)
        if self._rpc(
                installation_id, 'logout', short_token, 'auth/logout', {},
                deadline, cancelled) is not None:
            raise MusicAssistantBootstrapRuntimeError(
                'music_assistant_bootstrap_uncertain',
                uncertain_effect=True)
        after = self._info(self._rpc(
            installation_id, 'info-after', long_token, 'info', {}, deadline,
            cancelled), True, before['server_id'])
        try:
            return AuthenticatedMusicAssistantReadback(
                token=long_token, serverId=after['server_id'],
                serverVersion=after['server_version'],
                schemaVersion=after['schema_version'])
        except ValidationError:
            raise MusicAssistantBootstrapRuntimeError(
                'music_assistant_bootstrap_readback_changed',
                uncertain_effect=True) from None
