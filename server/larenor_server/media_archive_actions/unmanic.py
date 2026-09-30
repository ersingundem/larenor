"""Strict Unmanic 0.4.1 HTTP protocol boundary for the F30 worker.

This module only builds and validates the six fixed API exchanges used by the
media archive worker.  Connection policy, credentials, mount translation,
journalling, retries and terminal callback receipts belong to the isolated
worker around this adapter.  A successful delete/terminate response is only an
acknowledgement that Unmanic accepted that control request.
"""

from dataclasses import dataclass, field
import hashlib
import json
import math
import posixpath
import time
from typing import Protocol, runtime_checkable


_PREFIX = "/unmanic/api/v2"
_MAX_BODY = 512 * 1024
_MAX_IDS = 64
_MAX_ID = 2**63 - 1
_TASK_KEYS = frozenset({
    "id", "abspath", "priority", "type", "status", "checksum",
    "library_id", "library_name",
})
_TASK_REQUIRED = frozenset({"id", "abspath", "priority", "type", "status"})
_WORKER_KEYS = frozenset({
    "id", "name", "idle", "paused", "start_time", "current_file",
    "current_task", "current_command", "worker_log_tail", "runners_info",
    "subprocess",
})
_STATUSES = frozenset({
    "creating", "pending", "in_progress", "processed", "complete",
})


class UnmanicHttpError(Exception):
    """Static, secret-free protocol error."""

    _CODES = frozenset({
        "invalid_unmanic_request",
        "unmanic_transport_unavailable",
        "unmanic_deadline_exceeded",
        "unmanic_protocol_changed",
        "unmanic_upstream_rejected",
    })

    def __init__(self, code="unmanic_transport_unavailable"):
        self.code = code if code in self._CODES else "unmanic_transport_unavailable"
        super().__init__(self.code)

    def __repr__(self):
        return f"UnmanicHttpError({self.code!r})"


@dataclass(frozen=True)
class UnmanicRequest:
    method: str
    path: str
    headers: tuple[tuple[str, str], ...]
    body: bytes = field(repr=False)


@dataclass(frozen=True)
class UnmanicResponse:
    status: int
    contentType: str
    body: bytes = field(repr=False)


@dataclass(frozen=True)
class PendingTestResult:
    path: str
    libraryId: int
    libraryName: str
    shouldQueue: bool | None
    issueCount: int
    decisionPluginId: str | None
    decisionPluginName: str | None


@dataclass(frozen=True)
class PendingTask:
    id: int
    path: str
    priority: int
    taskType: str
    status: str
    libraryId: int | None
    libraryName: str | None
    checksum: str | None


@dataclass(frozen=True)
class PendingStatusReadback:
    tasks: tuple[PendingTask, ...]
    missingIds: tuple[int, ...]
    # The public endpoint never carries a durable terminal result.
    terminal: bool = False


@dataclass(frozen=True)
class WorkerStatus:
    id: str
    name: str
    idle: bool
    paused: bool
    startTime: str | None
    currentFile: str
    currentTask: int | None
    currentCommand: str | None


@dataclass(frozen=True)
class UnmanicWorkBinding:
    """Trusted file-store resolution; hashes are observed by the file store."""

    path: str
    libraryId: int

    def __post_init__(self):
        _path(self.path)
        try:
            _integer(self.libraryId)
        except ValueError:
            raise UnmanicHttpError("invalid_unmanic_request") from None


@dataclass(frozen=True)
class UnmanicTerminalReceipt:
    providerTaskId: int
    workPath: str
    libraryId: int
    terminal: str
    destinationPath: str
    destinationFiles: tuple[str, ...]
    taskSuccess: bool
    fileMoveProcessesSuccess: bool
    startTime: float
    finishTime: float
    processedByWorker: str
    callbackDigest: str


@runtime_checkable
class UnmanicWorkPathResolver(Protocol):
    def resolve_work_path(self, command) -> UnmanicWorkBinding:
        """Resolve a command from trusted file-store state, never request input."""


