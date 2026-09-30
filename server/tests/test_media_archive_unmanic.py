import json

import pytest

from larenor_server.media_archive_actions.unmanic import (
    UnmanicAdapter,
    UnmanicHttpError,
    UnmanicResponse,
    UnmanicWorkBinding,
    parse_terminal_callback,
)


PATH = "/library/Films/A Film (2026).mkv"


class Exchange:
    def __init__(self, *responses):
        self.responses = list(responses)
        self.requests = []

    def __call__(self, request, deadline):
        self.requests.append((request, deadline))
        return self.responses.pop(0)


def response(value, status=200):
    return UnmanicResponse(
        status=status,
        contentType='application/json; charset="utf-8"',
        body=json.dumps(value, separators=(",", ":")).encode(),
    )


def body(exchange, index=-1):
    return json.loads(exchange.requests[index][0].body)


def test_pending_test_and_create_pin_the_041_shapes():
    exchange = Exchange(
        response({
            "path": PATH,
            "library_id": 7,
            "library_name": "Films",
            "add_file_to_pending_tasks": True,
            "issues": [],
            "decision_plugin": {
                "plugin_id": "video_transcoder",
                "plugin_name": "Video Transcoder",
            },
        }),
        response({
            "id": 31,
            "abspath": PATH,
            "priority": 1031,
            "type": "local",
            "status": "pending",
            "library_id": 7,
        }),
    )
    adapter = UnmanicAdapter(exchange, clock=lambda: 10.0)

    tested = adapter.test_path(PATH, library_id=7)
    created = adapter.create_local_task(PATH, library_id=7, priority_score=1000)

    assert tested.shouldQueue is True
    assert tested.decisionPluginId == "video_transcoder"
    assert created.id == 31
    assert created.status == "pending"
    assert [(item[0].method, item[0].path) for item in exchange.requests] == [
        ("POST", "/unmanic/api/v2/pending/test"),
        ("POST", "/unmanic/api/v2/pending/create"),
    ]
    assert body(exchange, 0) == {"library_id": 7, "path": PATH}
    assert body(exchange, 1) == {
        "library_id": 7,
        "path": PATH,
        "priority_score": 1000,
        "type": "local",
    }


def test_status_reports_partial_absence_without_calling_it_terminal_success():
    exchange = Exchange(response({
        "results": [{
            "id": 31,
            "abspath": PATH,
            "priority": 1031,
            "type": "local",
            "status": "in_progress",
        }],
    }))
    adapter = UnmanicAdapter(exchange, clock=lambda: 10.0)

    readback = adapter.pending_status([31, 32])

    assert [item.id for item in readback.tasks] == [31]
    assert readback.missingIds == (32,)
    assert readback.terminal is False
    assert body(exchange) == {"id_list": [31, 32]}


def test_delete_and_worker_terminate_use_delete_bodies_and_only_ack_dispatch():
    exchange = Exchange(
        response({"success": True}),
        response({"success": True}),
    )
    adapter = UnmanicAdapter(exchange, clock=lambda: 10.0)

    adapter.delete_pending([31])
    adapter.terminate_worker("Default-0")

    assert [(item[0].method, item[0].path) for item in exchange.requests] == [
        ("DELETE", "/unmanic/api/v2/pending/tasks"),
        ("DELETE", "/unmanic/api/v2/workers/worker/terminate"),
    ]
    assert body(exchange, 0) == {
        "id_list": [31],
        "selection_mode": "explicit",
    }
    assert body(exchange, 1) == {"worker_id": "Default-0"}


def test_worker_status_is_typed_and_requires_unique_task_ownership():
    exchange = Exchange(response({
        "workers_status": [{
            "id": "Default-0",
            "name": "Default-Worker-1",
            "idle": False,
            "paused": False,
            "start_time": "1790769600.5",
            "current_file": "A Film (2026).mkv",
            "current_task": 31,
            "current_command": "ffmpeg -i input output",
            "worker_log_tail": ["frame=12"],
            "runners_info": {"video_transcoder": {"status": "in_progress"}},
            "subprocess": {"pid": 123, "percent": 4.2, "elapsed": 3.0},
        }],
    }))
    adapter = UnmanicAdapter(exchange, clock=lambda: 10.0)

    workers = adapter.workers_status()

    assert workers[0].currentTask == 31
    assert exchange.requests[0][0].body == b""
    assert exchange.requests[0][0].headers == (("Accept", "application/json"),)
    assert adapter.worker_for_task(31, workers).id == "Default-0"
    assert adapter.worker_for_task(99, workers) is None


