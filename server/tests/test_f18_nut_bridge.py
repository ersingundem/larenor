import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import stat
import sys
import tempfile
import threading
import time

import pytest

from larenor_server.power_recovery.nut_bridge import (
    NutBridgeConfig,
    NutBridgeError,
    NutBridgeOutbox,
    NutBridgeRuntime,
    NutBridgeWorker,
    FixedUpsc,
    send_notification,
    validate_upsmon_wiring,
)


NOW = 1_788_800_000


def _config(tmp_path):
    state = tmp_path / "state"
    state.mkdir(mode=0o700)
    upsc = tmp_path / "upsc"
    upsc.write_text("#!/bin/sh\nexit 0\n", encoding="ascii")
    upsc.chmod(0o700)
    ca = tmp_path / "core-ca.pem"
    ca.write_text("synthetic CA identity\n", encoding="ascii")
    ca.chmod(0o600)
    source = tmp_path / "nut-bridge.json"
    source.write_text(json.dumps({
        "schemaVersion": 1,
        "sourceId": "ups-main",
        "sourceRevision": 7,
        "sourceToken": "t" * 32,
        "upsName": "rackups@127.0.0.1:3493",
        "coreUrl": "https://core.larenor.invalid:8098",
        "caFile": str(ca),
        "caSha256": hashlib.sha256(ca.read_bytes()).hexdigest(),
        "upsc": str(upsc),
        "upscSha256": hashlib.sha256(upsc.read_bytes()).hexdigest(),
        "stateRoot": str(state),
        "maxEventAgeSeconds": 240,
        "upscTimeoutSeconds": 3,
        "httpTimeoutSeconds": 5,
        "retrySeconds": 2,
        "notifyUser": "nut",
    }), encoding="utf-8")
    source.chmod(0o600)
    return NutBridgeConfig.load(source)


def _accepted(body, *, duplicate=False):
    return {
        "accepted": True,
        "duplicate": duplicate,
        "status": {
            "policy": {
                "sourceId": body["sourceId"],
                "revision": body["sourceRevision"],
            },
            "lastSequence": body["sequence"],
        },
    }


def test_private_config_rejects_arbitrary_endpoint_and_mutable_upsc(tmp_path):
    config = _config(tmp_path)
    assert config.ups_name == "rackups@127.0.0.1:3493"
    source = tmp_path / "nut-bridge.json"
    value = json.loads(source.read_text())
    value["coreUrl"] = "http://127.0.0.1:8098/other"
    source.write_text(json.dumps(value))
    source.chmod(0o600)
    with pytest.raises(NutBridgeError, match="invalid_configuration"):
        NutBridgeConfig.load(source)

    value["coreUrl"] = "https://core.larenor.invalid:8098"
    source.write_text(json.dumps(value))
    source.chmod(0o600)
    config.upsc.write_text("changed", encoding="ascii")
    config.upsc.chmod(0o700)
    with pytest.raises(NutBridgeError, match="invalid_configuration"):
        NutBridgeConfig.load(source)


def test_notify_callback_commits_only_fixed_nut_environment_without_network(tmp_path):
    config = _config(tmp_path)
    outbox = NutBridgeOutbox(config, clock=lambda: NOW)
    notice = outbox.enqueue({
        "UPSNAME": config.ups_name,
        "NOTIFYTYPE": "ONBATT",
        "NOTIFYMSG": "untrusted shell-like $(ignored) payload",
        "FOREIGN": "ignored",
    })
    status = outbox.status()
    assert len(notice) == 32
    assert status == {
        "sourceId": "ups-main",
        "sourceRevision": 7,
        "lastDeliveredSequence": 0,
        "pending": 1,
        "delivered": 0,
        "blocked": None,
    }
    with pytest.raises(NutBridgeError, match="invalid_notification"):
        outbox.enqueue({"UPSNAME": "other@127.0.0.1", "NOTIFYTYPE": "ONBATT"})


def test_runtime_context_releases_worker_lock_when_startup_fails(tmp_path):
    config = _config(tmp_path)
    outbox = NutBridgeOutbox(config, clock=lambda: NOW)
    # The production CLI and hosted UID proof use this context. Failure before
    # socket publication must still release the singleton worker lock.
    with pytest.raises(NutBridgeError):
        with NutBridgeRuntime(
            config, outbox, notify_socket=tmp_path / "missing" / "notify.sock",
            peer_uid=lambda _connection: os.geteuid(),
        ) as runtime:
            lock = runtime._lock
            assert lock >= 0
            runtime.serve(threading.Event())
    assert runtime._lock == -1
    with pytest.raises(OSError):
        os.fstat(lock)
    with NutBridgeRuntime(config, outbox, notify_socket=tmp_path / "notify.sock"):
        pass


