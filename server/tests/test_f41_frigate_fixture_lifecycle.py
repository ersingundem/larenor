"""The owned Frigate/HA fixture must finish the actual WebSocket lifetime."""

from types import MappingProxyType

from larenor_server.home_assistant.read_only_websocket import HomeAssistantReadOnlyWebSocket
from larenor_server.services.service import ServiceConnection
from support.f41_frigate_fixture import FrigateFixture


def test_registry_fixture_observes_masked_client_close_before_retiring_socket():
    upstream = FrigateFixture()
    connection = ServiceConnection(
        id='a' * 32, name='Owned registry', kind='home_assistant',
        base_url=upstream.url, revision=1,
        credentials=MappingProxyType({'token': upstream.token}),
    )
    try:
        with HomeAssistantReadOnlyWebSocket(connection).session(timeout=2) as session:
            result = session.list_entity_registry()
        assert {value['entity_id'] for value in result} == {'camera.front', 'camera.back'}
        assert upstream.websocket_close_event.wait(2)
    finally:
        upstream.close()
    assert upstream.errors == []
    assert getattr(upstream, 'websocket_close_count', 0) == 1
