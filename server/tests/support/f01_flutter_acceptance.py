"""Actual F01 Client -> normal Core -> bounded HA state/read; zero device effect."""
from pathlib import Path
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
from test_home_assistant_adapter import ha as ha_fixture, setup, bind


def main():
    with tempfile.TemporaryDirectory(prefix='larenor-f01-client-') as root:
        core_gen = core_fixture.__wrapped__(Path(root))
        server = next(core_gen)
        ha_gen = ha_fixture.__wrapped__()
        provider = next(ha_gen)
        app, client, actor, resource, _, base, _, body = setup(server, provider)
        bind(client, actor, base, body)
        initial_reads = provider.calls
        scope = app.state.core.context
        listener = socket.socket(); listener.bind(('127.0.0.1', 0))
        running = uvicorn.Server(uvicorn.Config(app, log_level='critical', access_log=False))
        thread = threading.Thread(target=lambda: running.run(sockets=[listener]), daemon=True)
        try:
            thread.start(); until = time.monotonic() + 5
            while not running.started:
                if not thread.is_alive() or time.monotonic() > until: raise RuntimeError('core_start_failed')
                time.sleep(.02)
            result = subprocess.run(['flutter', 'test', 'test/features/server/server_automation_draft_normal_core_test.dart'], cwd=Path(__file__).resolve().parents[3], env={**os.environ,
                'LARENOR_F01_CORE_URL': f'http://127.0.0.1:{listener.getsockname()[1]}',
                'LARENOR_F01_CORE_ID': scope.coreId, 'LARENOR_F01_HOME_ID': scope.homeId,
                'LARENOR_F01_TOKEN': actor['accessToken'],
            }, check=False)
            if result.returncode == 0:
                # Normal Core caches a validated snapshot. Preview/activation
                # may reuse it, but the Client must cause an actual fresh read.
                if provider.command_calls != 0 or provider.calls <= initial_reads: raise RuntimeError('actual_draft_effect_boundary_failed')
                with app.state.core.db.connection() as c:
                    if c.execute('SELECT COUNT(*) FROM automation_drafts WHERE state="activated"').fetchone()[0] != 1: raise RuntimeError('durable_rule_acceptance_failed')
            return result.returncode
        finally:
            running.should_exit = True
            if thread.is_alive(): thread.join(timeout=5)
            listener.close(); ha_gen.close(); core_gen.close()

if __name__ == '__main__': sys.exit(main())
