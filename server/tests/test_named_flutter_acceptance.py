"""A green process must not hide skipped or unrelated acceptance tests."""

import json
import os
import sys

import pytest

from support.named_flutter_acceptance import (
    NamedFlutterAcceptanceError, run_named_flutter, validate_machine,
)


NAME = "owned normal Core acceptance"
LOADING = "loading /owned/test/fixture_test.dart"


def _events():
    return [
        {"type": "testStart", "test": {"id": 0, "name": LOADING}},
        {"type": "testDone", "testID": 0, "result": "success", "skipped": False,
         "hidden": True},
        {"type": "testStart", "test": {"id": 1, "name": NAME}},
        {"type": "testDone", "testID": 1, "result": "success", "skipped": False,
         "hidden": False},
        {"type": "done", "success": True},
    ]


def _raw(events):
    return ("\n".join(json.dumps(event) for event in events) + "\n").encode()


def test_named_success_counts_only_real_test_not_loading():
    assert validate_machine(_raw(_events()), test_name=NAME, loading_name=LOADING) == {
        "tests": 1, "passed": 1, "failures": 0, "errors": 0, "skipped": 0,
    }


def test_actual_flutter_lifecycle_and_started_process_envelope():
    events = _events()
    events.insert(0, [{"event": "test.startedProcess", "params": {"vmServiceUri": None}}])
    events.insert(3, {"type": "testStart", "test": {"id": 2, "name": "(setUpAll)"}})
    events.insert(4, {"type": "testDone", "testID": 2, "result": "success",
                      "skipped": False, "hidden": True})
    events.insert(-1, {"type": "testStart", "test": {"id": 3, "name": "(tearDownAll)"}})
    events.insert(-1, {"type": "testDone", "testID": 3, "result": "success",
                      "skipped": False, "hidden": True})
    assert validate_machine(_raw(events), test_name=NAME, loading_name=LOADING)["passed"] == 1
    events[0][0]["params"]["extra"] = "untrusted"
    with pytest.raises(NamedFlutterAcceptanceError):
        validate_machine(_raw(events), test_name=NAME, loading_name=LOADING)


@pytest.mark.parametrize("mutation", [
    "skip", "failure", "hidden_real", "hidden_other", "duplicate_terminal",
    "duplicate_test", "wrong_name", "missing_done", "false_done", "error",
])
def test_green_process_cannot_mask_invalid_acceptance(mutation):
    events = _events()
    if mutation == "skip":
        events[3]["skipped"] = True
    elif mutation == "failure":
        events[3]["result"] = "failure"
    elif mutation == "hidden_real":
        events[3]["hidden"] = True
    elif mutation == "hidden_other":
        events[0]["test"]["name"] = "loading /other.dart"
    elif mutation == "duplicate_terminal":
        events.append(events[-1])
    elif mutation == "duplicate_test":
        events.insert(4, events[3])
    elif mutation == "wrong_name":
        events[2]["test"]["name"] = "unrelated test"
    elif mutation == "missing_done":
        events.pop()
    elif mutation == "false_done":
        events[-1]["success"] = False
    elif mutation == "error":
        events.insert(4, {"type": "error", "error": "private provider value"})
    with pytest.raises(NamedFlutterAcceptanceError) as error:
        validate_machine(_raw(events), test_name=NAME, loading_name=LOADING)
    assert "private provider value" not in str(error.value)


def test_report_rejects_duplicate_json_keys_and_non_json():
    for raw in (b'{"type":"done","type":"print","success":true}\n',
                b'private stderr value\n', b''):
        with pytest.raises(NamedFlutterAcceptanceError):
            validate_machine(raw, test_name=NAME, loading_name=LOADING)


def test_actual_subprocess_keeps_machine_log_private_and_rejects_skipped(tmp_path, monkeypatch):
    test_file = "test/fixture_test.dart"
    (tmp_path / "test").mkdir()
    (tmp_path / test_file).write_text("// owned fixture")
    events = _events()
    events[0]["test"]["name"] = "loading " + str(tmp_path / test_file)
    events[3]["skipped"] = True
    executable = tmp_path / "flutter"
    executable.write_text("#!" + sys.executable + "\nimport sys\nsys.stdout.write(" +
                          repr(_raw(events).decode()) + ")\n")
    executable.chmod(0o700)
    monkeypatch.setenv("PATH", str(tmp_path) + os.pathsep + os.environ["PATH"])
    log = tmp_path / "private-machine.jsonl"
    with pytest.raises(NamedFlutterAcceptanceError, match="report_invalid"):
        run_named_flutter(test_file=test_file, test_name=NAME,
                          env=dict(os.environ), cwd=tmp_path, log_path=log)
    assert log.stat().st_mode & 0o777 == 0o600
    assert log.read_bytes() == _raw(events)
    original = log.read_bytes()
    with pytest.raises(FileExistsError):
        run_named_flutter(test_file=test_file, test_name=NAME,
                          env=dict(os.environ), cwd=tmp_path, log_path=log)
    assert log.read_bytes() == original


def test_timeout_retires_child_after_flutter_leader_already_exited(tmp_path, monkeypatch):
    (tmp_path / "test").mkdir()
    (tmp_path / "test/fixture_test.dart").write_text("// owned fixture")
    marker = tmp_path / "child-retired"
    ready = tmp_path / "child-ready"
    executable = tmp_path / "flutter"
    executable.write_text(
        "#!" + sys.executable + "\n"
        "import os, signal, time\n"
        "from pathlib import Path\n"
        "pid = os.fork()\n"
        "if pid == 0:\n"
        " def retired(*_):\n"
        "  Path(" + repr(str(marker)) + ").write_text('retired')\n"
        "  os._exit(0)\n"
        " signal.signal(signal.SIGTERM, retired)\n"
        " Path(" + repr(str(ready)) + ").write_text('ready')\n"
        " time.sleep(60)\n"
        "else:\n"
        " while not Path(" + repr(str(ready)) + ").exists(): time.sleep(.01)\n"
        " os._exit(0)\n"
    )
    executable.chmod(0o700)
    monkeypatch.setenv("PATH", str(tmp_path) + os.pathsep + os.environ["PATH"])
    with pytest.raises(NamedFlutterAcceptanceError, match="named_flutter_timeout"):
        run_named_flutter(test_file="test/fixture_test.dart", test_name=NAME,
                          env=dict(os.environ), cwd=tmp_path,
                          log_path=tmp_path / "private-machine.jsonl", timeout_seconds=1)
    assert ready.read_text() == "ready"
    assert marker.read_text() == "retired"
