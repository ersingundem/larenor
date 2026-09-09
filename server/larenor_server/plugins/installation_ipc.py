"""Bounded Unix IPC for the closed Jellyfin create/start worker surface."""

import json
import math
import os
from pathlib import Path
import platform as host_platform
import re
import socket
import stat
import threading
import time
import uuid

from .installation_execution import JellyfinWorkerBackend
from .jellyfin_bootstrap_executor import (
    JellyfinBootstrapExecutionError, JellyfinBootstrapExecutionResult,
)
from .jellyfin_authenticated_readback import JellyfinAuthenticatedReadbackResult
from .media_service_bootstrap_models import PrivateMediaServiceBootstrap
from .preflight_ipc import PreflightIPCError, PreflightWorkerServer, read_packet, write_packet
from .catalog import load_catalog
from .stack_plan import MediaStackPlan, verify_media_stack_plan
from .worker import DockerWorkerError, StepReceipt, WorkerStep, _safe_path


class InstallationIPCError(Exception):
    def __init__(self, code='worker_unavailable'):
        self.code = code if code in {'worker_unavailable', 'invalid_request', 'invalid_worker_result'} else 'worker_unavailable'
        super().__init__(self.code)


def _receipt(value, step):
    try:
        if type(value) is StepReceipt:
            result = value
        elif type(value) is dict and set(value) == {'jobId', 'step', 'state', 'code', 'containerId'}:
            result = StepReceipt(value['jobId'], value['step'], value['state'], value['code'], value['containerId'])
        else:
            raise ValueError()
        if result.job_id != step.job_id or result.step != step.kind:
            raise ValueError()
        return result
    except (ValueError, TypeError, AttributeError):
        raise InstallationIPCError('invalid_worker_result') from None


def _wire_receipt(value):
    return {'jobId': value.job_id, 'step': value.step, 'state': value.state,
            'code': value.code, 'containerId': value.container_id}


_BOOTSTRAP_STEPS = (
    'observed_unconfigured', 'configuration_updated', 'user_updated',
    'remote_access_updated', 'wizard_completed',
)


def _wire_bootstrap(value=None, error=None):
    if error is not None:
        return {
            'state': 'failed', 'completedSteps': list(error.completed_steps),
            'errorCode': error.code, 'uncertainEffect': error.uncertain_effect,
            'readback': None,
        }
    if (type(value) is not JellyfinBootstrapExecutionResult
            or value.state != 'wiring_partial'
            or value.completed_steps != _BOOTSTRAP_STEPS
            or type(value.readback) is not JellyfinAuthenticatedReadbackResult):
        raise InstallationIPCError('invalid_worker_result')
    return {
        'state': value.state,
        'completedSteps': list(value.completed_steps),
        'errorCode': None, 'uncertainEffect': False,
        'readback': {
            'state': value.readback.state,
            'serverId': value.readback.server_id,
            'serverName': value.readback.server_name,
            'version': value.readback.version,
            'apiKey': value.readback.api_key,
            'libraries': [
                {
                    'name': name, 'collectionType': collection,
                    'itemId': item_id, 'locations': list(locations),
                }
                for name, collection, item_id, locations in value.readback.libraries
            ],
            'completedSteps': list(value.readback.completed_steps),
        },
    }


def _bootstrap_result(value):
    try:
        if (type(value) is not dict or set(value) != {
                'state', 'completedSteps', 'errorCode', 'uncertainEffect', 'readback'}
                or type(value['completedSteps']) is not list
                or any(type(item) is not str or item not in _BOOTSTRAP_STEPS
                       for item in value['completedSteps'])
                or tuple(value['completedSteps']) != _BOOTSTRAP_STEPS[:len(value['completedSteps'])]
                or type(value['uncertainEffect']) is not bool):
            raise ValueError()
        completed = tuple(value['completedSteps'])
        if (value['state'] == 'wiring_partial'
                and value['completedSteps'] == list(_BOOTSTRAP_STEPS)
                and value['errorCode'] is None
                and value['uncertainEffect'] is False):
            readback = value['readback']
            if (type(readback) is not dict or set(readback) != {
                    'state', 'serverId', 'serverName', 'version', 'apiKey',
                    'libraries', 'completedSteps'}
                    or readback['state'] != 'verified'
                    or type(readback['libraries']) is not list
                    or len(readback['libraries']) > 256
                    or type(readback['completedSteps']) is not list):
                raise ValueError()
            libraries = []
            for item in readback['libraries']:
                if type(item) is not dict or set(item) != {
                        'name', 'collectionType', 'itemId', 'locations'}:
                    raise ValueError()
                libraries.append((
                    item['name'], item['collectionType'], item['itemId'],
                    tuple(item['locations']),
                ))
            verified = JellyfinAuthenticatedReadbackResult(
                readback['state'], readback['serverId'], readback['serverName'],
                readback['version'], readback['apiKey'], tuple(libraries),
                tuple(readback['completedSteps']),
            )
            # Re-validate every private value through the same strict encrypted
            # storage model before the Core can persist it.
            from .media_service_bootstrap_models import (
                PrivateJellyfinReadback, PrivateMediaLibrary,
            )
            PrivateJellyfinReadback(
                apiKey=verified.api_key,
                serverId=verified.server_id,
                serverName=verified.server_name,
                version=verified.version,
                libraries=tuple(
                    PrivateMediaLibrary(
                        name=name, collectionType=collection, itemId=item_id,
                        locations=locations,
                    )
                    for name, collection, item_id, locations in verified.libraries
                ),
            )
            return JellyfinBootstrapExecutionResult(
                'wiring_partial', completed, verified)
        if (value['state'] != 'failed' or type(value['errorCode']) is not str
                or value['readback'] is not None
                or value['errorCode'] not in {
                    'invalid_bootstrap_execution', 'bootstrap_authority_changed',
                    'bootstrap_resources_unavailable', 'bootstrap_endpoint_unavailable',
                    'bootstrap_endpoint_changed', 'bootstrap_startup_failed',
                    'bootstrap_readback_failed', 'bootstrap_wiring_failed',
                    'bootstrap_timeout'}):
            raise ValueError()
        raise JellyfinBootstrapExecutionError(
            value['errorCode'], completed_steps=completed,
            uncertain_effect=value['uncertainEffect'])
    except JellyfinBootstrapExecutionError:
        raise
    except (ValueError, TypeError, AttributeError):
        raise InstallationIPCError('invalid_worker_result') from None


