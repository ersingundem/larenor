import hashlib
import hmac
import json

import pytest

from larenor_server.media_archive_actions.terminal_store import (
    UnmanicTerminalStore,
    UnmanicTerminalStoreError,
)


KEY = b"synthetic-unmanic-callback-key!!" * 2
NOW = 1_790_769_700
WORK = "/work/operation-1/source.mkv"


def body(**changes):
    value = {
        "schemaVersion": 1,
        "taskId": 31,
        "taskType": "local",
        "libraryId": 7,
        "sourcePath": WORK,
        "destinationPath": "/work/operation-1/output.mkv",
        "destinationFiles": ["/work/operation-1/output.mkv"],
        "taskSuccess": True,
        "fileMoveProcessesSuccess": True,
        "startTime": NOW - 60.5,
        "finishTime": NOW - 0.5,
        "processedByWorker": "Default-Worker-1",
    }
    value.update(changes)
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def headers(raw, *, nonce="a" * 64, timestamp=NOW, key=KEY):
    derived = hmac.new(key, b"larenor-unmanic-callback-v1", hashlib.sha256).digest()
    signature = hmac.new(
        derived,
        b"v1\n" + str(timestamp).encode() + b"\n" + nonce.encode() + b"\n" + raw,
        hashlib.sha256,
    ).hexdigest()
    return {
        "x-larenor-unmanic-timestamp": str(timestamp),
        "x-larenor-unmanic-nonce": nonce,
        "x-larenor-unmanic-signature": signature,
    }


def directory(tmp_path):
    value = tmp_path / "terminal"
    value.mkdir(mode=0o700)
    return value


def test_authenticated_terminal_is_durable_and_looked_up_by_exact_task_and_path(tmp_path):
    target = directory(tmp_path)
    raw = body()
    with UnmanicTerminalStore(target, KEY, clock=lambda: NOW) as store:
        first = store.ingest(headers(raw), raw)
        duplicate = store.ingest(headers(raw, nonce="b" * 64), raw)
        assert duplicate == first
        assert store.lookup_terminal(31, WORK) == first
        assert store.lookup_terminal(32, WORK) is None
        assert store.lookup_terminal(31, "/work/operation-2/source.mkv") is None

    with UnmanicTerminalStore(target, KEY, clock=lambda: NOW + 1) as reopened:
        assert reopened.lookup_terminal(31, WORK) == first


@pytest.mark.parametrize("kind", ["signature", "timestamp", "body"])
def test_authentication_and_canonical_body_fail_closed(tmp_path, kind):
    raw = body()
    signed = headers(raw)
    if kind == "signature":
        signed["x-larenor-unmanic-signature"] = "0" * 64
    elif kind == "timestamp":
        signed = headers(raw, timestamp=NOW - 301)
    else:
        raw += b" "
    with UnmanicTerminalStore(directory(tmp_path), KEY, clock=lambda: NOW) as store:
        with pytest.raises(UnmanicTerminalStoreError) as caught:
            store.ingest(signed, raw)
    assert caught.value.code in {
        "terminal_callback_unauthorized", "terminal_callback_invalid",
    }


def test_nonce_replay_and_changed_terminal_for_same_task_are_rejected(tmp_path):
    target = directory(tmp_path)
    first = body()
    changed = body(taskSuccess=False)
    with UnmanicTerminalStore(target, KEY, clock=lambda: NOW) as store:
        store.ingest(headers(first), first)
        with pytest.raises(UnmanicTerminalStoreError) as caught:
            store.ingest(headers(changed, nonce="b" * 64), changed)
        assert caught.value.code == "terminal_callback_conflict"

        with pytest.raises(UnmanicTerminalStoreError) as caught:
            store.ingest(headers(changed, nonce="a" * 64), changed)
        assert caught.value.code == "terminal_callback_replayed"
