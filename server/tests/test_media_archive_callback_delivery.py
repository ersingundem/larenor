import hashlib
import http.server
import json
import socket
import sqlite3
import threading
import time

import pytest

from larenor_server.media_archive_actions.callback_plugin import (
    CallbackOutboxError,
    UnmanicCallbackOutbox,
)
from larenor_server.media_archive_actions.callback_server import UnmanicCallbackServer
from larenor_server.media_archive_actions.terminal_store import UnmanicTerminalStore
from test_media_archive_unmanic_terminal_store import KEY, NOW


def unused_port():
    with socket.socket() as stream:
        stream.bind(('127.0.0.1', 0))
        return stream.getsockname()[1]


def setup(tmp_path):
    paths = {}
    for name in ('outbox', 'work', 'terminal'):
        paths[name] = tmp_path / name
        paths[name].mkdir(mode=0o700)
    return paths, unused_port()


def event(work, **changes):
    result = {
        'task_id': 31, 'library_id': 7, 'task_type': 'local',
        'source_data': {'abspath': str(work / 'job/source.mkv')},
        'destination_data': {'abspath': str(work / 'job/output.mkv')},
        'destination_files': [str(work / 'job/output.mkv')],
        'task_success': True, 'file_move_processes_success': True,
        'start_time': NOW - 60.5, 'finish_time': NOW - 0.5,
        'processed_by_worker': 'Default-Worker-1',
        'log': 'sensitive upstream log must never leave plugin',
    }
    result.update(changes)
    return result


def outbox(paths, port):
    return UnmanicCallbackOutbox(paths['outbox'], KEY, paths['work'], port, clock=lambda: NOW)


def test_real_signed_delivery_is_durable_before_removal_and_reopens(tmp_path):
    paths, port = setup(tmp_path)
    value = event(paths['work'])
    sender = outbox(paths, port)
    try:
        digest = sender.enqueue(value)
        assert sender.enqueue(value) == digest
        assert sender.pending() == 1
        with UnmanicTerminalStore(paths['terminal'], KEY, clock=lambda: NOW) as store:
            with UnmanicCallbackServer(store, port):
                assert sender.flush_one() is True
                assert sender.pending() == 0
                receipt = store.lookup_terminal(31, value['source_data']['abspath'])
                assert receipt.callbackDigest == digest
                assert receipt.taskSuccess is True
    finally:
        sender.close()
    with UnmanicTerminalStore(paths['terminal'], KEY, clock=lambda: NOW) as reopened:
        assert reopened.lookup_terminal(31, value['source_data']['abspath']) == receipt
    connection = sqlite3.connect(paths['terminal'] / 'unmanic-terminal.sqlite')
    try:
        body = connection.execute('SELECT body FROM callbacks').fetchone()[0]
        assert b'sensitive upstream log' not in body
    finally:
        connection.close()


def test_failed_upstream_task_without_destinations_delivers_terminal_failure(tmp_path):
    paths, port = setup(tmp_path)
    value = event(paths['work'], task_success=False, destination_files=[])
    sender = outbox(paths, port)
    try:
        sender.enqueue(value)
        with UnmanicTerminalStore(paths['terminal'], KEY, clock=lambda: NOW) as store:
            with UnmanicCallbackServer(store, port):
                assert sender.flush_one() is True
            proof = store.lookup_terminal(31, value['source_data']['abspath'])
            assert proof.terminal == 'failed' and proof.destinationFiles == ()
            assert sender.pending() == 0
    finally:
        sender.close()


def test_receiver_down_then_process_restart_retries_without_new_event(tmp_path):
    paths, port = setup(tmp_path)
    value = event(paths['work'])
    sender = outbox(paths, port)
    sender.enqueue(value)
    assert sender.flush_one() is False
    assert sender.pending() == 1
    sender.close()
    reopened = outbox(paths, port)
    try:
        with UnmanicTerminalStore(paths['terminal'], KEY, clock=lambda: NOW) as store:
            with UnmanicCallbackServer(store, port):
                reopened.start()
                deadline = time.monotonic() + 3
                while reopened.pending() and time.monotonic() < deadline:
                    time.sleep(0.01)
                assert reopened.pending() == 0
                assert store.lookup_terminal(31, value['source_data']['abspath']) is not None
    finally:
        reopened.close()