@runtime_checkable
class UnmanicTerminalLookup(Protocol):
    def lookup_terminal(
        self, provider_task_id: int, expected_work_path: str
    ) -> UnmanicTerminalReceipt | None:
        """Return only an authenticated exact task/path terminal projection."""


def _pairs(values):
    result = {}
    for key, value in values:
        if key in result:
            raise ValueError
        result[key] = value
    return result


def _bounded_json(value, depth=0, budget=None):
    if budget is None:
        budget = [4096]
    budget[0] -= 1
    if budget[0] < 0 or depth > 10:
        raise ValueError
    if value is None or type(value) in (bool, int, str):
        if type(value) is str and len(value) > 16_384:
            raise ValueError
        return
    if type(value) is float:
        if not math.isfinite(value):
            raise ValueError
        return
    if type(value) is list:
        if len(value) > 1024:
            raise ValueError
        for item in value:
            _bounded_json(item, depth + 1, budget)
        return
    if type(value) is dict:
        if len(value) > 256:
            raise ValueError
        for key, item in value.items():
            if type(key) is not str or not 1 <= len(key) <= 256:
                raise ValueError
            _bounded_json(item, depth + 1, budget)
        return
    raise ValueError


def _decode(response):
    if (
        type(response) is not UnmanicResponse
        or type(response.status) is not int
        or type(response.contentType) is not str
        or response.contentType.lower() not in {
            "application/json", "application/json; charset=utf-8",
            'application/json; charset="utf-8"',
        }
        or type(response.body) is not bytes
        or not 1 <= len(response.body) <= _MAX_BODY
    ):
        raise UnmanicHttpError("unmanic_protocol_changed")
    try:
        value = json.loads(
            response.body.decode("utf-8"),
            object_pairs_hook=_pairs,
            parse_constant=lambda _value: (_ for _ in ()).throw(ValueError()),
        )
        _bounded_json(value)
        if type(value) is not dict:
            raise ValueError
        return value
    except (UnicodeError, ValueError, TypeError, RecursionError):
        raise UnmanicHttpError("unmanic_protocol_changed") from None


def _text(value, *, maximum=4096, empty=False):
    if (
        type(value) is not str
        or (not empty and not value)
        or len(value) > maximum
        or any(ord(char) < 32 or ord(char) == 127 for char in value)
    ):
        raise ValueError
    return value


def _integer(value, *, minimum=1, maximum=_MAX_ID):
    if type(value) is not int or not minimum <= value <= maximum:
        raise ValueError
    return value


def _path(value):
    try:
        _text(value, maximum=4096)
        if (
            not value.startswith("/")
            or value == "/"
            or "//" in value
            or posixpath.normpath(value) != value
        ):
            raise ValueError
    except ValueError:
        raise UnmanicHttpError("invalid_unmanic_request") from None
    return value


def _terminal_value(value):
    required = {
        "schemaVersion", "taskId", "taskType", "libraryId", "sourcePath",
        "destinationPath", "destinationFiles", "taskSuccess",
        "fileMoveProcessesSuccess", "startTime", "finishTime",
        "processedByWorker",
    }
    try:
        if type(value) is not dict or set(value) != required:
            raise ValueError
        if value["schemaVersion"] != 1 or type(value["schemaVersion"]) is not int:
            raise ValueError
        task_id = _integer(value["taskId"])
        if value["taskType"] != "local":
            raise ValueError
        library_id = _integer(value["libraryId"])
        source = _path(value["sourcePath"])
        destination = _path(value["destinationPath"])
        destinations = value["destinationFiles"]
        if type(destinations) is not list or len(destinations) > 16:
            raise ValueError
        destinations = tuple(_path(item) for item in destinations)
        if len(set(destinations)) != len(destinations):
            raise ValueError
        task_success = value["taskSuccess"]
        movement_success = value["fileMoveProcessesSuccess"]
        if type(task_success) is not bool or type(movement_success) is not bool:
            raise ValueError
        if task_success and movement_success and destination not in destinations:
            raise ValueError
        start = value["startTime"]
        finish = value["finishTime"]
        if (
            type(start) not in (int, float)
            or type(start) is bool
            or type(finish) not in (int, float)
            or type(finish) is bool
            or not math.isfinite(start)
            or not math.isfinite(finish)
            or not 1 <= start <= finish <= 253402300799
        ):
            raise ValueError
        worker = _text(value["processedByWorker"], maximum=240)
        canonical = json.dumps(
            value, sort_keys=True, separators=(",", ":"), allow_nan=False,
        ).encode("utf-8")
        return UnmanicTerminalReceipt(
            providerTaskId=task_id,
            workPath=source,
            libraryId=library_id,
            terminal=(
                "succeeded" if task_success and movement_success else "failed"
            ),
            destinationPath=destination,
            destinationFiles=destinations,
            taskSuccess=task_success,
            fileMoveProcessesSuccess=movement_success,
            startTime=float(start),
            finishTime=float(finish),
            processedByWorker=worker,
            callbackDigest=hashlib.sha256(canonical).hexdigest(),
        ), canonical
    except (KeyError, TypeError, ValueError, UnicodeError):
        raise UnmanicHttpError("unmanic_protocol_changed") from None


