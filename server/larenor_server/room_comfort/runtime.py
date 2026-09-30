"""Normal Core composition for the trusted Home Assistant comfort worker."""

from ..errors import ApiError
from .home_assistant import HomeAssistantComfortExecutor
from .source_store import RoomComfortSourceStore
from .provisioning import RoomComfortProvisioner


def build_room_comfort_runtime(
    db, auth, key, context, services, home_resources, *, transport_factory=None
):
    def connection(connection, service_id, revision):
        return services()._authenticated_home_assistant_connection(
            connection, service_id, revision
        )

    def resources(connection, rooms):
        home_resources._check_context(
            connection, context.coreId, context.homeId
        )
        for item in rooms:
            room_row, room_ref, _room = home_resources._target(
                connection, item.roomId
            )
            area_row, area_ref, _area = home_resources._target(
                connection, item.areaId
            )
            if (
                room_ref.kind != "room"
                or area_ref.kind != "resource"
                or room_row["revision"] != item.roomRevision
                or area_row["revision"] != item.areaRevision
            ):
                raise ApiError("revision_conflict", 409)
        return home_resources._state(connection)["revision"]

    provisioner = RoomComfortProvisioner(
        db, auth, services, home_resources, context, connection, resources
    )
    store = RoomComfortSourceStore(
        db, auth, key, context, connection, resources,
        preflight=provisioner.verify,
    )
    store.validate_storage()
    return (
        store,
        HomeAssistantComfortExecutor(
            store, transport_factory=transport_factory
        ),
        provisioner,
    )
