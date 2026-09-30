"""Signed per-command plans and real standalone FFmpeg runner output."""

from dataclasses import replace
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
import zipfile

import pytest

from larenor_server.media_archive_actions.encoder_plan import SignedArchiveTranscodePlanWriter
from larenor_server.media_archive_actions.encoder_plugin import ArchiveEncoderError
from larenor_server.media_archive_actions.file_store import MediaArchiveFileStore
from larenor_server.media_archive_actions.plugin_package import encoder_plugin_package
from test_media_archive_verifier import media


@pytest.fixture
def encoder(tmp_path, media, monkeypatch):
    roots = {}
    for name in ("work", "retained", "library", "cache"):
        roots[name] = tmp_path / name
        roots[name].mkdir(mode=0o700)
    source = roots["library"] / "source.mkv"
    shutil.copyfile(media[2], source)
    source.chmod(0o600)
    files = MediaArchiveFileStore(roots["retained"], roots["work"], [roots["library"]],
                                 quota_bytes=256 * 1024**2)
    command = media[4]
    observed = files.observe_source(str(source), expected_bytes=source.stat().st_size)
    staged = files.retain_and_stage(command, observed)
    key = b"e" * 32
    keyfile = tmp_path / "key"
    keyfile.write_bytes(key)
    keyfile.chmod(0o600)
    config = tmp_path / "encoder.json"
    config.write_text(json.dumps({"schemaVersion": 1, "workRoot": str(roots["work"]),
        "cacheRoot": str(roots["cache"]), "keyFile": str(keyfile), "ffmpeg": media[1]}))
    config.chmod(0o600)
    monkeypatch.setenv("LARENOR_UNMANIC_ENCODER_CONFIG", str(config))
    package = encoder_plugin_package()
    assert package == encoder_plugin_package()
    with zipfile.ZipFile(io.BytesIO(package)) as archive:
        metadata = json.loads(archive.read("info.json"))
        assert metadata["priorities"] == {"on_library_management_file_test": 0, "on_worker_process": 0}
        pluginpath = tmp_path / "plugin.py"
        pluginpath.write_bytes(archive.read("plugin.py"))
    spec = importlib.util.spec_from_file_location("standalone_larenor_encoder", pluginpath)
    plugin = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(plugin)
    writer = SignedArchiveTranscodePlanWriter(roots["work"], key)
    return plugin, writer, command, staged, source, roots, config


def file_test(plugin, staged):
    return plugin.on_library_management_file_test({"library_id": 1, "path": staged.workPath,
        "issues": [], "add_file_to_pending_tasks": False, "priority_score": 0})


def worker_data(staged, roots):
    return {"library_id": 1, "task_id": 1, "worker_log": [], "exec_command": [],
        "current_command": [], "command_progress_parser": None, "repeat": True,
        "original_file_path": staged.workPath, "file_in": staged.workPath,
        "file_out": str(roots["cache"] / "output.mkv")}


def publish(encoder):
    plugin, writer, command, staged, *_rest = encoder
    writer(command, staged, deadline=time.monotonic() + 5)
    assert file_test(plugin, staged)["add_file_to_pending_tasks"] is True
    return plugin, command, staged


def test_unsigned_file_does_not_queue_and_worker_fails(encoder):
    plugin, _writer, _cmd, staged, _source, roots, _config = encoder
    result = file_test(plugin, staged)
    assert result["add_file_to_pending_tasks"] is False
    assert result["issues"] == ["archive_encoder_unavailable"]
    with pytest.raises(plugin.ArchiveEncoderError):
        plugin.on_worker_process(worker_data(staged, roots))


