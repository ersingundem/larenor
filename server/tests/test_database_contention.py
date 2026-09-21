"""Database writer contention remains bounded without losing a valid write."""

from concurrent.futures import ThreadPoolExecutor
from threading import Event

from larenor_server.database import Database


def test_second_writer_waits_for_a_slow_committed_transaction(tmp_path):
    database = Database(tmp_path / "writer-contention.sqlite")
    with database.connection() as connection:
        connection.execute("CREATE TABLE writes (value TEXT NOT NULL)")

    acquired = Event()
    release = Event()

    def slow_writer():
        with database.transaction() as connection:
            connection.execute("INSERT INTO writes VALUES ('first')")
            acquired.set()
            release.wait(timeout=5.5)

    with ThreadPoolExecutor(max_workers=1) as executor:
        first = executor.submit(slow_writer)
        assert acquired.wait(timeout=2)
        try:
            with database.transaction() as connection:
                connection.execute("INSERT INTO writes VALUES ('second')")
        finally:
            release.set()
        first.result(timeout=2)

    with database.connection() as connection:
        assert [row["value"] for row in connection.execute("SELECT value FROM writes")] == [
            "first", "second"
        ]
