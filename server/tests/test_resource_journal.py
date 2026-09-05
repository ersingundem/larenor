"""Private resource receipts only. Synthetic observers, never Docker or mkdir effects."""

from concurrent.futures import ThreadPoolExecutor
import os
from pathlib import Path
import sqlite3

import pytest

from larenor_server.plugins.resource_journal import ResourceJournal, ResourceJournalError


def rejected(code, action):
    with pytest.raises(ResourceJournalError) as caught:
        action()
    assert str(caught.value) == caught.value.code == code


@pytest.fixture
def journal(tmp_path):
    value = ResourceJournal(tmp_path / 'resources-v1', initialize=True)
    yield value
    value.close()


def test_first_initialization_is_private_and_reopens_identical_identity(tmp_path):
    directory = tmp_path / 'resources-v1'
    with ResourceJournal(directory, initialize=True) as first:
        identity = first.identity
        assert len(identity) == 32 and all(c in '0123456789abcdef' for c in identity)
        assert str(directory) not in repr(first)
        assert directory.stat().st_mode & 0o777 == 0o700
        assert {entry.name for entry in directory.iterdir()} == {'journal.sqlite', 'journal.lock', 'identity.json'}
        assert all(entry.stat().st_mode & 0o777 == 0o600 for entry in directory.iterdir())
        with first.locked():
            assert first.list() == ()
    with ResourceJournal(directory, initialize=True) as reopened:
        assert reopened.identity == identity
        with reopened.locked():
            assert reopened.list() == ()


@pytest.mark.parametrize('missing', ['journal.sqlite', 'journal.lock', 'identity.json'])
@pytest.mark.parametrize('initialize', [False, True])
def test_missing_current_files_never_regenerate_or_reset(tmp_path, missing, initialize):
    directory = tmp_path / 'resources-v1'
    with ResourceJournal(directory, initialize=True):
        pass
    (directory / missing).unlink()
    rejected('journal_unavailable', lambda: ResourceJournal(directory, initialize=initialize))
    assert not (directory / missing).exists()


def test_preexisting_empty_directory_is_not_adopted(tmp_path):
    directory = tmp_path / 'resources-v1'
    directory.mkdir(mode=0o700)
    rejected('journal_unavailable', lambda: ResourceJournal(directory, initialize=True))
    assert list(directory.iterdir()) == []


def test_parent_must_exist_and_have_private_operator_ownership(tmp_path):
    parent = tmp_path / 'public'
    parent.mkdir(mode=0o777)
    parent.chmod(0o777)
    rejected('unsafe_worker_path', lambda: ResourceJournal(parent / 'resources-v1', initialize=True))
    assert not (parent / 'resources-v1').exists()
    rejected('unsafe_worker_path', lambda: ResourceJournal(tmp_path / 'missing' / 'resources-v1', initialize=True))


@pytest.mark.parametrize('target', ['directory', 'journal.sqlite', 'journal.lock', 'identity.json', 'journal.sqlite-journal'])
def test_symlink_never_follows_or_changes_foreign_target(tmp_path, target):
    directory = tmp_path / 'resources-v1'
    with ResourceJournal(directory, initialize=True):
        pass
    if target == 'directory':
        real = tmp_path / 'real'
        directory.rename(real)
        directory.symlink_to(real, target_is_directory=True)
        selected = real / 'identity.json'
    else:
        selected = tmp_path / 'foreign-file'
        selected.write_bytes(b'foreign-content')
        selected.chmod(0o600)
        path = directory / target
        if path.exists():
            path.unlink()
        path.symlink_to(selected)
    before = selected.read_bytes()
    rejected('unsafe_worker_path', lambda: ResourceJournal(directory))
    assert selected.read_bytes() == before


@pytest.mark.parametrize('name', ['journal.sqlite', 'journal.lock', 'identity.json'])
def test_hardlinked_or_public_files_are_not_accepted(tmp_path, name):
    directory = tmp_path / 'resources-v1'
    with ResourceJournal(directory, initialize=True):
        pass
    target = directory / name
    target.chmod(0o640)
    rejected('unsafe_worker_path', lambda: ResourceJournal(directory))
    target.chmod(0o600)
    os.link(target, tmp_path / 'alias')
    rejected('unsafe_worker_path', lambda: ResourceJournal(directory))


def test_lock_is_required_and_never_released_during_an_active_effect(journal):
    rejected('lock_required', journal.list)
    with journal.locked():
        assert journal.list() == ()
        rejected('worker_busy', journal.close)
        def other_thread():
            rejected('lock_required', journal.list)
            with pytest.raises(ResourceJournalError, match='^worker_busy$'):
                with journal.locked():
                    pass
        with ThreadPoolExecutor(max_workers=1) as pool:
            pool.submit(other_thread).result()
    with journal.locked():
        assert journal.list() == ()


def test_independent_process_lock_prevents_overlapping_leases(journal):
    with ResourceJournal(journal.directory) as other:
        with journal.locked():
            with pytest.raises(ResourceJournalError, match='^worker_busy$'):
                with other.locked():
                    pass
        with other.locked():
            assert other.list() == ()


@pytest.mark.parametrize('target', ['directory', 'journal.sqlite', 'journal.lock', 'identity.json'])
def test_path_identity_replacement_after_open_fails_before_receipt_write(journal, target):
    if target == 'directory':
        path = journal.directory
        replacement = path.with_name('moved')
        path.rename(replacement)
        path.mkdir(mode=0o700)
    else:
        path = journal.directory / target
        old = path.with_name(target + '.old')
        path.rename(old)
        path.write_bytes(old.read_bytes())
        path.chmod(0o600)
    with pytest.raises(ResourceJournalError, match='^unsafe_worker_path$'):
        with journal.locked():
            pass


@pytest.mark.parametrize('damage', ['metadata_identity', 'metadata_version', 'metadata_count', 'metadata_digest', 'columns', 'unique', 'extra_table'])
def test_full_schema_and_metadata_integrity_fail_on_an_empty_current_journal(tmp_path, damage):
    directory = tmp_path / 'resources-v1'
    with ResourceJournal(directory, initialize=True):
        pass
    with sqlite3.connect(directory / 'journal.sqlite') as db:
        if damage.startswith('metadata_'):
            column = damage.removeprefix('metadata_')
            value = 9 if column in ('version', 'count') else 'f' * (32 if column == 'identity' else 64)
            db.execute(f'UPDATE metadata SET {column}=?', (value,))
        elif damage == 'columns':
            db.execute('ALTER TABLE resources ADD COLUMN untrusted TEXT')
        elif damage == 'extra_table':
            db.execute('CREATE TABLE foreign_state(value TEXT)')
        else:
            source = db.execute("SELECT sql FROM sqlite_master WHERE name='resources'").fetchone()[0]
            assert 'UNIQUE(preparation_id,resource_id,kind)' in source
            db.execute('DROP TABLE resources')
            db.execute(source.replace('UNIQUE(preparation_id,resource_id,kind)', 'CHECK(1)'))
    rejected('journal_unavailable', lambda: ResourceJournal(directory))


def test_close_is_idempotent_and_closed_journal_cannot_observe(journal):
    journal.close()
    journal.close()
    with pytest.raises(ResourceJournalError, match='^journal_unavailable$'):
        with journal.locked():
            pass
