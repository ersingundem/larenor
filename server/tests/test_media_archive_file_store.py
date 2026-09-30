from pathlib import Path

import pytest

from larenor_server.media_archive_actions.file_store import (
    ArchiveFileStoreError, MediaArchiveFileStore,
)
from test_media_archive_action_journal import command


@pytest.fixture
def store(tmp_path):
    roots = [tmp_path / name for name in ("retained", "work", "library")]
    for root in roots:
        root.mkdir(mode=0o700)
    source = roots[2] / "movie.mkv"
    source.write_bytes(b"x" * 4096)
    source.chmod(0o600)
    return MediaArchiveFileStore(*roots[:2], [roots[2]], quota_bytes=8192), source


def stage(store):
    files, path = store
    source = files.observe_source(path, expected_bytes=4096)
    return files, files.retain_and_stage(command(), source)


def test_stage_is_a_verified_separate_copy_and_source_stays_untouched(store):
    files, binding = stage(store)
    assert Path(binding.retainedPath).read_bytes() == Path(binding.workPath).read_bytes() == b"x" * 4096
    assert Path(binding.source.path).read_bytes() == b"x" * 4096
    assert len({path.stat().st_ino for path in map(Path, (
        binding.source.path, binding.retainedPath, binding.workPath))}) == 3
    assert files.lookup(command()) == binding
    assert files.retained_bytes() == 4096


def test_changed_original_and_symlink_parent_never_enter_work_store(store, tmp_path):
    files, path = store
    source = files.observe_source(path, expected_bytes=4096)
    path.write_bytes(b"z" * 4096)
    with pytest.raises(ArchiveFileStoreError, match="source_changed"):
        files.retain_and_stage(command(), source)
    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "file.mkv").write_bytes(b"x" * 4096)
    (path.parent / "linked").symlink_to(outside, target_is_directory=True)
    with pytest.raises(ArchiveFileStoreError, match="source_path_rejected"):
        files.observe_source(path.parent / "linked/file.mkv", expected_bytes=4096)


def test_quota_and_cancel_preserve_source(store):
    files, path = store
    files.quota_bytes = 4095
    source = files.observe_source(path, expected_bytes=4096)
    with pytest.raises(ArchiveFileStoreError, match="archive_quota_exceeded"):
        files.retain_and_stage(command(), source)
    files.quota_bytes = 8192
    with pytest.raises(ArchiveFileStoreError, match="cancelled"):
        files.retain_and_stage(command(), source, cancelled=lambda: True)
    assert path.read_bytes() == b"x" * 4096


def test_install_intent_precedes_atomic_replace_and_original_remains(store):
    import hashlib
    files, binding = stage(store)
    Path(binding.workPath).write_bytes(b"optimized")
    output_digest = hashlib.sha256(b"optimized").hexdigest()
    seen = []

    def before_replace(actual, digest, length):
        assert actual == binding
        assert Path(binding.source.path).read_bytes() == b"x" * 4096
        assert Path(binding.retainedPath).read_bytes() == b"x" * 4096
        seen.append((digest, length))

    result = files.install_verified(binding, output_digest=output_digest,
        output_bytes=9, before_replace=before_replace)
    assert seen == [result] == [(output_digest, 9)]
    assert Path(binding.source.path).read_bytes() == b"optimized"
    assert Path(binding.retainedPath).read_bytes() == b"x" * 4096
    proof = files.observe_retained_cleanup(
        binding, expected_digest=binding.source.sha256,
        output_digest=output_digest, output_bytes=9)
    intents = []
    assert files.cleanup_retained(
        binding, proof, intent_recorded=False,
        before_delete=intents.append,
        before_unlink=lambda _proof: None) is True
    assert intents == [proof]
    assert not Path(binding.retainedPath).exists()
    assert files.retained_bytes() == 0
    assert files.cleanup_retained(
        binding, proof, intent_recorded=True,
        before_unlink=lambda _proof: None) is False
    Path(binding.retainedPath).write_bytes(b"x" * 4096)
    Path(binding.retainedPath).chmod(0o600)
    with pytest.raises(ArchiveFileStoreError, match="artifact_changed"):
        files.cleanup_retained(
            binding, proof, intent_recorded=True,
            before_unlink=lambda _proof: None)
    Path(binding.retainedPath).unlink()
    with pytest.raises(
            ArchiveFileStoreError, match="retained_original_missing"):
        files.cleanup_retained(
            binding, proof, intent_recorded=False,
            before_delete=lambda _proof: None,
            before_unlink=lambda _proof: None)


def test_lost_install_intent_ack_never_replaces_source(store):
    import hashlib
    files, binding = stage(store)
    Path(binding.workPath).write_bytes(b"optimized")

    def before_replace(*_args):
        raise RuntimeError("simulated crash after durable intent")

    with pytest.raises(RuntimeError):
        files.install_verified(binding, output_digest=hashlib.sha256(b"optimized").hexdigest(),
            output_bytes=9, before_replace=before_replace)
    assert Path(binding.source.path).read_bytes() == b"x" * 4096
    assert Path(binding.retainedPath).read_bytes() == b"x" * 4096


def test_original_tamper_or_missing_verified_output_blocks_cleanup(store):
    files, binding = stage(store)
    Path(binding.retainedPath).write_bytes(b"corrupt")
    with pytest.raises(ArchiveFileStoreError, match="artifact_changed"):
        files.inspect_original(binding)
    with pytest.raises(ArchiveFileStoreError, match="source_changed"):
        files.observe_retained_cleanup(
            binding, expected_digest=binding.source.sha256,
            output_digest="f" * 64, output_bytes=8)
    assert Path(binding.retainedPath).exists()


def test_existing_work_paths_are_not_adopted_or_retried(store):
    files, binding = stage(store)
    with pytest.raises(FileExistsError):
        files.retain_and_stage(command(), binding.source)
    assert Path(binding.retainedPath).read_bytes() == b"x" * 4096