def parse_terminal_callback(value):
    """Validate the minimal payload emitted by the pinned event hook."""

    return _terminal_value(value)[0]


def _decode_terminal_callback_body(body):
    if type(body) is not bytes or not 1 <= len(body) <= 64 * 1024:
        raise UnmanicHttpError("unmanic_protocol_changed")
    try:
        value = json.loads(
            body.decode("utf-8"), object_pairs_hook=_pairs,
            parse_constant=lambda _value: (_ for _ in ()).throw(ValueError()),
        )
        _bounded_json(value)
    except (UnicodeError, ValueError, TypeError, RecursionError):
        raise UnmanicHttpError("unmanic_protocol_changed") from None
    receipt, canonical = _terminal_value(value)
    if body != canonical:
        raise UnmanicHttpError("unmanic_protocol_changed")
    return receipt


def _ids(values):
    try:
        if type(values) not in (list, tuple) or not 1 <= len(values) <= _MAX_IDS:
            raise ValueError
        result = tuple(_integer(value) for value in values)
        if len(set(result)) != len(result):
            raise ValueError
        return result
    except ValueError:
        raise UnmanicHttpError("invalid_unmanic_request") from None


def _task(value):
    try:
        if (
            type(value) is not dict
            or not _TASK_REQUIRED <= set(value) <= _TASK_KEYS
        ):
            raise ValueError
        identifier = _integer(value["id"])
        path = _text(value["abspath"], maximum=4096)
        priority = _integer(value["priority"], minimum=-_MAX_ID)
        task_type = value["type"]
        status = value["status"]
        if task_type not in {"local", "remote"} or status not in _STATUSES:
            raise ValueError
        library_id = value.get("library_id")
        if library_id is not None:
            library_id = _integer(library_id)
        library_name = value.get("library_name")
        if library_name is not None:
            library_name = _text(library_name, maximum=240)
        checksum = value.get("checksum")
        if checksum is not None:
            checksum = _text(checksum, maximum=256)
        return PendingTask(
            id=identifier,
            path=path,
            priority=priority,
            taskType=task_type,
            status=status,
            libraryId=library_id,
            libraryName=library_name,
            checksum=checksum,
        )
    except (KeyError, TypeError, ValueError):
        raise UnmanicHttpError("unmanic_protocol_changed") from None