class InstallationWorkerClient:
    def __init__(self, path, *, owner_uid=0, peer_uid=None, timeout=5):
        from .preflight_ipc import _peer_uid
        if type(owner_uid) is not int or owner_uid < 0 or type(timeout) not in (int, float) or not 0 < timeout <= 5:
            raise InstallationIPCError()
        self.path = Path(path).absolute()
        self.owner_uid, self.peer_uid, self.timeout = owner_uid, peer_uid or _peer_uid, timeout

    def _exchange(self, operation, step=None, plan=None, bootstrap=None):
        try:
            _safe_path(self.path, uid=self.owner_uid, kind=stat.S_ISSOCK)
            deadline = time.monotonic() + self.timeout
            request = {'protocol': 1, 'requestId': uuid.uuid4().hex, 'operation': operation}
            if step is not None:
                request['step'] = {
                    'job_id': step.job_id, 'installation_id': step.installation_id,
                    'kind': step.kind, 'dispatch_id': step.dispatch_id,
                    'start_deadline': step.start_deadline,
                }
                request['plan'] = plan.model_dump(mode='json')
            elif bootstrap is not None:
                job, private = bootstrap
                request['jobId'] = job
                request['plan'] = plan.model_dump(mode='json')
                request['private'] = private.model_dump(mode='json')
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                connection.settimeout(self.timeout)
                connection.connect(str(self.path))
                if self.peer_uid(connection) != self.owner_uid:
                    raise InstallationIPCError()
                write_packet(connection, request, deadline)
                response = read_packet(connection, deadline)
            if response['requestId'] != request['requestId']:
                raise InstallationIPCError('invalid_worker_result')
            if set(response) == {'protocol', 'requestId', 'error'}:
                raise InstallationIPCError()
            if set(response) != {'protocol', 'requestId', 'result'}:
                raise InstallationIPCError('invalid_worker_result')
            return response['result']
        except InstallationIPCError:
            raise
        except (OSError, ValueError, TypeError, AttributeError, DockerWorkerError, PreflightIPCError):
            raise InstallationIPCError() from None

    def status(self):
        result = self._exchange('status')
        expected = {'capability': 'container_execution', 'installAvailable': False,
                    'services': ['jellyfin']}
        if result != expected:
            raise InstallationIPCError('invalid_worker_result')
        return result

    def apply(self, step, plan):
        if type(step) is not WorkerStep or type(plan) is not MediaStackPlan:
            raise InstallationIPCError('invalid_request')
        return _receipt(self._exchange('apply', step, plan), step)

    def reconcile(self, step, plan):
        if type(step) is not WorkerStep or type(plan) is not MediaStackPlan:
            raise InstallationIPCError('invalid_request')
        return _receipt(self._exchange('reconcile', step, plan), step)

    def execute(self, job, plan, private, *, deadline, gate):
        now = time.monotonic()
        if (type(job) is not str or re.fullmatch(r'[0-9a-f]{32}', job) is None
                or type(plan) is not MediaStackPlan
                or type(private) is not PrivateMediaServiceBootstrap
                or type(deadline) not in (int, float) or not math.isfinite(deadline)
                or not now < deadline <= now + 120 or not callable(gate)):
            raise JellyfinBootstrapExecutionError('invalid_bootstrap_execution')
        try:
            plan = verify_media_stack_plan(plan, load_catalog())
        except (ValueError, TypeError, AttributeError, OSError):
            raise JellyfinBootstrapExecutionError('invalid_bootstrap_execution') from None
        try:
            permitted = gate()
        except Exception:
            raise JellyfinBootstrapExecutionError('bootstrap_authority_changed') from None
        if permitted is not True:
            raise JellyfinBootstrapExecutionError('bootstrap_authority_changed')
        try:
            return _bootstrap_result(self._exchange(
                'bootstrap', plan=plan, bootstrap=(job, private)))
        except JellyfinBootstrapExecutionError:
            raise
        except InstallationIPCError:
            raise JellyfinBootstrapExecutionError(
                'bootstrap_resources_unavailable') from None


