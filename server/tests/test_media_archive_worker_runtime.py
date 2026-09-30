from contextlib import contextmanager
from dataclasses import asdict
import http.server
import json
import os
import shutil
import socket
import sys
import threading
import tempfile

import pytest

from larenor_server.media_archive_actions.worker_ipc import MediaArchiveActionWorkerClient
from larenor_server.media_archive_actions.worker_runtime import (
    ArchiveWorkerRuntime, ArchiveWorkerRuntimeConfig, ArchiveWorkerRuntimeError,
)
from larenor_server.plugins.media_archive_worker_ipc import MediaArchiveWorkerClient


@pytest.fixture
def runtime_root():
    from pathlib import Path
    root = '/private/tmp' if sys.platform == 'darwin' else '/tmp'
    with tempfile.TemporaryDirectory(prefix='larc-', dir=root) as directory:
        yield Path(directory)


def private_json(path, value):
    path.write_text(json.dumps(value))
    path.chmod(0o600)


def port():
    with socket.socket() as stream:
        stream.bind(('127.0.0.1', 0))
        return stream.getsockname()[1]


@contextmanager
def unmanic(work, plugins=('larenor_archive_encoder', 'larenor_archive_terminal')):
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            assert self.path == '/unmanic/api/v2/settings/libraries'
            self.reply({'libraries': [{'id': 42, 'path': str(work)}]})

        def do_POST(self):
            assert self.path == '/unmanic/api/v2/settings/library/read'
            assert json.loads(self.rfile.read(int(self.headers['Content-Length']))) == {'id': 42}
            self.reply({'library_config': {'id': 42, 'path': str(work)},
                'plugins': {'enabled_plugins': [{'plugin_id': value} for value in plugins]}})

        def reply(self, value):
            body = json.dumps(value).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_args):
            pass

    server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield server.server_port
    finally:
        server.shutdown()
        thread.join(2)
        server.server_close()


def config(tmp_path, unmanic_port=8888):
    values = {}
    for name in ('resolver', 'work', 'retained', 'library', 'journal', 'terminal', 'sockets'):
        values[name] = tmp_path / name
        values[name].mkdir(mode=0o700)
    key = tmp_path / 'key'
    key.write_bytes(b'c'*32)
    key.chmod(0o600)
    catalog = tmp_path / 'catalog.json'
    private_json(catalog, {
        'schemaVersion': 1, 'storeRoot': str(values['resolver']),
        'workRoot': str(values['work']), 'retainedRoot': str(values['retained']),
        'authenticationKeyFile': str(key),
        'approvedMounts': [{'mountId': 'media', 'jellyfinRoot': '/media', 'hostRoot': str(values['library'])}],
    })
    ffmpeg, ffprobe = shutil.which('ffmpeg'), shutil.which('ffprobe')
    if not ffmpeg or not ffprobe:
        pytest.skip('real verifier executables required')
    result = ArchiveWorkerRuntimeConfig(
        str(catalog), str(values['sockets'] / 'reads.sock'),
        str(values['sockets'] / 'actions.sock'), str(values['sockets'] / 'authority.sock'),
        os.getuid(), unmanic_port, port(), str(values['journal']), str(values['terminal']),
        str(key), ffmpeg, ffprobe, 256*1024**2,
    )
    return result, values


def test_normal_composition_exposes_actual_ipc_and_removes_only_own_sockets(runtime_root):
    tmp_path = runtime_root
    settings, paths = config(tmp_path)
    with unmanic(paths['work']) as upstream_port:
        settings = ArchiveWorkerRuntimeConfig(**{**asdict(settings), 'unmanicPort': upstream_port})
        with ArchiveWorkerRuntime(settings):
            status = MediaArchiveActionWorkerClient(settings.actionSocket, owner_uid=os.getuid()).status()
            assert status['executeAvailable'] is True
            reads = MediaArchiveWorkerClient(settings.readSocket, owner_uid=os.getuid()).status()
            assert reads['readAvailable'] is True
            assert reads['mutationAvailable'] is False
        assert not os.path.lexists(settings.actionSocket)
        assert not os.path.lexists(settings.readSocket)


def test_failed_start_preserves_preexisting_socket_target(runtime_root):
    tmp_path = runtime_root
    settings, paths = config(tmp_path)
    from pathlib import Path
    existing = Path(settings.actionSocket)
    existing.write_bytes(b'owned by another service')
    existing.chmod(0o600)
    with unmanic(paths['work']) as upstream_port:
        settings = ArchiveWorkerRuntimeConfig(**{**asdict(settings), 'unmanicPort': upstream_port})
        with pytest.raises(ArchiveWorkerRuntimeError, match='^archive_worker_unavailable$'):
            with ArchiveWorkerRuntime(settings):
                pass
    assert existing.read_bytes() == b'owned by another service'


def test_private_config_strict_fields_permissions_and_redacted_repr(runtime_root):
    tmp_path = runtime_root
    settings, _paths = config(tmp_path)
    path = tmp_path / 'runtime.json'
    private_json(path, {'schemaVersion': 1, **asdict(settings)})
    assert ArchiveWorkerRuntimeConfig.load(path) == settings
    assert str(tmp_path) not in repr(settings)
    path.chmod(0o644)
    with pytest.raises(ArchiveWorkerRuntimeError):
        ArchiveWorkerRuntimeConfig.load(path)
    private_json(path, {'schemaVersion': 1, **asdict(settings), 'libraryId': 1})
    with pytest.raises(ArchiveWorkerRuntimeError):
        ArchiveWorkerRuntimeConfig.load(path)


def test_runtime_does_not_advertise_ready_without_live_unmanic_library(runtime_root):
    tmp_path = runtime_root
    settings, _paths = config(tmp_path, unmanic_port=port())
    with pytest.raises(ArchiveWorkerRuntimeError):
        ArchiveWorkerRuntime(settings)


@pytest.mark.parametrize('plugins', [(), ('larenor_archive_terminal',),
    ('larenor_archive_encoder', 'larenor_archive_terminal', 'other_encoder')])
def test_runtime_refuses_missing_or_extra_encoder_flows(runtime_root, plugins):
    settings, paths = config(runtime_root)
    with unmanic(paths['work'], plugins) as upstream_port:
        settings = ArchiveWorkerRuntimeConfig(**{**asdict(settings), 'unmanicPort': upstream_port})
        with pytest.raises(ArchiveWorkerRuntimeError):
            ArchiveWorkerRuntime(settings)