def test_real_runner_preserves_all_tracks_and_original(encoder, media):
    plugin, command, staged = publish(encoder)
    _p, writer, _c, _s, original, roots, _config = encoder
    writer(command, staged, deadline=time.monotonic() + 5)  # identical replay cannot replace the plan
    data = plugin.on_worker_process(worker_data(staged, roots))
    assert data["repeat"] is False and type(data["exec_command"]) is list
    assert data["exec_command"][data["exec_command"].index("-b:v") + 1] == str(command.target.targetBitrate)
    assert "-map" in data["exec_command"] and "copy" in data["exec_command"]
    subprocess.run(data["exec_command"], check=True, capture_output=True, timeout=30)
    proof = media[0].verify(command, Path(staged.retainedPath), Path(data["file_out"]),
                            deadline=time.monotonic() + 30)
    assert proof.codec == "hevc" and proof.audioStreams == 1 and proof.subtitleStreams == 1
    assert original.read_bytes() == media[2].read_bytes()
    manifest = Path(staged.workPath).parent / "transcode-plan.json"
    assert oct(manifest.stat().st_mode & 0o777) == "0o600"
    assert str(original) not in manifest.read_text()


@pytest.mark.parametrize("change", ["signature", "bitrate", "file", "expiry", "permissions", "symlink"])
def test_forged_changed_expired_or_unsafe_plan_does_not_queue(encoder, change):
    plugin, _command, staged = publish(encoder)
    path = Path(staged.workPath)
    manifest = path.parent / "transcode-plan.json"
    value = json.loads(manifest.read_text())
    if change in {"signature", "bitrate"}:
        if change == "signature":
            value["signature"] = "0" * 64
        else:
            value["plan"]["targetBitrate"] += 1
        manifest.write_text(json.dumps(value))
    elif change == "file":
        path.write_bytes(path.read_bytes() + b"changed")
    elif change == "expiry":
        value["plan"]["createdAt"] = 1
        value["plan"]["expiresAt"] = 2
        # Even an authentic past plan cannot queue.
        from larenor_server.media_archive_actions.encoder_plugin import _signature
        value["signature"] = _signature(b"e" * 32, value["plan"])
        manifest.write_text(json.dumps(value))
    elif change == "permissions":
        manifest.chmod(0o644)
    else:
        copy = manifest.with_name("saved.json")
        manifest.rename(copy)
        manifest.symlink_to(copy)
    result = file_test(plugin, staged)
    assert result["add_file_to_pending_tasks"] is False


def test_worker_rejects_changed_cache_input_and_destination_escape(encoder):
    plugin, _command, staged = publish(encoder)
    roots = encoder[5]
    cached = roots["cache"] / "copy.mkv"
    cached.write_bytes(Path(staged.workPath).read_bytes()[:-1] + b"x")
    data = worker_data(staged, roots)
    data["file_in"] = str(cached)
    with pytest.raises(plugin.ArchiveEncoderError):
        plugin.on_worker_process(data)
    data = worker_data(staged, roots)
    data["file_out"] = str(roots["library"] / "replaced.mkv")
    with pytest.raises(plugin.ArchiveEncoderError):
        plugin.on_worker_process(data)
    assert not (roots["library"] / "replaced.mkv").exists()


def test_writer_rejects_unbound_stage_or_deadline(encoder):
    _plugin, writer, command, staged, *_ = encoder
    with pytest.raises(ArchiveEncoderError):
        writer(command, replace(staged, commandDigest="0" * 64), deadline=time.monotonic() + 5)
    with pytest.raises(ArchiveEncoderError):
        writer(command, staged, deadline=time.monotonic() - 1)
    assert not (Path(staged.workPath).parent / "transcode-plan.json").exists()


def test_upstream_missing_cache_directory_is_bound_before_it_is_created(encoder):
    plugin, _command, staged = publish(encoder)
    roots = encoder[5]
    data = worker_data(staged, roots)
    data['file_out'] = str(roots['cache'] / 'task-1' / 'encoded.mkv')
    assert plugin.on_worker_process(data)['exec_command'][-1] == data['file_out']
    assert not (roots['cache'] / 'task-1').exists()
    (roots['cache'] / 'task-1').symlink_to(roots['library'], target_is_directory=True)
    with pytest.raises(plugin.ArchiveEncoderError):
        plugin.on_worker_process(data)