def test_lost_ack_retries_identical_callback_without_duplicate_terminal(tmp_path):
    paths, port = setup(tmp_path)
    sender = outbox(paths, port)
    value = event(paths['work'])
    digest = sender.enqueue(value)
    try:
        with UnmanicTerminalStore(paths['terminal'], KEY, clock=lambda: NOW) as store:
            # Simulate a previously admitted delivery whose ACK was lost.
            row = sender._db.execute('SELECT body FROM outbox').fetchone()
            from test_media_archive_unmanic_terminal_store import headers
            receipt = store.ingest(headers(row[0]), row[0])
            with UnmanicCallbackServer(store, port):
                assert sender.flush_one() is True
            assert receipt.callbackDigest == digest
            assert store._db.execute('SELECT COUNT(*) FROM callbacks').fetchone()[0] == 1
    finally:
        sender.close()


def test_forged_plaintext_ack_never_discards_durable_callback(tmp_path):
    paths, port = setup(tmp_path)
    sender = outbox(paths, port)
    digest = sender.enqueue(event(paths['work']))

    class ForgedAck(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            self.rfile.read(int(self.headers['Content-Length']))
            body = json.dumps({'schemaVersion': 1, 'acceptedDigest': digest,
                'nonce': self.headers['X-Larenor-Unmanic-Nonce'], 'signature': '0'*64}).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_args):
            pass

    server = http.server.HTTPServer(('127.0.0.1', port), ForgedAck)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        assert sender.flush_one() is False
        assert sender.pending() == 1
    finally:
        server.shutdown()
        thread.join(2)
        server.server_close()
        sender.close()


@pytest.mark.parametrize('change', [
    {'source_data': {'abspath': '/outside/source.mkv'}},
    {'task_success': 1},
    {'destination_files': [{'abspath': '/bad'}]},
])
def test_invalid_upstream_event_is_not_signed_or_persisted(tmp_path, change):
    paths, port = setup(tmp_path)
    sender = outbox(paths, port)
    try:
        with pytest.raises(CallbackOutboxError, match='^archive_callback_unavailable$'):
            sender.enqueue(event(paths['work'], **change))
        assert sender.pending() == 0
    finally:
        sender.close()


def test_conflicting_terminal_event_rejected_before_a_second_row(tmp_path):
    paths, port = setup(tmp_path)
    sender = outbox(paths, port)
    try:
        sender.enqueue(event(paths['work']))
        with pytest.raises(CallbackOutboxError):
            sender.enqueue(event(paths['work'], task_success=False))
        assert sender.pending() == 1
    finally:
        sender.close()


def test_tampered_outbox_is_rejected_after_reopen(tmp_path):
    paths, port = setup(tmp_path)
    sender = outbox(paths, port)
    sender.enqueue(event(paths['work']))
    sender._db.execute("UPDATE outbox SET signature=?", ('0'*64,))
    sender.close()
    with pytest.raises(CallbackOutboxError, match='^archive_callback_unavailable$'):
        outbox(paths, port)


def test_replaced_lock_file_and_foreign_key_fail_closed(tmp_path):
    paths, port = setup(tmp_path)
    sender = outbox(paths, port)
    sender.enqueue(event(paths['work']))
    sender.close()
    with pytest.raises(CallbackOutboxError):
        UnmanicCallbackOutbox(paths['outbox'], b'x'*32, paths['work'], port)
    sender = outbox(paths, port)
    try:
        sender.lock_path.rename(sender.lock_path.with_suffix('.old'))
        sender.lock_path.write_bytes(b'')
        sender.lock_path.chmod(0o600)
        with pytest.raises(CallbackOutboxError):
            sender.pending()
    finally:
        sender.close()
