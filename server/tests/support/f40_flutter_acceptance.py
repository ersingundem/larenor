"""Actual F40 Flutter Client against normal Core TCP across restart."""

from pathlib import Path
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from conftest import ready, server as core_fixture
from support.installed_core_tcp import InstalledCoreTcp


def _exact_journal_counts(core):
    with core.db.connection() as connection:
        reservation = connection.execute(
            "SELECT action,COUNT(*) AS count FROM resource_reservation_events "
            "GROUP BY action ORDER BY action"
        ).fetchall()
        catalog = connection.execute(
            "SELECT action,COUNT(*) AS count FROM resource_reservation_catalog_events "
            "GROUP BY action ORDER BY action"
        ).fetchall()
    return (
        [(row["action"], row["count"]) for row in reservation],
        [(row["action"], row["count"]) for row in catalog],
    )


def main():
    with tempfile.TemporaryDirectory(prefix="larenor-f40-client-") as root:
        for phase in ("create", "restart"):
            generator = core_fixture.__wrapped__(Path(root))
            fixture = next(generator)
            try:
                if phase == "create":
                    ready(fixture)
                with InstalledCoreTcp(fixture[0]) as tcp:
                    result = subprocess.run(
                        [
                            "flutter",
                            "test",
                            "--no-pub",
                            "test/features/resource_reservations/"
                            "resource_reservation_normal_core_test.dart",
                        ],
                        env={
                            **os.environ,
                            "LARENOR_RESERVATION_CORE_URL":
                                f"http://127.0.0.1:{tcp.port}",
                            "LARENOR_RESERVATION_PHASE": phase,
                        },
                        cwd=Path(__file__).resolve().parents[3],
                        check=False,
                    )
                    if result.returncode:
                        return result.returncode
                if phase == "restart":
                    reservation, catalog = _exact_journal_counts(
                        fixture[0].state.core
                    )
                    if reservation != [("cancelled", 1), ("created", 1)]:
                        raise RuntimeError(
                            "reservation_journal_effect_count:" + repr(reservation)
                        )
                    if catalog != [("created", 1)]:
                        raise RuntimeError(
                            "reservation_catalog_effect_count:" + repr(catalog)
                        )
            finally:
                generator.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
