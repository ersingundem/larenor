"""Normal Core composition for authenticated HA MQTT-room observations."""

import hashlib
import hmac

from ..errors import ApiError
from .home_assistant_provider import HomeAssistantMqttRoomProvider
from .provider_source import MqttRoomSourceStore
from .repository import RoomPresenceRepository


class RoomPresenceRuntime:
    def __init__(self, repository, source_store, provider):
        self.repository = repository
        self.source_store = source_store
        self.provider = provider

    def validate_storage(self):
        self.repository.validate_storage()
        self.source_store.validate_storage()

    def configuration_setup(self, actor):
        return self.provider.setup(actor)

    def configuration_entities(self, actor, service_id, revision):
        return self.provider.entities(actor, service_id, revision)

    def configuration(self, actor):
        return {
            "schemaVersion": 1,
            "configuration": self.source_store.get(actor),
        }

    def configure(self, actor, value):
        source = self.source_store.put(
            actor,
            value,
            update_state=self.repository.register_provider_in_transaction,
            transaction_guard=self.repository.provider_source_update,
        )
        return {
            "schemaVersion": 1,
            "configuration": self.source_store.view(source),
        }

    def revoke_configuration(self, actor, value):
        source = self.source_store.revoke(
            actor,
            value,
            update_state=self.repository.revoke_provider_in_transaction,
            transaction_guard=self.repository.provider_source_update,
        )
        return {
            "schemaVersion": 1,
            "configuration": self.source_store.view(source),
        }

    def _observe(self, actor):
        source = self.source_store.internal_source()
        if source is None or not source.consentActive:
            return
        policy = self.source_store.policy(source)
        try:
            _current_source, observed_policy, signal = self.provider.observe(
                actor, self.source_store
            )
            if observed_policy != policy:
                raise ApiError("revision_conflict", 409)
            self.repository.set_provider_reachable(policy.policyId, True)
            self.repository.fuse_local(
                actor, policy.policyId, [signal],
                now_ms=self.provider.now_ms(),
                idempotent_provider=True,
            )
        except ApiError as error:
            if error.code in {"invalid_session", "forbidden"}:
                raise
            try:
                self.repository.set_provider_reachable(
                    policy.policyId, False
                )
            except ApiError:
                pass

    def scope_authority(self, *args, **kwargs):
        return self.repository.scope_authority(*args, **kwargs)

    def list_devices(self, actor, *args, **kwargs):
        self._observe(actor)
        return self.repository.list_devices(actor, *args, **kwargs)

    def readback(self, actor, *args, **kwargs):
        self._observe(actor)
        return self.repository.readback(actor, *args, **kwargs)

    def preview(self, *args, **kwargs):
        return self.repository.preview(*args, **kwargs)

    def confirm(self, *args, **kwargs):
        return self.repository.confirm(*args, **kwargs)

    # Retained package-private seams used by existing focused reducer tests.
    def register_local(self, *args, **kwargs):
        return self.repository.register_local(*args, **kwargs)

    def fuse_local(self, *args, **kwargs):
        return self.repository.fuse_local(*args, **kwargs)


def build_room_presence_runtime(
    db, auth, settings, key, context, services, home_resources,
    *, websocket_factory=None, transport_factory=None,
):
    def service(connection, service_id, revision):
        return services()._authenticated_home_assistant_connection(
            connection, service_id, revision
        )

    def room(connection, room_id, revision):
        home_resources._check_context(
            connection, context.coreId, context.homeId
        )
        row, ref, record = home_resources._target(connection, room_id)
        if ref.kind != "room" or row["revision"] != revision:
            raise ApiError("revision_conflict", 409)
        return record.label

    provider = HomeAssistantMqttRoomProvider(
        db, auth, services, home_resources, context, service, room,
        clock=settings.clock,
        candidate_key=hmac.new(
            key, b"larenor-room-presence-candidate-v1", hashlib.sha256
        ).digest(),
        websocket_factory=websocket_factory,
        transport_factory=transport_factory,
    )
    store = MqttRoomSourceStore(
        db, auth, key, context, service, room, preflight=provider.preflight
    )
    repository = RoomPresenceRepository(
        db, auth, settings, key, context
    )
    runtime = RoomPresenceRuntime(repository, store, provider)
    runtime.validate_storage()
    return runtime


__all__ = ["RoomPresenceRuntime", "build_room_presence_runtime"]
