"""Static worker configuration errors and ownership-safe failed socket startup."""

from dataclasses import replace
import os
import socket

import pytest

from larenor_server.cli import main
from larenor_server.config import Settings
from larenor_server.errors import StartupError
from larenor_server.plugins.preflight_ipc import PreflightIPCError, PreflightWorkerServer
from test_plugin_preflight_ipc import Inspector, root, uid


@pytest.mark.parametrize("value", ["synthetic-invalid-uid", "", "-1", str(2**31)])
def test_invalid_worker_uid_environment_is_a_static_startup_error(monkeypatch, value):
    monkeypatch.setenv("LARENOR_PLUGIN_WORKER_UID", value)
    with pytest.raises(StartupError, match="^invalid_worker_configuration$") as caught:
        Settings.from_environment()
    assert value not in str(caught.value) if value else True


@pytest.mark.parametrize("value", ["relative/socket", "/tmp/../synthetic/socket", "/tmp/synthetic\nworker.sock"])
def test_invalid_worker_socket_environment_is_a_static_startup_error(monkeypatch, value):
    monkeypatch.setenv("LARENOR_PLUGIN_WORKER_SOCKET", value)
    with pytest.raises(StartupError, match="^invalid_worker_configuration$"):
        Settings.from_environment()


def test_cli_reports_worker_configuration_failure_without_env_or_traceback(monkeypatch, capsys):
    monkeypatch.setenv("LARENOR_PLUGIN_WORKER_UID", "synthetic-private-environment-text")
    assert main(["--initialize-only"]) == 1
    captured = capsys.readouterr()
    assert captured.out == ""
    assert captured.err == "Larenor Server initialization failed: invalid_worker_configuration\n"
    assert "synthetic-private" not in captured.err and "Traceback" not in captured.err


def test_direct_settings_keeps_value_error_contract_for_bad_uid_and_path(tmp_path):
    settings = Settings(tmp_path / "data", tmp_path / "key")
    for changes in ({"plugin_worker_uid": True}, {"plugin_worker_uid": -1},
                    {"plugin_worker_socket": tmp_path / "synthetic\nworker.sock"}):
        with pytest.raises(ValueError, match="^invalid_worker_configuration$"):
            replace(settings, **changes)


@pytest.mark.parametrize("failure", ["chmod", "chown"])
def test_permission_failure_after_bind_removes_only_owned_socket(monkeypatch, failure):
    with root() as directory:
        path = directory / "worker.sock"
        worker = PreflightWorkerServer(path, Inspector(), platform="linux/amd64", allowed_uid=os.getuid(),
                                       peer_uid=uid, socket_gid=os.getgid() if failure == "chown" else None)
        with monkeypatch.context() as patch:
            def reject(*_args):
                raise PermissionError("synthetic permission failure")
            patch.setattr("larenor_server.plugins.preflight_ipc.os." + failure, reject)
            with pytest.raises(PreflightIPCError, match="^worker_unavailable$"):
                worker.start()
        assert not path.exists(), "Failed startup left its own newly bound endpoint behind"
        worker.close()
        replacement = PreflightWorkerServer(path, Inspector(), platform="linux/amd64", allowed_uid=os.getuid(), peer_uid=uid)
        replacement.start()
        replacement.close()
        assert not path.exists()


def test_failed_permission_change_never_unlinks_replacement_inode(monkeypatch):
    with root() as directory:
        path = directory / "worker.sock"
        worker = PreflightWorkerServer(path, Inspector(), platform="linux/amd64", allowed_uid=os.getuid(), peer_uid=uid)
        with socket.socket(socket.AF_UNIX) as replacement:
            with monkeypatch.context() as patch:
                def replace_endpoint(*_args):
                    path.unlink()
                    replacement.bind(str(path))
                    raise PermissionError("synthetic replacement")
                patch.setattr("larenor_server.plugins.preflight_ipc.os.chmod", replace_endpoint)
                with pytest.raises(PreflightIPCError):
                    worker.start()
            retained_inode = path.stat().st_ino
            worker.close()
            assert path.stat().st_ino == retained_inode