@pytest.mark.parametrize(
    "payload",
    [
        {"success": True, "results": []},
        {"results": []},
        {"results": [{"id": True, "abspath": PATH, "priority": 1,
                      "type": "local", "status": "pending"}]},
    ],
)
def test_status_rejects_changed_or_semantically_empty_contract(payload):
    adapter = UnmanicAdapter(Exchange(response(payload)), clock=lambda: 10.0)

    with pytest.raises(UnmanicHttpError) as caught:
        adapter.pending_status([31])

    assert caught.value.code == "unmanic_protocol_changed"
    assert repr(caught.value) == "UnmanicHttpError('unmanic_protocol_changed')"


def test_non_200_and_expired_deadline_fail_closed_without_upstream_details():
    rejected = UnmanicAdapter(
        Exchange(response({"error": "500: raw private path", "messages": {}}, 500)),
        clock=lambda: 10.0,
    )
    with pytest.raises(UnmanicHttpError) as caught:
        rejected.pending_status([31])
    assert caught.value.code == "unmanic_upstream_rejected"
    assert "private" not in str(caught.value)

    ticks = iter((10.0, 15.0))
    expired = UnmanicAdapter(
        Exchange(response({"success": True})), timeout=4.0,
        clock=lambda: next(ticks),
    )
    with pytest.raises(UnmanicHttpError) as caught:
        expired.delete_pending([31])
    assert caught.value.code == "unmanic_deadline_exceeded"


@pytest.mark.parametrize("path", ["relative.mkv", "/library/../secret", "/", "/bad\x00path"])
def test_paths_are_absolute_normalized_and_bounded(path):
    adapter = UnmanicAdapter(Exchange(), clock=lambda: 10.0)

    with pytest.raises(UnmanicHttpError) as caught:
        adapter.create_local_task(path, library_id=7)

    assert caught.value.code == "invalid_unmanic_request"


def test_duplicate_worker_ownership_is_a_protocol_failure():
    workers = [{
        "id": suffix,
        "name": suffix,
        "idle": False,
        "paused": False,
        "start_time": "1.0",
        "current_file": "a.mkv",
        "current_task": 31,
        "current_command": "",
        "worker_log_tail": [],
        "runners_info": {},
        "subprocess": {},
    } for suffix in ("a-0", "b-0")]
    adapter = UnmanicAdapter(
        Exchange(response({"workers_status": workers})), clock=lambda: 10.0
    )

    values = adapter.workers_status()
    with pytest.raises(UnmanicHttpError) as caught:
        adapter.worker_for_task(31, values)
    assert caught.value.code == "unmanic_protocol_changed"


def terminal(**changes):
    value = {
        "schemaVersion": 1,
        "taskId": 31,
        "taskType": "local",
        "libraryId": 7,
        "sourcePath": "/work/operation-1/source.mkv",
        "destinationPath": "/work/operation-1/output.mkv",
        "destinationFiles": ["/work/operation-1/output.mkv"],
        "taskSuccess": True,
        "fileMoveProcessesSuccess": True,
        "startTime": 1790769600.5,
        "finishTime": 1790769660.5,
        "processedByWorker": "Default-Worker-1",
    }
    value.update(changes)
    return value


def test_terminal_callback_requires_both_success_signals_and_discards_log():
    succeeded = parse_terminal_callback(terminal())
    failed = parse_terminal_callback(terminal(fileMoveProcessesSuccess=False))

    assert succeeded.providerTaskId == 31
    assert succeeded.workPath == "/work/operation-1/source.mkv"
    assert succeeded.terminal == "succeeded"
    assert failed.terminal == "failed"
    with pytest.raises(UnmanicHttpError):
        parse_terminal_callback(terminal(log="private ffmpeg output"))


def test_work_binding_accepts_only_internal_normalized_paths():
    assert UnmanicWorkBinding(
        path="/work/operation-1/source.mkv", libraryId=7
    ).libraryId == 7
    with pytest.raises(UnmanicHttpError):
        UnmanicWorkBinding(path="/work/../outside.mkv", libraryId=7)
