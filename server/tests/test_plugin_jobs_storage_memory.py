"""Opening retained job history must not accumulate encrypted payload bodies."""

from contextlib import contextmanager
import tracemalloc

import pytest

from larenor_server.errors import StartupError
from larenor_server.plugins.jobs import JobManagement


class Rows:
    def __init__(self, count, payload_bytes):
        self.count, self.payload_bytes = count, payload_bytes

    def __iter__(self):
        for _ in range(self.count):
            yield {"ciphertext": b"x" * self.payload_bytes}

    def fetchall(self):
        return list(self)


class RetainedHistory:
    """Model SQLite's lazy row delivery without writing a large test database."""
    def __init__(self, count):
        self.count = count

    @contextmanager
    def connection(self):
        yield self

    def execute(self, query, _parameters=None):
        return Rows(self.count if "FROM plugin_jobs " in query else 0, 65536)


def validation_manager(monkeypatch, count):
    manager = JobManagement(RetainedHistory(count), None, None, b"x" * 32, None)
    decoded = []
    def decode(row):
        # Crypto/metadata correctness has separate real-SQLite regressions;
        # this test measures retention of accepted payloads during iteration.
        assert len(row["ciphertext"]) == 65536
        decoded.append(1)
    monkeypatch.setattr(manager, "_decode", decode)
    return manager, decoded


def test_startup_validation_keeps_bounded_memory_as_retained_history_grows(monkeypatch):
    manager, decoded = validation_manager(monkeypatch, 128)
    tracemalloc.start()
    try:
        manager.validate_storage()
        _, peak = tracemalloc.get_traced_memory()
    finally:
        tracemalloc.stop()
    assert len(decoded) == 128
    assert peak < 2 * 1024 * 1024, f"Retained payloads accumulated {peak} bytes"


def test_streaming_validation_still_rejects_history_over_capacity(monkeypatch):
    monkeypatch.setattr("larenor_server.plugins.jobs.MAX_JOBS", 1)
    manager, _ = validation_manager(monkeypatch, 2)
    with pytest.raises(StartupError, match="invalid_plugin_jobs_storage"):
        manager.validate_storage()