def test_notify_ipc_ack_means_durable_enqueue_and_filters_environment(tmp_path):
    config = _config(tmp_path)
    outbox = NutBridgeOutbox(config, clock=lambda: NOW)
    socket_root = Path(tempfile.mkdtemp(
        prefix="lnut-", dir="/private/tmp" if Path("/private/tmp").is_dir() else "/tmp"
    ))
    os.chown(socket_root, os.geteuid(), os.getegid())
    socket_root.chmod(0o770)
    socket_path = socket_root / "notify.sock"
    runtime = NutBridgeRuntime(
        config, outbox, notify_socket=socket_path,
        peer_uid=lambda _connection: os.geteuid(),
    )
    stopped = threading.Event()
    thread = threading.Thread(target=runtime.serve, args=(stopped,), daemon=True)
    thread.start()
    try:
        deadline = time.monotonic() + 2
        while not socket_path.exists():
            assert thread.is_alive() and time.monotonic() < deadline
            time.sleep(0.01)
        notice = send_notification(
            socket_path,
            {
                "UPSNAME": config.ups_name,
                "NOTIFYTYPE": "LOWBATT",
                "NOTIFYMSG": "ignored untrusted text $(command)",
                "FOREIGN_SECRET": "ignored",
            },
            expected_uid=os.geteuid(), expected_gid=os.getegid(),
            peer_uid=lambda _connection: os.geteuid(),
        )
        assert len(notice) == 32
        assert outbox.status()["pending"] == 1
    finally:
        stopped.set()
        thread.join(timeout=2)
        runtime.close()
        shutil.rmtree(socket_root, ignore_errors=True)
    assert not thread.is_alive()
    assert not socket_path.exists()


def test_notify_socket_path_is_published_only_after_listener_is_ready(
    tmp_path, monkeypatch
):
    config = _config(tmp_path)
    outbox = NutBridgeOutbox(config, clock=lambda: NOW)
    socket_root = Path(tempfile.mkdtemp(
        prefix="lnut-", dir="/private/tmp" if Path("/private/tmp").is_dir() else "/tmp"
    ))
    os.chown(socket_root, os.geteuid(), os.getegid())
    socket_root.chmod(0o770)
    socket_path = socket_root / "notify.sock"
    runtime = NutBridgeRuntime(
        config, outbox, notify_socket=socket_path,
        peer_uid=lambda _connection: os.geteuid(),
    )
    stopped = threading.Event()
    chmod_entered = threading.Event()
    allow_ready = threading.Event()
    real_chmod = os.chmod

    def held_chmod(path, mode, *args, **kwargs):
        info = os.stat(path, follow_symlinks=False)
        if stat.S_ISSOCK(info.st_mode) and not chmod_entered.is_set():
            chmod_entered.set()
            assert allow_ready.wait(2)
        return real_chmod(path, mode, *args, **kwargs)

    monkeypatch.setattr(os, "chmod", held_chmod)
    server = threading.Thread(target=runtime.serve, args=(stopped,), daemon=True)
    result = []

    def send_when_published():
        deadline = time.monotonic() + 2
        while not socket_path.exists() and time.monotonic() < deadline:
            time.sleep(0.005)
        try:
            result.append(send_notification(
                socket_path,
                {"UPSNAME": config.ups_name, "NOTIFYTYPE": "LOWBATT"},
                expected_uid=os.geteuid(), expected_gid=os.getegid(),
                peer_uid=lambda _connection: os.geteuid(),
            ))
        except Exception as error:
            result.append(error)

    sender = threading.Thread(target=send_when_published, daemon=True)
    server.start()
    try:
        assert chmod_entered.wait(1)
        sender.start()
        # Keep the bind-to-ready interval open long enough for a prematurely
        # published canonical path to be observed deterministically.
        time.sleep(0.05)
        allow_ready.set()
        sender.join(3)
        assert not sender.is_alive()
        assert len(result) == 1 and isinstance(result[0], str)
        assert len(result[0]) == 32
        assert outbox.status()["pending"] == 1
    finally:
        allow_ready.set()
        stopped.set()
        server.join(timeout=2)
        runtime.close()
        shutil.rmtree(socket_root, ignore_errors=True)


