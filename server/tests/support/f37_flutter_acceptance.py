"""Actual F37 Client, encrypted normal Core and immutable corrections."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from conftest import ready, server as core_fixture
from test_admin import activate, create as create_user
from support.installed_core_tcp import InstalledCoreTcp


def main():
    with tempfile.TemporaryDirectory(prefix='larenor-f37-client-') as root:
        state = Path(root) / 'client-proof.json'
        for phase in ('create', 'restart'):
            generator = core_fixture.__wrapped__(Path(root))
            app, client, settings, clock = next(generator)
            try:
                if phase == 'create':
                    admin = ready((app, client, settings, clock))
                    create_user(client, admin)
                    activate(client, 'member')
                with InstalledCoreTcp(app) as tcp:
                    result = subprocess.run([
                        'flutter', 'test', '--no-pub',
                        'test/features/shared_expenses/shared_expense_normal_core_test.dart',
                    ], env={**os.environ,
                        'LARENOR_EXPENSE_CORE_URL': f'http://127.0.0.1:{tcp.port}',
                        'LARENOR_EXPENSE_PHASE': phase,
                        'LARENOR_EXPENSE_STATE_FILE': str(state)},
                        cwd=Path(__file__).resolve().parents[3], timeout=120, check=False)
                    if result.returncode:
                        return result.returncode
                with app.state.core.db.connection() as connection:
                    expected = 3 if phase == 'create' else 4
                    for table in ('shared_expense_records', 'shared_expense_events'):
                        if connection.execute('SELECT COUNT(*) FROM ' + table).fetchone()[0] != expected:
                            raise RuntimeError('expense_exact_effect_count')
                    ciphertexts = connection.execute('SELECT ciphertext FROM shared_expense_records').fetchall()
                    if any(b'Corrected' in row['ciphertext'] for row in ciphertexts):
                        raise RuntimeError('expense_payload_not_private')
                app.state.core.shared_expenses.store.validate_storage(
                    core_id=app.state.core.context.coreId, home_id=app.state.core.context.homeId)
            finally:
                generator.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
