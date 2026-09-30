"""Opt-in acceptance against the actual pinned Unmanic process and FFmpeg.

Set LARENOR_UNMANIC_041_EXECUTABLE to an installed unmanic==0.4.1 executable.
All configuration, libraries, plugins, sockets and effects are temporary. This
does not address any pre-existing Unmanic service or real home media.
"""

from contextlib import ExitStack
import hashlib
import http.client
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import time

import pytest

from larenor_server.media_archive_actions.callback_server import UnmanicCallbackServer
from larenor_server.media_archive_actions.encoder_plan import SignedArchiveTranscodePlanWriter
from larenor_server.media_archive_actions.engine import MediaArchiveActionEngine
from larenor_server.media_archive_actions.file_store import MediaArchiveFileStore
from larenor_server.media_archive_actions.http_transport import UnmanicLoopbackHttpTransport
from larenor_server.media_archive_actions.journal import MediaArchiveActionJournal
from larenor_server.media_archive_actions.plugin_package import callback_plugin_package, encoder_plugin_package
from larenor_server.media_archive_actions.source_resolver import UnmanicLibraryReadback
from larenor_server.media_archive_actions.terminal_store import UnmanicTerminalStore
from larenor_server.media_archive_actions.unmanic import UnmanicAdapter
from larenor_server.media_archive_actions.worker_runtime import _verified_encoder_library
from test_media_archive_engine import Resolver
from test_media_archive_verifier import media


def _port():
    with socket.socket() as stream:
        stream.bind(('127.0.0.1', 0))
        return stream.getsockname()[1]


def _json(path, value):
    path.write_text(json.dumps(value))
    path.chmod(0o600)


def _request(port, method, route, body=None):
    connection = http.client.HTTPConnection('127.0.0.1', port, timeout=3)
    try:
        raw = None if body is None else json.dumps(body).encode()
        connection.request(method, '/unmanic/api/v2' + route, raw,
                           {} if raw is None else {'Content-Type': 'application/json'})
        response = connection.getresponse()
        data = response.read(512 * 1024 + 1)
        assert response.status == 200 and len(data) <= 512 * 1024
        return json.loads(data)
    finally:
        connection.close()


def _stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)