@pytest.mark.parametrize("foreign", ["wrong-mode", "symlink"])
def test_notify_socket_publication_rejects_foreign_canonical_path(
    tmp_path, foreign
):
    config = _config(tmp_path)
    outbox = NutBridgeOutbox(config, clock=lambda: NOW)
    socket_root = Path(tempfile.mkdtemp(
        prefix="lnut-", dir="/private/tmp" if Path("/private/tmp").is_dir() else "/tmp"
    ))
    os.chown(socket_root, os.geteuid(), os.getegid())
    socket_root.chmod(0o770)
    socket_path = socket_root / "notify.sock"
    foreign_listener = None
    if foreign == "wrong-mode":
        foreign_listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        foreign_listener.bind(str(socket_path))
        socket_path.chmod(0o600)
    else:
        target = socket_root / "target"
        target.write_text("not a socket", encoding="ascii")
        socket_path.symlink_to(target)
    runtime = NutBridgeRuntime(
        config, outbox, notify_socket=socket_path,
        peer_uid=lambda _connection: os.geteuid(),
    )
    try:
        with pytest.raises(NutBridgeError, match="bridge_unavailable"):
            runtime.serve(threading.Event())
        assert os.path.lexists(socket_path)
        if foreign == "wrong-mode":
            info = os.stat(socket_path, follow_symlinks=False)
            assert stat.S_ISSOCK(info.st_mode)
            assert stat.S_IMODE(info.st_mode) == 0o600
        else:
            assert socket_path.is_symlink()
    finally:
        runtime.close()
        if foreign_listener is not None:
            foreign_listener.close()
        if os.path.lexists(socket_path):
            socket_path.unlink()
        target = socket_root / "target"
        if target.exists():
            target.unlink()
        socket_root.rmdir()


def test_close_does_not_unlink_successor_socket_identity(tmp_path):
    config = _config(tmp_path)
    outbox = NutBridgeOutbox(config, clock=lambda: NOW)
    socket_root = Path(tempfile.mkdtemp(
        prefix="lnut-", dir="/private/tmp" if Path("/private/tmp").is_dir() else "/tmp"
    ))
    os.chown(socket_root, os.geteuid(), os.getegid())
    socket_root.chmod(0o770)
    socket_path = socket_root / "notify.sock"
    runtime = NutBridgeRuntime(
        config, outbox, notify_socket=socket_path,
        peer_uid=lambda _connection: os.geteuid(),
    )
    successor = None
    try:
        assert runtime._bind_notify() == os.geteuid()
        socket_path.unlink()
        successor = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        successor.bind(str(socket_path))
        socket_path.chmod(0o660)
        replacement = os.stat(socket_path, follow_symlinks=False)

        runtime.close()

        current = os.stat(socket_path, follow_symlinks=False)
        assert (current.st_dev, current.st_ino) == (
            replacement.st_dev, replacement.st_ino
        )
    finally:
        runtime.close()
        if successor is not None:
            successor.close()
        if os.path.lexists(socket_path):
            socket_path.unlink()
        socket_root.rmdir()


def test_worker_uses_actual_upsc_snapshot_and_exact_core_contract(tmp_path):
    config = _config(tmp_path)
    outbox = NutBridgeOutbox(config, clock=lambda: NOW)
    outbox.enqueue({"UPSNAME": config.ups_name, "NOTIFYTYPE": "ONBATT"})
    calls = []

    def upsc(peer, timeout):
        calls.append((peer, timeout))
        return b"battery.charge: 41\nbattery.runtime: 118\nups.status: OB\n"

    sent = []

    def deliver(body, timeout):
        sent.append((body, timeout))
        return _accepted(body)

    result = NutBridgeWorker(
        config, outbox, upsc=upsc, deliver=deliver, clock=lambda: NOW + 1,
    ).run_once()
    assert result == "delivered"
    assert calls == [(config.ups_name, 3)]
    body = sent[0][0]
    assert body == {
        "contractVersion": 1,
        "eventId": body["eventId"],
        "sourceId": "ups-main",
        "sourceRevision": 7,
        "sequence": 1,
        "state": "onBattery",
        "chargePercent": 41,
        "runtimeSeconds": 118,
        "observedAt": NOW + 1,
    }
    assert len(body["eventId"]) == 32
    assert sent[0][1] == 5
    assert outbox.status()["lastDeliveredSequence"] == 1