class InstallationWorkerServer(PreflightWorkerServer):
    def __init__(self, path, backend, *, allowed_uid, socket_gid=None, peer_uid=None, timeout=5):
        machine = host_platform.machine().lower()
        platform = 'linux/arm64' if machine in {'arm64', 'aarch64'} else 'linux/amd64'
        super().__init__(path, backend, platform=platform, allowed_uid=allowed_uid,
                         socket_gid=socket_gid, peer_uid=peer_uid, timeout=timeout)
        self.backend = backend
        self._backend_ready = threading.Event()
        self._backend_started = False
        self._backend_failed = False

    def start(self):
        if self._listener is not None or self._lock is not None:
            raise PreflightIPCError()
        self._backend_ready.clear()
        self._backend_started = self._backend_failed = False
        super().start()
        if not self._backend_ready.wait(self.timeout) or self._backend_failed:
            try:
                super().close()
            finally:
                raise PreflightIPCError() from None

    def _serve(self):
        try:
            opening = getattr(self.backend, 'open', None)
            if callable(opening):
                opening(time.monotonic() + self.timeout)
            self._backend_started = True
            self._backend_ready.set()
            super()._serve()
        except Exception:
            self._backend_failed = True
            self._stopped.set()
            self._backend_ready.set()
        finally:
            if self._backend_started:
                closing = getattr(self.backend, 'close', None)
                if callable(closing):
                    try:
                        closing()
                    except Exception:
                        self._backend_failed = True
            self._backend_ready.set()

    def close(self):
        super().close()
        if self._backend_failed:
            raise PreflightIPCError()

    def _answer(self, request, *, deadline=None):
        deadline = time.monotonic() + self.timeout if deadline is None else deadline
        operation = request.get('operation')
        if operation == 'status' and set(request) == {'protocol', 'requestId', 'operation'}:
            return {'capability': 'container_execution', 'installAvailable': False,
                    'services': ['jellyfin']}
        if operation == 'bootstrap':
            if (set(request) != {
                    'protocol', 'requestId', 'operation', 'jobId', 'plan', 'private'}
                    or type(request['jobId']) is not str
                    or re.fullmatch(r'[0-9a-f]{32}', request['jobId']) is None
                    or time.monotonic() >= deadline):
                raise PreflightIPCError('invalid_request')
            try:
                raw_plan = json.dumps(
                    request['plan'], sort_keys=True, separators=(',', ':'),
                    allow_nan=False)
                raw_private = json.dumps(
                    request['private'], sort_keys=True, separators=(',', ':'),
                    allow_nan=False)
                plan = verify_media_stack_plan(
                    MediaStackPlan.model_validate_json(raw_plan), self.catalog)
                private = PrivateMediaServiceBootstrap.model_validate_json(raw_private)
                timed = getattr(self.backend, 'bootstrap_with_deadline', None)
                try:
                    result = (timed(request['jobId'], plan, private, deadline)
                              if callable(timed) else self.backend.bootstrap(
                                  request['jobId'], plan, private, deadline=deadline))
                except JellyfinBootstrapExecutionError as error:
                    return _wire_bootstrap(error=error)
                if time.monotonic() >= deadline:
                    raise JellyfinBootstrapExecutionError('bootstrap_timeout')
                return _wire_bootstrap(value=result)
            except JellyfinBootstrapExecutionError as error:
                return _wire_bootstrap(error=error)
            except (ValueError, TypeError, AttributeError, DockerWorkerError,
                    InstallationIPCError):
                raise PreflightIPCError('invalid_request') from None
        if (operation not in {'apply', 'reconcile'}
                or set(request) != {'protocol', 'requestId', 'operation', 'step', 'plan'}
                or time.monotonic() >= deadline):
            raise PreflightIPCError('invalid_request')
        try:
            raw = json.dumps(request['plan'], sort_keys=True, separators=(',', ':'), allow_nan=False)
            plan = MediaStackPlan.model_validate_json(raw)
            step = WorkerStep(**request['step'])
            JellyfinWorkerBackend._verify(step, plan)
            if time.monotonic() >= deadline:
                raise ValueError()
            timed = getattr(self.backend, operation + '_with_deadline', None)
            result = (timed(step, plan, deadline) if callable(timed)
                      else getattr(self.backend, operation)(step, plan))
            result = _receipt(result, step)
            if time.monotonic() >= deadline:
                raise ValueError()
            return _wire_receipt(result)
        except (ValueError, TypeError, AttributeError, DockerWorkerError, InstallationIPCError):
            raise PreflightIPCError('invalid_request') from None
