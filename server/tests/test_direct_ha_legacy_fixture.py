"""Old fixture builders must omit the later identity-bound transfer domain."""
import pytest
from test_admin_migration import downgrade_to_known_v1
from test_core_context import legacy_v2


@pytest.mark.parametrize('builder',[downgrade_to_known_v1,legacy_v2])
def test_historical_fixture_does_not_retain_later_transfer_inventory(server,builder):
    app,_,_,_=server
    builder(app)
    with app.state.core.db.connection() as c:
        assert c.execute("SELECT name FROM sqlite_master WHERE name GLOB 'direct_ha_*'").fetchall()==[]
        assert c.execute("SELECT value FROM metadata WHERE key='direct_ha_schema'").fetchone() is None
