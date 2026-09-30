"""Real Flutter Client -> normal Core -> owned music worker timer gate."""

from dataclasses import replace
from pathlib import Path
import os
import shutil
import socket
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from conftest import server as core_fixture
from larenor_server.app import create_app
import larenor_server.core as core_module
from larenor_server.plugins.installation_ipc import InstallationWorkerServer
from larenor_server.plugins.installation_ipc import InstallationWorkerClient
from support.installed_core_tcp import InstalledCoreTcp
from test_f28_longform_catalog import result
from test_f28_longform_sleep_timer import _enforce_timer_worker_media
from test_music_manager_api import MANAGER, ready_manager
from test_music_playback import player, queue


MEDIA_URI = "audiobookshelf://audiobook/book-one"


def _flutter(app, phase, state_file, deadline):
    with InstalledCoreTcp(app) as tcp:
        return subprocess.run(
            [
                "flutter", "test", "--no-pub",
                "test/features/server/server_longform_sleep_timer_normal_core_test.dart",
            ],
            env={
                **os.environ,
                "LARENOR_F28_CORE_URL": f"http://127.0.0.1:{tcp.port}",
                "LARENOR_F28_PHASE": phase,
                "LARENOR_F28_STATE_FILE": str(state_file),
                "LARENOR_F28_DEADLINE": str(deadline),
            },
            cwd=Path(__file__).resolve().parents[3],
            timeout=120,
            check=False,
        ).returncode


def main():
    with tempfile.TemporaryDirectory(prefix="larenor-f28-client-") as root:
        root_path = Path(root).resolve()
        generator = core_fixture.__wrapped__(root_path)
        fixture = next(generator)
        try:
            _pair, setup, readiness, worker, _manager = ready_manager(fixture)
            _enforce_timer_worker_media(worker)
            worker.players = [player().model_copy(
                update={"playbackState": "playing", "positionSeconds": 900})]
            worker.queues = [queue(current=MEDIA_URI, position=900)]
            provider = "spotify--fixture"
            worker.read_music_longform = lambda _action, **_kwargs: result(provider)
            refreshed = fixture[1].post(MANAGER + "/refresh", headers={
                "Authorization": "Bearer " + _pair["accessToken"],
            }, json={
                "requestId": "2" * 32,
                "installationId": setup["installationId"],
                "expectedInstallationRevision": setup["installationRevision"],
                "expectedCoreRevision": readiness["revision"],
            })
            if refreshed.status_code != 200:
                raise RuntimeError("music_snapshot_setup_failed")
            settings, clock = fixture[2], fixture[3]
            installation_id = setup["installationId"]
        finally:
            generator.close()

        socket_parent = Path(tempfile.mkdtemp(
            prefix="larenor-f28-worker-",
            dir="/private/tmp" if Path("/private/tmp").is_dir() else "/tmp",
        )).resolve()
        socket_path = socket_parent / "owned-music-worker.sock"
        darwin_peer = (None if hasattr(socket, "SO_PEERCRED")
                       else lambda _connection: os.getuid())
        ipc = InstallationWorkerServer(
            socket_path,
            worker,
            allowed_uid=os.getuid(),
            peer_uid=darwin_peer,
            timeout=2,
        )
        ipc.start()
        settings = replace(
            settings,
            installation_worker_socket=socket_path,
            installation_worker_uid=os.getuid(),
        )
        state_file = root_path / "client-state.json"
        deadline = int(clock.now) + 60
        os.environ["LARENOR_F28_INSTALLATION_ID"] = installation_id
        original_client = core_module.InstallationWorkerClient
        if darwin_peer is not None:
            core_module.InstallationWorkerClient = (
                lambda path, *, owner_uid: InstallationWorkerClient(
                    path, owner_uid=owner_uid, peer_uid=darwin_peer,
                )
            )
        try:
            first = create_app(settings)
            status = _flutter(first, "schedule", state_file, deadline)
            if status:
                return status
            if worker.calls:
                raise RuntimeError("sleep_timer_dispatched_before_deadline")
            clock.now += 60
            if first.state.core.longform_sessions.tick() is not True:
                raise RuntimeError("sleep_timer_not_verified")
            if len(worker.calls) != 1:
                raise RuntimeError("sleep_timer_effect_count_invalid")
            command = worker.calls[0].request
            if (command.operation != "pause"
                    or command.targetId != "homepod-living"
                    or command.expectedQueueId != "homepod-living"):
                raise RuntimeError("sleep_timer_effect_invalid")

            restarted = create_app(settings)
            status = _flutter(restarted, "restart", state_file, deadline)
            if status:
                return status
            if restarted.state.core.longform_sessions.tick() is not False:
                raise RuntimeError("sleep_timer_replayed_after_restart")
            if len(worker.calls) != 1:
                raise RuntimeError("sleep_timer_duplicate_effect")
        finally:
            core_module.InstallationWorkerClient = original_client
            os.environ.pop("LARENOR_F28_INSTALLATION_ID", None)
            ipc.close()
            shutil.rmtree(socket_parent)
    return 0


if __name__ == "__main__":
    sys.exit(main())
