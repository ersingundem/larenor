"""Run exactly one opt-in Client acceptance without accepting skipped tests."""

import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import time


MAX_REPORT_BYTES = 8 * 1024 * 1024


class NamedFlutterAcceptanceError(RuntimeError):
    """Closed error codes; private machine output must never enter exceptions."""


def _pairs(values):
    result = {}
    for key, value in values:
        if key in result:
            raise ValueError("duplicate_key")
        result[key] = value
    return result


def validate_machine(raw, *, test_name, loading_name):
    if not raw or len(raw) > MAX_REPORT_BYTES:
        raise NamedFlutterAcceptanceError("named_flutter_report_size")
    started = {}
    finished = set()
    visible = 0
    done = False
    process_event = False
    hidden_names = {loading_name, "(setUpAll)", "(tearDownAll)"}
    try:
        for line in raw.decode("utf-8").splitlines():
            if not line.strip():
                continue
            event = json.loads(line, object_pairs_hook=_pairs)
            if type(event) is list:
                if (done or process_event or len(event) != 1
                        or type(event[0]) is not dict
                        or set(event[0]) != {"event", "params"}
                        or event[0]["event"] != "test.startedProcess"
                        or event[0]["params"] != {"vmServiceUri": None}):
                    raise ValueError("process_event")
                process_event = True
                continue
            if type(event) is not dict or done:
                raise ValueError("event_order")
            kind = event.get("type")
            if kind == "testStart":
                test = event["test"]
                identifier = test["id"]
                name = test["name"]
                if (type(identifier) is not int or identifier < 0
                        or identifier in started or name not in (hidden_names | {test_name})
                        or name in started.values() or len(started) >= 4):
                    raise ValueError("test_identity")
                started[identifier] = name
            elif kind == "testDone":
                identifier = event["testID"]
                if (type(identifier) is not int or identifier not in started
                        or identifier in finished or event.get("result") != "success"
                        or event.get("skipped") is not False
                        or type(event.get("hidden")) is not bool):
                    raise ValueError("test_result")
                hidden = event["hidden"]
                if hidden != (started[identifier] in hidden_names):
                    raise ValueError("hidden_identity")
                finished.add(identifier)
                visible += not hidden
            elif kind == "done":
                if (event.get("success") is not True or finished != set(started)
                        or visible != 1):
                    raise ValueError("terminal_result")
                done = True
            elif kind == "error":
                raise ValueError("test_error")
            elif kind not in ("start", "suite", "group", "print", "debug", "allSuites"):
                raise ValueError("unknown_event")
    except (ValueError, KeyError, TypeError, UnicodeError):
        raise NamedFlutterAcceptanceError("named_flutter_report_invalid") from None
    if not done:
        raise NamedFlutterAcceptanceError("named_flutter_report_incomplete")
    return {"tests": 1, "passed": 1, "failures": 0, "errors": 0, "skipped": 0}


def _stop_owned(process):
    # start_new_session makes this PGID private. The leader may already be
    # terminal while a descendant still retains our stdout pipe.
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        process.poll()
        try:
            os.killpg(process.pid, 0)
        except ProcessLookupError:
            break
        time.sleep(0.02)
    else:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    process.wait(timeout=3)


def run_named_flutter(*, test_file: str, test_name: str, env: dict[str, str],
                      cwd: Path, log_path: Path, timeout_seconds: int = 180):
    cwd = Path(cwd).resolve(strict=True)
    relative = Path(test_file)
    if (relative.is_absolute() or ".." in relative.parts
            or not test_file.endswith("_test.dart") or not test_name
            or type(timeout_seconds) is not int or not 1 <= timeout_seconds <= 600):
        raise NamedFlutterAcceptanceError("named_flutter_options_invalid")
    test_path = (cwd / relative).resolve(strict=True)
    if not test_path.is_relative_to(cwd):
        raise NamedFlutterAcceptanceError("named_flutter_options_invalid")
    descriptor = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                         0o600)
    process = None
    chunks = []
    size = 0
    try:
        with os.fdopen(descriptor, "wb") as log:
            process = subprocess.Popen(
                ["flutter", "test", "--no-pub", "--machine", test_file],
                cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                start_new_session=True,
            )
            deadline = time.monotonic() + timeout_seconds
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ)
                while selector.get_map():
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise NamedFlutterAcceptanceError("named_flutter_timeout")
                    for key, _ in selector.select(min(remaining, 0.25)):
                        chunk = os.read(key.fileobj.fileno(), 65536)
                        if not chunk:
                            selector.unregister(key.fileobj)
                            continue
                        size += len(chunk)
                        if size > MAX_REPORT_BYTES:
                            raise NamedFlutterAcceptanceError("named_flutter_report_size")
                        chunks.append(chunk)
                        log.write(chunk)
            log.flush()
            os.fsync(log.fileno())
            try:
                returncode = process.wait(timeout=max(0.1, deadline - time.monotonic()))
            except subprocess.TimeoutExpired:
                raise NamedFlutterAcceptanceError("named_flutter_timeout") from None
        if returncode != 0:
            raise NamedFlutterAcceptanceError("named_flutter_process_failed")
        return validate_machine(b"".join(chunks), test_name=test_name,
                                loading_name="loading " + str(test_path))
    except OSError:
        raise NamedFlutterAcceptanceError("named_flutter_process_unavailable") from None
    finally:
        if process is not None:
            _stop_owned(process)
            if process.stdout is not None:
                process.stdout.close()