def test_callback_can_enqueue_during_upsc_and_head_order_is_preserved(tmp_path):
    config = _config(tmp_path)
    outbox = NutBridgeOutbox(config, clock=lambda: NOW)
    outbox.enqueue({"UPSNAME": config.ups_name, "NOTIFYTYPE": "ONBATT"})
    delivered = []

    def upsc(_peer, _timeout):
        outbox.enqueue({"UPSNAME": config.ups_name, "NOTIFYTYPE": "LOWBATT"})
        return b"battery.charge: 9\nbattery.runtime: 30\nups.status: OB LB\n"

    worker = NutBridgeWorker(
        config, outbox, upsc=upsc,
        deliver=lambda body, _timeout: delivered.append(body) or _accepted(body),
        clock=lambda: NOW + 1,
    )
    assert worker.run_once() == "delivered"
    assert worker.run_once() == "delivered"
    assert [(item["sequence"], item["state"]) for item in delivered] == [
        (1, "lowBattery"), (2, "lowBattery")
    ]


def test_lost_ack_restart_retries_exact_body_without_rereading_upsc(tmp_path):
    config = _config(tmp_path)
    outbox = NutBridgeOutbox(config, clock=lambda: NOW)
    outbox.enqueue({"UPSNAME": config.ups_name, "NOTIFYTYPE": "ONLINE"})
    reads = []
    bodies = []

    def upsc(*_args):
        reads.append(True)
        return b"battery.charge: 95\nbattery.runtime: 999\nups.status: OL\n"

    def lost(body, _timeout):
        bodies.append(body)
        raise NutBridgeError("delivery_unavailable", retryable=True)

    first = NutBridgeWorker(
        config, outbox, upsc=upsc, deliver=lost, clock=lambda: NOW + 1,
    )
    assert first.run_once() == "retry"
    reopened = NutBridgeOutbox(config, clock=lambda: NOW + 100)
    second = NutBridgeWorker(
        config, reopened,
        upsc=lambda *_args: (_ for _ in ()).throw(AssertionError("must not reread")),
        deliver=lambda body, _timeout: bodies.append(body) or _accepted(body, duplicate=True),
        clock=lambda: NOW + 100,
    )
    assert second.run_once() == "delivered"
    assert reads == [True]
    assert bodies[0] == bodies[1]
    assert bodies[1]["runtimeSeconds"] == 0


def test_expired_unsampled_head_blocks_later_events_without_sequence_gap(tmp_path):
    config = _config(tmp_path)
    outbox = NutBridgeOutbox(config, clock=lambda: NOW)
    outbox.enqueue({"UPSNAME": config.ups_name, "NOTIFYTYPE": "ONBATT"})
    outbox.enqueue({"UPSNAME": config.ups_name, "NOTIFYTYPE": "ONLINE"})
    worker = NutBridgeWorker(
        config, outbox,
        upsc=lambda *_args: (_ for _ in ()).throw(NutBridgeError("upsc_unavailable", retryable=True)),
        deliver=lambda *_args: (_ for _ in ()).throw(AssertionError("no delivery")),
        clock=lambda: NOW + 241,
    )
    assert worker.run_once() == "blocked"
    status = outbox.status()
    assert status["lastDeliveredSequence"] == 0
    assert status["pending"] == 2
    assert status["blocked"] == "event_expired"


def test_core_conflict_blocks_exact_body_instead_of_advancing(tmp_path):
    config = _config(tmp_path)
    outbox = NutBridgeOutbox(config, clock=lambda: NOW)
    outbox.enqueue({"UPSNAME": config.ups_name, "NOTIFYTYPE": "LOWBATT"})
    worker = NutBridgeWorker(
        config, outbox,
        upsc=lambda *_args: b"battery.charge: 5\nbattery.runtime: 20\nups.status: OB LB\n",
        deliver=lambda *_args: (_ for _ in ()).throw(
            NutBridgeError("delivery_conflict", retryable=False)),
        clock=lambda: NOW + 1,
    )
    assert worker.run_once() == "blocked"
    assert outbox.status()["blocked"] == "delivery_conflict"
    assert outbox.status()["lastDeliveredSequence"] == 0


def test_source_revision_has_an_independent_sequence_database(tmp_path):
    first = _config(tmp_path)
    outbox = NutBridgeOutbox(first, clock=lambda: NOW)
    outbox.enqueue({"UPSNAME": first.ups_name, "NOTIFYTYPE": "ONLINE"})
    value = json.loads((tmp_path / "nut-bridge.json").read_text())
    value["sourceRevision"] = 8
    (tmp_path / "nut-bridge.json").write_text(json.dumps(value))
    (tmp_path / "nut-bridge.json").chmod(0o600)
    second = NutBridgeConfig.load(tmp_path / "nut-bridge.json")
    other = NutBridgeOutbox(second, clock=lambda: NOW)
    assert other.status()["lastDeliveredSequence"] == 0
    assert other.status()["pending"] == 0
    assert outbox.status()["pending"] == 1


