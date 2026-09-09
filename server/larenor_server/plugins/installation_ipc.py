"""Bounded Unix IPC for the closed Jellyfin create/start worker surface."""

import json
import os
from pathlib import Path
import platform as host_platform
import socket
import stat
import time
import uuid

from .installation_execution import JellyfinWorkerBackend
from .preflight_ipc import PreflightIPCError, PreflightWorkerServer, read_packet, write_packet
from .stack_plan import MediaStackComponent
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


class InstallationWorkerClient:
    def __init__(self, path, *, owner_uid=0, peer_uid=None, timeout=5):
        from .preflight_ipc import _peer_uid
        if type(owner_uid) is not int or owner_uid < 0 or type(timeout) not in (int, float) or not 0 < timeout <= 5:
            raise InstallationIPCError()
        self.path = Path(path).absolute()
        self.owner_uid, self.peer_uid, self.timeout = owner_uid, peer_uid or _peer_uid, timeout

    def _exchange(self, operation, step=None, component=None):
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
                request['component'] = component.model_dump(mode='json')
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

    def apply(self, step, component):
        if type(step) is not WorkerStep or type(component) is not MediaStackComponent:
            raise InstallationIPCError('invalid_request')
        return _receipt(self._exchange('apply', step, component), step)

    def reconcile(self, step, component):
        if type(step) is not WorkerStep or type(component) is not MediaStackComponent:
            raise InstallationIPCError('invalid_request')
        return _receipt(self._exchange('reconcile', step, component), step)


class InstallationWorkerServer(PreflightWorkerServer):
    def __init__(self, path, backend, *, allowed_uid, socket_gid=None, peer_uid=None, timeout=5):
        machine = host_platform.machine().lower()
        platform = 'linux/arm64' if machine in {'arm64', 'aarch64'} else 'linux/amd64'
        super().__init__(path, backend, platform=platform, allowed_uid=allowed_uid,
                         socket_gid=socket_gid, peer_uid=peer_uid, timeout=timeout)
        self.backend = backend

    def _answer(self, request, *, deadline=None):
        deadline = time.monotonic() + self.timeout if deadline is None else deadline
        operation = request.get('operation')
        if operation == 'status' and set(request) == {'protocol', 'requestId', 'operation'}:
            return {'capability': 'container_execution', 'installAvailable': False,
                    'services': ['jellyfin']}
        if (operation not in {'apply', 'reconcile'}
                or set(request) != {'protocol', 'requestId', 'operation', 'step', 'component'}
                or time.monotonic() >= deadline):
            raise PreflightIPCError('invalid_request')
        try:
            raw = json.dumps(request['component'], sort_keys=True, separators=(',', ':'), allow_nan=False)
            component = MediaStackComponent.model_validate_json(raw)
            step = WorkerStep(**request['step'])
            JellyfinWorkerBackend._verify(step, component)
            if time.monotonic() >= deadline:
                raise ValueError()
            result = getattr(self.backend, operation)(step, component)
            result = _receipt(result, step)
            if time.monotonic() >= deadline:
                raise ValueError()
            return _wire_receipt(result)
        except (ValueError, TypeError, AttributeError, DockerWorkerError, InstallationIPCError):
            raise PreflightIPCError('invalid_request') from None
