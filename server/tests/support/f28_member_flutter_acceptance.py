"""Real member Client -> normal Core -> production MASS runtime -> TCP fixture."""
from pathlib import Path
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time

import uvicorn

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from conftest import server as core_fixture
from test_admin import activate, create
from test_music_manager_api import ready_manager
from test_music_assistant_core_wiring import TOKEN as PROVIDER_TOKEN
from test_music_playback_runtime import raw_player, raw_queue
from larenor_server.plugins.music_playback_runtime import MusicPlaybackRuntime


def main():
    calls = []

    class Provider(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def do_POST(self):
            if self.path != '/api' or self.headers.get('Authorization') != 'Bearer ' + PROVIDER_TOKEN:
                self.send_error(403)
                return
            size = int(self.headers.get('Content-Length', '0'))
            if not 1 <= size <= 4096:
                self.send_error(400)
                return
            body = json.loads(self.rfile.read(size))
            command = body['command']
            calls.append(command)
            if command == 'player_queues/all':
                value = [raw_queue()]
            elif command == 'players/all':
                value = [raw_player()]
            elif command == 'players/get':
                value = raw_player()
            elif command == 'players/cmd/pause':
                value = None
            elif command == 'music/search':
                value = {'tracks': [{'uri': 'spotify://track/result',
                    'name': 'Member result', 'provider': 'spotify--fixture',
                    'artists': [{'name': 'Artist'}]}]}
            else:
                self.send_error(400)
                return
            payload = json.dumps(value).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

    upstream = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    threading.Thread(target=upstream.serve_forever, daemon=True).start()
    runtime = MusicPlaybackRuntime(lambda timeout: http.client.HTTPConnection(
        '127.0.0.1', upstream.server_port, timeout=timeout))

    class Backend:
        def _run(self, method, value, deadline, gate):
            if not gate():
                raise RuntimeError('authority_changed')
            result = method(value, deadline=deadline)
            if not gate():
                raise RuntimeError('authority_changed')
            return result

        def read_music_players(self, value, *, deadline, gate):
            return self._run(runtime.read, value, deadline, gate)

        def search_music_catalog(self, value, *, deadline, gate):
            return self._run(runtime.search, value, deadline, gate)

        def execute_music_playback(self, value, *, deadline, gate):
            return self._run(runtime.execute, value, deadline, gate)

    try:
        with tempfile.TemporaryDirectory(prefix='larenor-f28-member-') as root:
            generator = core_fixture.__wrapped__(Path(root))
            fixture = next(generator)
            app, client, _, clock = fixture
            clock.now = time.time()
            listener = socket.socket()
            listener.bind(('127.0.0.1', 0))
            async def observed_app(scope, receive, send):
                async def status_send(message):
                    if message['type'] == 'http.response.start' and message['status'] >= 400:
                        print('isolated request:', scope['method'], scope['path'], message['status'], flush=True)
                    await send(message)
                await app(scope, receive, status_send)
            running = uvicorn.Server(uvicorn.Config(observed_app, log_level='critical', access_log=False))
            thread = threading.Thread(target=lambda: running.run(sockets=[listener]), daemon=True)
            try:
                admin, setup, _, _, _ = ready_manager(fixture)
                create(client, admin, 'music-reader')
                member = activate(client, 'music-reader')
                app.state.core.music_playback.backend = Backend()
                thread.start()
                deadline = time.monotonic() + 5
                while not running.started:
                    if not thread.is_alive() or time.monotonic() >= deadline:
                        raise RuntimeError('core_startup_failed')
                    time.sleep(.02)
                for path in ['/available', '/' + setup['installationId']]:
                    probe = http.client.HTTPConnection('127.0.0.1', listener.getsockname()[1], timeout=5)
                    probe.request('GET', '/api/v1/admin/media/music-assistant/manager' + path,
                        headers={'Authorization': 'Bearer ' + member['accessToken']})
                    reply = probe.getresponse()
                    payload = json.loads(reply.read(262144))
                    probe.close()
                    if reply.status != 200:
                        raise RuntimeError('music_core_' + str(reply.status) + '_' + payload['error']['code'])
                result = subprocess.run(['flutter', 'test',
                    'test/features/server/server_music_member_normal_core_test.dart'],
                    cwd=Path(__file__).resolve().parents[3],
                    env={**os.environ, 'LARENOR_F28_CORE_URL':
                        f'http://127.0.0.1:{listener.getsockname()[1]}'}, check=False)
                if result.returncode:
                    return result.returncode
                assert calls == ['player_queues/all', 'players/all', 'music/search',
                                 'players/get', 'player_queues/all',
                                 'players/cmd/pause', 'players/get']
                return 0
            finally:
                running.should_exit = True
                if thread.is_alive():
                    thread.join(timeout=5)
                listener.close()
                generator.close()
    finally:
        upstream.shutdown()
        upstream.server_close()


if __name__ == '__main__':
    sys.exit(main())
