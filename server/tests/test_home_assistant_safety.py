"""Authority races and bounded persistence regressions for the actual adapter."""
import json
import tracemalloc

import pytest

from conftest import auth
from test_home_assistant_adapter import ha, setup, bind
from larenor_server.home_assistant import schema
from larenor_server.home_assistant.models import Projection


def test_anonymous_core_read_is_401_not_request_validation(server, ha):
    _, client, _, _, _, _, public, _ = setup(server, ha)
    response = client.get(public + '/snapshot')
    assert response.status_code == 401 and response.json()['error']['code'] == 'invalid_session'
    assert ha.calls == 0


def test_cache_is_purged_when_revoked_session_is_rejected_before_route(server, ha):
    app, client, admin, _, _, base, public, body = setup(server, ha)
    bind(client, admin, base, body)
    assert client.get(public + '/snapshot', headers=auth(admin)).status_code == 200
    assert app.state.core.home_assistant._cache
    assert client.post('/api/v1/auth/logout', headers=auth(admin), json={'refreshToken':admin['refreshToken']}).status_code == 204
    before = ha.calls
    assert client.get(public + '/snapshot', headers=auth(admin)).status_code == 401
    assert not app.state.core.home_assistant._cache
    assert ha.calls == before


def test_storage_bound_precedes_materializing_corrupt_payload(server, ha):
    app, client, admin, _, _, base, _, body = setup(server, ha)
    bind(client, admin, base, body)
    with app.state.core.db.transaction() as c:
        c.execute('UPDATE home_assistant_bindings SET ciphertext=zeroblob(4194304)')
    with app.state.core.db.connection() as c:
        tracemalloc.start()
        try:
            with pytest.raises(ValueError):
                schema.rows(c)
            _, peak = tracemalloc.get_traced_memory()
        finally:
            tracemalloc.stop()
    assert peak < 1024 * 1024


@pytest.mark.parametrize('value',[0,1,'false',None])
def test_command_capability_requires_literal_false(value):
    with pytest.raises(ValueError):
        Projection(state='on', commandAvailable=value)
