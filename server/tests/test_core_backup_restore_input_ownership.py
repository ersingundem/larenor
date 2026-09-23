"""Offline restore input ordering and passphrase-buffer ownership."""

import pytest
from larenor_server import cli
from larenor_server.errors import StartupError

PASSPHRASE = "Correct horse battery staple 2026"


@pytest.mark.parametrize("terminator", (b"\n", b"\r\n"))
def test_restore_passphrase_accepts_one_terminal_line_ending_and_wipes_buffer(
    terminator,
):
    encoded = bytearray(PASSPHRASE.encode("utf-8") + terminator)

    assert cli._decode_restore_passphrase(encoded) == PASSPHRASE
    assert encoded == bytearray(len(encoded))


def test_invalid_restore_passphrase_wipes_buffer():
    encoded = bytearray(b"too short\n")

    with pytest.raises(StartupError, match="restore_passphrase_invalid"):
        cli._decode_restore_passphrase(encoded)

    assert encoded == bytearray(len(encoded))


def test_invalid_passphrase_is_rejected_before_bundle_read(monkeypatch, tmp_path):
    bundle = tmp_path / "large-private-backup.larenor-core"
    passphrase = tmp_path / "passphrase"
    reads = []

    def private_read(path, maximum):
        reads.append((path, maximum))
        if path == passphrase:
            return b"too short\n"
        raise AssertionError("bundle must not be read for an invalid passphrase")

    monkeypatch.setattr(cli, "private_read", private_read)

    with pytest.raises(StartupError, match="restore_passphrase_invalid"):
        cli._read_restore_inputs(bundle, passphrase)

    assert [path for path, _maximum in reads] == [passphrase]


def test_restore_reads_the_secret_into_the_exact_buffer_that_is_wiped(
    monkeypatch, tmp_path
):
    bundle = tmp_path / "backup.larenor-core"
    passphrase = tmp_path / "passphrase"
    source = bytearray(PASSPHRASE.encode("utf-8") + b"\n")

    def private_read_mutable(path, maximum):
        assert path == passphrase
        assert maximum == 514
        return source

    def private_read(path, maximum):
        assert path == bundle
        return b"bounded bundle"

    monkeypatch.setattr(
        cli, "private_read_mutable", private_read_mutable, raising=False
    )
    monkeypatch.setattr(cli, "private_read", private_read)

    loaded, decoded = cli._read_restore_inputs(bundle, passphrase)

    assert loaded == b"bounded bundle"
    assert decoded == PASSPHRASE
    assert source == bytearray(len(source))
