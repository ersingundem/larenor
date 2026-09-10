"""Bounded authenticated Music Assistant setup-flow client for the private worker."""

import http.client
import json
import math
import re
import threading
import time

from pydantic import ValidationError

from .music_provider_setup_models import (
    PrivateMusicProviderSetupAction, ProviderSetupDiscovery,
    ProviderSetupEntry, ProviderSetupWorkerResult,
)


class MusicProviderSetupRuntimeError(Exception):
    """Static private-worker failure; response bodies and credentials stay private."""


class MusicProviderSetupRuntime:
    def __init__(self, connection_factory=None):
        self.connection_factory = connection_factory or (
            lambda timeout: http.client.HTTPConnection(
                '127.0.0.1', 8095, timeout=timeout))

    @staticmethod
    def _check(deadline, cancelled):
        if (type(deadline) not in (int, float) or not math.isfinite(deadline)
                or time.monotonic() >= deadline or cancelled.is_set()):
            raise MusicProviderSetupRuntimeError('provider_setup_cancelled')

    def _command(self, action, command, args, deadline, cancelled):
        self._check(deadline, cancelled)
        message_id = action.setupId + '-' + command.rsplit('/', 1)[-1]
        body = json.dumps({'message_id': message_id, 'command': command,
                           'args': args}, separators=(',', ':'), allow_nan=False)
        connection = self.connection_factory(max(.001, deadline - time.monotonic()))
        try:
            connection.request('POST', '/api', body=body.encode('utf-8'), headers={
                'Authorization': 'Bearer ' + action.token,
                'Content-Type': 'application/json',
                'Accept': 'application/json',
                'Connection': 'close',
            })
            response = connection.getresponse()
            raw = response.read(65537)
            if response.status != 200 or len(raw) > 65536:
                raise ValueError()
            parsed = json.loads(raw)
            if (type(parsed) is not dict
                    or parsed.get('message_id') != message_id
                    or set(parsed) != {'message_id', 'result'}):
                raise ValueError()
            self._check(deadline, cancelled)
            return parsed['result']
        except MusicProviderSetupRuntimeError:
            raise
        except Exception:
            raise MusicProviderSetupRuntimeError(
                'provider_setup_upstream_unavailable') from None
        finally:
            try:
                connection.close()
            except Exception:
                pass

    @staticmethod
    def _flow(action, value, now):
        try:
            if type(value) is not dict:
                raise ValueError()
            kind = value.get('type')
            if (action.flowId is not None
                    and value.get('flow_id') != action.flowId):
                raise ValueError()
            if kind in {'external', 'form'}:
                flow_id = value['flow_id']
                entries = []
                for raw in value.get('data_schema', []):
                    if type(raw) is not dict:
                        raise ValueError()
                    entries.append(ProviderSetupEntry(
                        key=raw['key'], type=raw['type'],
                        required=raw.get('required', False)))
                return ProviderSetupWorkerResult(
                    state='action_required', providerDomain=action.providerDomain,
                    discovery=ProviderSetupDiscovery(
                        providerDomain=action.providerDomain, flowId=flow_id,
                        stepId=value['step_id'], kind=kind,
                        externalUrl=value.get('external_url'),
                        expiresAt=now + 900, entries=entries))
            if kind != 'finish':
                raise ValueError()
            result = value['result']
            instance_id = (result.get('instance_id')
                           if type(result) is dict else result)
            if (type(instance_id) is not str
                    or re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.:\-]{0,127}',
                                    instance_id) is None):
                raise ValueError()
            return instance_id
        except (KeyError, TypeError, ValueError, ValidationError):
            raise MusicProviderSetupRuntimeError(
                'provider_setup_upstream_changed') from None

    def execute(self, action, *, deadline, cancelled=None):
        if type(action) is not PrivateMusicProviderSetupAction:
            raise MusicProviderSetupRuntimeError('invalid_provider_setup_action')
        cancelled = threading.Event() if cancelled is None else cancelled
        if type(cancelled) is not threading.Event:
            raise MusicProviderSetupRuntimeError('invalid_provider_setup_action')
        command = {
            'start': ('config/providers/setup',
                      {'provider_domain': action.providerDomain}),
            'submit': ('config/flows/submit',
                       {'flow_id': action.flowId, 'values': action.values}),
            'resume': ('config/flows/get', {'flow_id': action.flowId}),
            'abort': ('config/flows/abort', {'flow_id': action.flowId}),
        }[action.command]
        value = self._command(action, command[0], command[1], deadline, cancelled)
        if action.command == 'abort':
            if value not in (None, True):
                raise MusicProviderSetupRuntimeError(
                    'provider_setup_upstream_changed')
            return ProviderSetupWorkerResult(
                state='cancelled', providerDomain=action.providerDomain)
        parsed = self._flow(action, value, int(time.time()))
        if type(parsed) is ProviderSetupWorkerResult:
            return parsed
        # A finish response is not accepted as success until the same
        # authenticated endpoint reads the exact provider instance back.
        readback = self._command(
            action, 'config/providers/get', {'instance_id': parsed},
            deadline, cancelled)
        if (type(readback) is not dict
                or readback.get('instance_id') != parsed
                or readback.get('domain') != action.providerDomain
                or readback.get('status') != 'loaded'):
            raise MusicProviderSetupRuntimeError(
                'provider_setup_readback_failed')
        return ProviderSetupWorkerResult(
            state='ready', providerDomain=action.providerDomain,
            providerInstanceId=parsed)