def test_storage_schema_trigger_or_application_identity_tamper_fails_closed(tmp_path):
    config = _config(tmp_path)
    outbox = NutBridgeOutbox(config, clock=lambda: NOW)
    with outbox._connect() as connection:
        connection.execute(
            "CREATE TRIGGER unexpected AFTER INSERT ON notices BEGIN "
            "UPDATE metadata SET last_sequence=99 WHERE id=1; END"
        )
    with pytest.raises(NutBridgeError, match="bridge_unavailable"):
        NutBridgeOutbox(config, clock=lambda: NOW)


def test_integral_decimal_nut_values_are_supported_without_rounding(tmp_path):
    config = _config(tmp_path)
    outbox = NutBridgeOutbox(config, clock=lambda: NOW)
    outbox.enqueue({"UPSNAME": config.ups_name, "NOTIFYTYPE": "ONBATT"})
    sent = []
    worker = NutBridgeWorker(
        config, outbox,
        upsc=lambda *_args: (
            b"battery.charge: 41.0\nbattery.runtime: 118.00\nups.status: OB\n"
        ),
        deliver=lambda body, _timeout: sent.append(body) or _accepted(body),
        clock=lambda: NOW,
    )
    assert worker.run_once() == "delivered"
    assert (sent[0]["chargePercent"], sent[0]["runtimeSeconds"]) == (41, 118)


@pytest.mark.skipif(sys.platform != "linux", reason="/proc descriptor execution is Linux-only")
def test_pinned_upsc_executes_the_open_verified_descriptor_on_linux(tmp_path):
    config = _config(tmp_path)
    config.upsc.write_text(
        "#!/bin/sh\nprintf 'battery.charge: 90\\nbattery.runtime: 500\\nups.status: OL\\n'\n",
        encoding="ascii",
    )
    config.upsc.chmod(0o700)
    source = tmp_path / "nut-bridge.json"
    value = json.loads(source.read_text())
    value["upscSha256"] = hashlib.sha256(config.upsc.read_bytes()).hexdigest()
    source.write_text(json.dumps(value))
    source.chmod(0o600)
    current = NutBridgeConfig.load(source)
    assert FixedUpsc(current)(current.ups_name, 3).endswith(b"ups.status: OL\n")


def test_upsmon_wiring_requires_fixed_wrapper_monitor_and_exec_flags(tmp_path):
    config = _config(tmp_path)
    upsmon = tmp_path / "upsmon.conf"
    upsmon.write_text(
        "MONITOR rackups@127.0.0.1:3493 1 monitor secret secondary\n"
        "NOTIFYCMD /usr/libexec/larenor-nut-notify\n"
        "NOTIFYFLAG ONLINE SYSLOG+EXEC\n"
        "NOTIFYFLAG ONBATT SYSLOG+WALL+EXEC\n"
        "NOTIFYFLAG LOWBATT SYSLOG+EXEC\n",
        encoding="utf-8",
    )
    upsmon.chmod(0o600)
    validate_upsmon_wiring(config, upsmon)

    upsmon.write_text(upsmon.read_text().replace("SYSLOG+EXEC", "SYSLOG", 1))
    upsmon.chmod(0o600)
    with pytest.raises(NutBridgeError, match="invalid_configuration"):
        validate_upsmon_wiring(config, upsmon)


def test_upsmon_wiring_rejects_notify_command_arguments(tmp_path):
    config = _config(tmp_path)
    upsmon = tmp_path / "upsmon.conf"
    upsmon.write_text(
        "MONITOR rackups@127.0.0.1:3493 1 monitor secret secondary\n"
        "NOTIFYCMD '/usr/libexec/larenor-nut-notify --other'\n"
        "NOTIFYFLAG ONLINE EXEC\nNOTIFYFLAG ONBATT EXEC\n"
        "NOTIFYFLAG LOWBATT EXEC\n",
        encoding="utf-8",
    )
    upsmon.chmod(0o600)
    with pytest.raises(NutBridgeError, match="invalid_configuration"):
        validate_upsmon_wiring(config, upsmon)