def test_real_unmanic_signed_encoder_to_authenticated_terminal_and_verified_install(media):
    executable = os.environ.get('LARENOR_UNMANIC_041_EXECUTABLE')
    if not executable:
        pytest.skip('opt-in actual pinned Unmanic 0.4.1 environment required')
    executable = Path(executable)
    assert executable.is_absolute() and executable.is_file()
    python = executable.parent / 'python'
    assert python.is_file()
    checked = subprocess.run([str(python), '-c',
        "import json,pathlib,unmanic; p=pathlib.Path(unmanic.__file__).parent/'version'; "
        "assert json.loads(p.read_text()) == {'short':'0.4.1','long':'0.4.1~1c324b8'}"],
        capture_output=True, timeout=10)
    assert checked.returncode == 0, 'actual Unmanic revision differs from acceptance pin'
    with ExitStack() as resources:
        root = Path(resources.enter_context(tempfile.TemporaryDirectory(
            prefix='larenor-unmanic-accept-', dir='/private/tmp' if sys.platform == 'darwin' else '/tmp')))
        directories = {name: root / name for name in (
            'config', 'logs', 'cache', 'plugins', 'userdata', 'work', 'library',
            'retained', 'journal', 'terminal', 'outbox')}
        for directory in directories.values():
            directory.mkdir(mode=0o700)
        # Upstream PluginExecutor uses its application-specific HOME_DIR and
        # does not follow Config.plugins_path. Keep both on the same private
        # path without changing the user's HOME or writing to ~/.unmanic.
        upstream_home = root / 'upstream-home'
        upstream_home.mkdir(mode=0o700)
        (upstream_home / '.unmanic').mkdir(mode=0o700)
        directories['plugins'] = upstream_home / '.unmanic' / 'plugins'
        directories['plugins'].mkdir(mode=0o700)
        env = {key: value for key, value in os.environ.items()
               if not key.startswith('LARENOR_') and not key.startswith('SENTRY_')}
        env['HOME_DIR'] = str(upstream_home)
        for name in ('config', 'logs', 'cache', 'plugins', 'userdata', 'library'):
            env[('log' if name == 'logs' else name) + '_path'] = str(
                directories['work'] if name == 'library' else directories[name])
        _json(directories['config'] / 'settings.json', {
            'ui_port': _port(), 'ui_address': '127.0.0.1',
            'number_of_workers': 1, 'enable_library_scanner': False,
            'run_full_scan_on_start': False, 'follow_symlinks': False,
            'library_path': str(directories['work']),
        })
        key = os.urandom(32)
        keyfile = root / 'key'
        keyfile.write_bytes(key)
        keyfile.chmod(0o600)
        terminals = resources.enter_context(UnmanicTerminalStore(directories['terminal'], key))
        callback = UnmanicCallbackServer(terminals, _port())
        callback.start()
        resources.callback(callback.close)
        _json(root / 'callback.json', {'schemaVersion': 1, 'outboxDirectory': str(directories['outbox']),
            'workRoot': str(directories['work']), 'keyFile': str(keyfile),
            'callbackPort': callback._server.server_port})
        _json(root / 'encoder.json', {'schemaVersion': 1, 'workRoot': str(directories['work']),
            'cacheRoot': str(directories['cache']), 'keyFile': str(keyfile), 'ffmpeg': media[1]})
        env['LARENOR_UNMANIC_CALLBACK_CONFIG'] = str(root / 'callback.json')
        env['LARENOR_UNMANIC_ENCODER_CONFIG'] = str(root / 'encoder.json')
        for name, payload in (('callback', callback_plugin_package()), ('encoder', encoder_plugin_package())):
            (root / (name + '.zip')).write_bytes(payload)
        # Use the actual upstream installer, including its DB metadata and
        # dynamic plugin loading, rather than importing our plugin in-process.
        install = root / 'install.py'
        install.write_text(
            "from pathlib import Path\nfrom unmanic import config\n"
            "from unmanic.service import init_db\nfrom unmanic.libs.plugins import PluginsHandler\n"
            "root=Path(__file__).parent\nsettings=config.Config()\n"
            "db=init_db(settings.get_config_path())\nh=PluginsHandler()\n"
            "assert h.install_plugin_from_path_on_disk(str(root/'callback.zip'))\n"
            "assert h.install_plugin_from_path_on_disk(str(root/'encoder.zip'))\n"
            "db.stop()\n")
        installed = subprocess.run([str(python), str(install)], env=env,
                                   capture_output=True, timeout=20)
        assert installed.returncode == 0, 'actual upstream plugin installation failed'
        port = _port()
        log = resources.enter_context(open(root / 'process.log', 'wb'))
        process = subprocess.Popen([str(executable), '--address', '127.0.0.1', '--port', str(port)],
            env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        resources.callback(_stop, process)
        until = time.monotonic() + 30
        libraries = None
        while time.monotonic() < until:
            assert process.poll() is None, 'actual upstream exited before startup'
            try:
                libraries = _request(port, 'GET', '/settings/libraries')['libraries']
                break
            except (OSError, AssertionError):
                time.sleep(0.2)
        assert libraries and len(libraries) == 1, 'actual upstream library startup unavailable'
        library_id = libraries[0]['id']
        detail = _request(port, 'POST', '/settings/library/read', {'id': library_id})
        detail['library_config'].update(enable_scanner=False, enable_inotify=False)
        detail['plugins']['enabled_plugins'] = [{'library_id': library_id, 'plugin_id': value,
            'name': value, 'description': 'Larenor acceptance', 'icon': ''}
            for value in ('larenor_archive_encoder', 'larenor_archive_terminal')]
        _request(port, 'POST', '/settings/library/write', detail)
        transport = UnmanicLoopbackHttpTransport(port)
        library = UnmanicLibraryReadback(transport, directories['work']).read_verified_library(
            deadline=time.monotonic() + 5)
        _verified_encoder_library(transport, library)
        journal = resources.enter_context(MediaArchiveActionJournal(directories['journal']))
        files = MediaArchiveFileStore(directories['retained'], directories['work'],
            [directories['library']], quota_bytes=256 * 1024**2)
        source = directories['library'] / 'source.mkv'
        shutil.copyfile(media[2], source)
        source.chmod(0o600)
        command = media[4]
        resolver = Resolver(command, source)
        # Resolver supplies current authority; the actual library id is read
        # from this upstream instance rather than the protocol fixture's id.
        from dataclasses import replace
        resolver.source = replace(resolver.source, libraryId=library_id)
        engine = MediaArchiveActionEngine(journal, files, UnmanicAdapter(transport),
            terminals, media[0], resolver,
            plan_writer=SignedArchiveTranscodePlanWriter(directories['work'], key))
        resources.callback(engine.close)
        assert engine.preview(command, deadline=time.monotonic() + 5, gate=lambda: True).state == 'ready'
        assert engine.execute(command, deadline=time.monotonic() + 5, cancelled=lambda: False).state == 'running'
        until = time.monotonic() + 90
        receipt = None
        while time.monotonic() < until:
            assert process.poll() is None, 'actual upstream exited during encoding'
            receipt = engine.reconcile(command, deadline=time.monotonic() + 5, cancelled=lambda: False)
            if receipt.state != 'running':
                break
            time.sleep(0.2)
        assert receipt is not None and receipt.state == 'succeeded', 'actual archive pipeline did not verify/install'
        assert receipt.retainedOriginal and receipt.proofDigest
        staged = files.lookup(command)
        assert files.inspect_original(staged)[1] == media[2].stat().st_size
        assert hashlib.sha256(source.read_bytes()).hexdigest() != staged.source.sha256
        assert source.stat().st_size < staged.source.byteLength
        with journal.locked():
            row = journal.get(command.operationId)
        proof = terminals.lookup_terminal(row.evidence.providerTaskId, staged.workPath)
        assert proof.taskSuccess and proof.fileMoveProcessesSuccess