class UnmanicAdapter:
    """Build fixed requests and strictly parse Unmanic 0.4.1 responses."""

    def __init__(self, exchange, *, timeout=4.0, clock=None):
        if (
            not callable(exchange)
            or type(timeout) not in (int, float)
            or type(timeout) is bool
            or not math.isfinite(timeout)
            or not 0 < timeout <= 30
            or clock is not None and not callable(clock)
        ):
            raise UnmanicHttpError("invalid_unmanic_request")
        self._exchange = exchange
        self._timeout = float(timeout)
        self._clock = clock or time.monotonic

    @staticmethod
    def _request(method, path, value=None):
        try:
            body = (
                b""
                if method == "GET" and value is None
                else json.dumps(
                    value, sort_keys=True, separators=(",", ":"),
                    allow_nan=False,
                ).encode("utf-8")
            )
        except (TypeError, ValueError, UnicodeError):
            raise UnmanicHttpError("invalid_unmanic_request") from None
        if len(body) > 32_768 or method == "GET" and body:
            raise UnmanicHttpError("invalid_unmanic_request")
        headers = (("Accept", "application/json"),)
        if method != "GET":
            headers += (("Content-Type", "application/json"),)
        return UnmanicRequest(
            method=method,
            path=_PREFIX + path,
            headers=headers,
            body=body,
        )

    def _call(self, method, path, value):
        request = self._request(method, path, value)
        deadline = self._clock() + self._timeout
        try:
            response = self._exchange(request, deadline)
        except UnmanicHttpError:
            raise
        except Exception:
            raise UnmanicHttpError("unmanic_transport_unavailable") from None
        if self._clock() >= deadline:
            raise UnmanicHttpError("unmanic_deadline_exceeded")
        decoded = _decode(response)
        if response.status != 200:
            if (
                response.status not in {400, 404, 405, 500}
                or not {"error", "messages"} <= set(decoded)
                or not set(decoded) <= {"error", "messages", "traceback"}
                or type(decoded["error"]) is not str
                or type(decoded["messages"]) is not dict
                or "traceback" in decoded and type(decoded["traceback"]) is not list
            ):
                raise UnmanicHttpError("unmanic_protocol_changed")
            raise UnmanicHttpError("unmanic_upstream_rejected")
        return decoded

    def test_path(self, path, *, library_id):
        path = _path(path)
        try:
            library_id = _integer(library_id)
        except ValueError:
            raise UnmanicHttpError("invalid_unmanic_request") from None
        value = self._call(
            "POST", "/pending/test", {"path": path, "library_id": library_id}
        )
        try:
            if set(value) != {
                "path", "library_id", "library_name",
                "add_file_to_pending_tasks", "issues", "decision_plugin",
            }:
                raise ValueError
            if value["path"] != path or value["library_id"] != library_id:
                raise ValueError
            library_name = _text(value["library_name"], maximum=240)
            should_queue = value["add_file_to_pending_tasks"]
            if should_queue is not None and type(should_queue) is not bool:
                raise ValueError
            issues = value["issues"]
            if (
                type(issues) is not list
                or len(issues) > 256
                or any(type(issue) is not dict for issue in issues)
            ):
                raise ValueError
            decision = value["decision_plugin"]
            if decision is None:
                plugin_id = plugin_name = None
            else:
                if type(decision) is not dict or set(decision) != {
                    "plugin_id", "plugin_name"
                }:
                    raise ValueError
                plugin_id = _text(decision["plugin_id"], maximum=128)
                plugin_name = _text(decision["plugin_name"], maximum=240)
            return PendingTestResult(
                path=path,
                libraryId=library_id,
                libraryName=library_name,
                shouldQueue=should_queue,
                issueCount=len(issues),
                decisionPluginId=plugin_id,
                decisionPluginName=plugin_name,
            )
        except (KeyError, TypeError, ValueError):
            raise UnmanicHttpError("unmanic_protocol_changed") from None

    def create_local_task(self, path, *, library_id, priority_score=0):
        path = _path(path)
        try:
            library_id = _integer(library_id)
            priority_score = _integer(
                priority_score, minimum=-2**31, maximum=2**31 - 1
            )
        except ValueError:
            raise UnmanicHttpError("invalid_unmanic_request") from None
        value = self._call("POST", "/pending/create", {
            "path": path,
            "library_id": library_id,
            "type": "local",
            "priority_score": priority_score,
        })
        task = _task(value)
        if (
            task.path != path
            or task.taskType != "local"
            or task.status != "pending"
            or task.libraryId != library_id
        ):
            raise UnmanicHttpError("unmanic_protocol_changed")
        return task

    def pending_status(self, task_ids):
        requested = _ids(task_ids)
        value = self._call("POST", "/pending/status/get", {
            "id_list": list(requested),
        })
        if set(value) != {"results"} or type(value["results"]) is not list:
            raise UnmanicHttpError("unmanic_protocol_changed")
        if not value["results"] or len(value["results"]) > len(requested):
            raise UnmanicHttpError("unmanic_protocol_changed")
        tasks = tuple(_task(item) for item in value["results"])
        found = tuple(item.id for item in tasks)
        if len(set(found)) != len(found) or not set(found) <= set(requested):
            raise UnmanicHttpError("unmanic_protocol_changed")
        return PendingStatusReadback(
            tasks=tasks,
            missingIds=tuple(value for value in requested if value not in found),
        )

    def delete_pending(self, task_ids):
        task_ids = _ids(task_ids)
        value = self._call("DELETE", "/pending/tasks", {
            "selection_mode": "explicit",
            "id_list": list(task_ids),
        })
        if value != {"success": True}:
            raise UnmanicHttpError("unmanic_protocol_changed")

    def workers_status(self):
        value = self._call("GET", "/workers/status", None)
        if set(value) != {"workers_status"} or type(value["workers_status"]) is not list:
            raise UnmanicHttpError("unmanic_protocol_changed")
        if len(value["workers_status"]) > 128:
            raise UnmanicHttpError("unmanic_protocol_changed")
        result = []
        try:
            for item in value["workers_status"]:
                if type(item) is not dict or set(item) != _WORKER_KEYS:
                    raise ValueError
                worker_id = _text(item["id"], maximum=128)
                name = _text(item["name"], maximum=240)
                if type(item["idle"]) is not bool or type(item["paused"]) is not bool:
                    raise ValueError
                start = item["start_time"]
                if start is not None:
                    start = _text(start, maximum=64)
                    if not math.isfinite(float(start)):
                        raise ValueError
                current_file = _text(item["current_file"], maximum=4096, empty=True)
                current_task = item["current_task"]
                if current_task is not None:
                    current_task = _integer(current_task)
                command = item["current_command"]
                if command is not None:
                    command = _text(command, maximum=16_384, empty=True)
                if (
                    type(item["worker_log_tail"]) is not list
                    or len(item["worker_log_tail"]) > 40
                    or any(type(line) is not str or len(line) > 16_384
                           for line in item["worker_log_tail"])
                    or type(item["runners_info"]) is not dict
                    or type(item["subprocess"]) is not dict
                ):
                    raise ValueError
                result.append(WorkerStatus(
                    id=worker_id,
                    name=name,
                    idle=item["idle"],
                    paused=item["paused"],
                    startTime=start,
                    currentFile=current_file,
                    currentTask=current_task,
                    currentCommand=command,
                ))
            if len({item.id for item in result}) != len(result):
                raise ValueError
            return tuple(result)
        except (KeyError, TypeError, ValueError, OverflowError):
            raise UnmanicHttpError("unmanic_protocol_changed") from None

    @staticmethod
    def worker_for_task(task_id, workers):
        try:
            task_id = _integer(task_id)
            if type(workers) not in (list, tuple) or any(
                type(worker) is not WorkerStatus for worker in workers
            ):
                raise ValueError
        except ValueError:
            raise UnmanicHttpError("invalid_unmanic_request") from None
        matches = [worker for worker in workers if worker.currentTask == task_id]
        if len(matches) > 1:
            raise UnmanicHttpError("unmanic_protocol_changed")
        return matches[0] if matches else None

    def terminate_worker(self, worker_id):
        try:
            worker_id = _text(worker_id, maximum=128)
        except ValueError:
            raise UnmanicHttpError("invalid_unmanic_request") from None
        value = self._call("DELETE", "/workers/worker/terminate", {
            "worker_id": worker_id,
        })
        if value != {"success": True}:
            raise UnmanicHttpError("unmanic_protocol_changed")
