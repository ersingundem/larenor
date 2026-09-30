"""Bind the read-only Zigbee2MQTT observer to current Core authority."""

from __future__ import annotations

import threading

from ..errors import ApiError
from .models import MeshAuthority
from .zigbee2mqtt_provider import Zigbee2MqttProvider


class CoreMeshAuthoritySource:
    def __init__(self, db, auth, context):
        self._db = db
        self._auth = auth
        self._context = context
        self._local = threading.local()

    def _resolve(self, actor):
        with self._db.connection() as connection:
            self._auth.assert_current(connection, actor)
            row = connection.execute(
                "SELECT revision,role,must_change_password,disabled "
                "FROM users WHERE id=?", (actor.id,)
            ).fetchone()
        if row is None:
            raise ApiError("invalid_session", 401)
        active = not bool(row["disabled"]) and not bool(row["must_change_password"])
        return MeshAuthority(
            schemaVersion=1,
            coreId=self._context.coreId,
            homeId=self._context.homeId,
            homeRevision=1,
            accountId=actor.id,
            accountRevision=row["revision"],
            memberRevision=row["revision"],
            sessionFamilyId=actor.family_id,
            role=row["role"],
            active=active,
            canObserveMesh=active and row["role"] == "admin",
            # This provider deliberately advertises an empty signed catalog.
            canUpdateMesh=False,
        )

    def for_actor(self, actor):
        authority = self._resolve(actor)
        self._local.actor = actor
        return authority

    def for_account(self, account_id):
        actor = getattr(self._local, "actor", None)
        if actor is None or actor.id != account_id:
            return None
        try:
            return self._resolve(actor)
        except ApiError:
            return None


def build_core_zigbee2mqtt_provider(*, db, auth, context, master_key, observer):
    if not callable(getattr(observer, "observe", None)):
        raise ValueError("invalid_mesh_observer")
    authority = CoreMeshAuthoritySource(db, auth, context)
    return Zigbee2MqttProvider(
        core_id=context.coreId,
        home_id=context.homeId,
        master_key=master_key,
        observe=observer.observe,
        authority_for_actor=authority.for_actor,
        authority_for_account=authority.for_account,
    )
