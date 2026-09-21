"""Read-only projection over durable managed-media execution receipts."""

from ..errors import ApiError
from .media_recovery_status_models import MediaRecoveryStatusResponse

_SERVICE_ORDER = (
    "larenor_core",
    "qbittorrent",
    "sonarr",
    "radarr",
    "jellyfin",
    "seerr",
    "music_assistant",
)
_INSTALLATION_SERVICES = frozenset({"jellyfin", "seerr", "music_assistant"})
_MAX_INSTALLATIONS = 256
_MAX_CONFIGURATIONS = 256


class MediaRecoveryStatusManagement:
    def __init__(
        self,
        db,
        installations,
        jellyfin_bootstraps,
        qbittorrent_configurations,
        arr_configurations,
        seerr_bootstraps,
        music_assistant_bootstraps,
        context,
    ):
        self.db = db
        self.installations = installations
        self.jellyfin_bootstraps = jellyfin_bootstraps
        self.qbittorrent_configurations = qbittorrent_configurations
        self.arr_configurations = arr_configurations
        self.seerr_bootstraps = seerr_bootstraps
        self.music_assistant_bootstraps = music_assistant_bootstraps
        self.context = context

    @staticmethod
    def _terminal(
        *,
        service_id,
        public,
        source_kind,
        container_state,
        service_verified=False,
        partial_action="review",
    ):
        state = public["state"]
        if state in {"queued", "running"}:
            result, action = "pending", "wait"
        elif state in {"container_started", "credentials_configured", "wiring_partial"}:
            result, action = "partial", partial_action
        elif state == "succeeded":
            if service_verified:
                result, action = "verified", "none"
            else:
                result, action = "partial", "review"
        elif state == "cancelled":
            result, action = "cancelled", "none"
        elif state == "needs_attention":
            result, action = "needs_attention", "review"
        else:
            result, action = "failed", "retry"
        return {
            "serviceId": service_id,
            "sourceId": public["id"],
            "sourceKind": source_kind,
            "revision": public["revision"],
            "resultState": result,
            "containerState": container_state,
            "serviceState": "verified" if service_verified else "unverified",
            "storedState": "stored",
            "reachableState": "reachable" if service_verified else "unknown",
            "verifiedState": "verified" if service_verified else "unverified",
            "recoveryAction": action,
            "automaticRetry": False,
            "errorCode": public["errorCode"],
            "updatedAt": public["updatedAt"],
        }

    def _core(self):
        return {
            "serviceId": "larenor_core",
            "sourceId": self.context.coreId,
            "sourceKind": "core",
            "revision": self.context.schemaVersion,
            "resultState": "verified",
            "containerState": "started",
            "serviceState": "verified",
            "storedState": "stored",
            "reachableState": "reachable",
            "verifiedState": "verified",
            "recoveryAction": "none",
            "automaticRetry": False,
            "errorCode": None,
            "updatedAt": None,
        }

    @staticmethod
    def _missing(service_id):
        return {
            "serviceId": service_id,
            "sourceId": None,
            "sourceKind": "missing",
            "revision": None,
            "resultState": "missing",
            "containerState": "unknown",
            "serviceState": "unverified",
            "storedState": "missing",
            "reachableState": "unknown",
            "verifiedState": "unverified",
            "recoveryAction": "configure",
            "automaticRetry": False,
            "errorCode": None,
            "updatedAt": None,
        }

    def _latest_installations(self, connection):
        rows = connection.execute(
            "SELECT * FROM media_installations ORDER BY sequence DESC LIMIT ?",
            (_MAX_INSTALLATIONS + 1,),
        ).fetchall()
        if len(rows) > _MAX_INSTALLATIONS:
            raise ApiError("media_installation_storage_unavailable", 503)
        latest = {}
        for row in rows:
            payload = self.installations._decode(row)
            service_id = payload.request.serviceId
            if service_id not in _INSTALLATION_SERVICES:
                raise ApiError("media_installation_storage_unavailable", 503)
            latest.setdefault(service_id, (row, payload))
        return latest

    def _installation_result(self, connection, service_id, row, payload):
        public = self.installations._public(row, payload)
        manager, table = {
            "jellyfin": (self.jellyfin_bootstraps, "media_service_bootstraps"),
            "seerr": (self.seerr_bootstraps, "media_seerr_bootstraps"),
            "music_assistant": (
                self.music_assistant_bootstraps,
                "media_music_assistant_bootstraps",
            ),
        }[service_id]
        bootstrap = connection.execute(
            f"SELECT * FROM {table} WHERE installation_id=?",
            (row["id"],),
        ).fetchone()
        if bootstrap is None:
            container_state = (
                "started"
                if row["state"] == "container_started"
                else "pending"
                if row["state"] in {"queued", "running"}
                else "unknown"
            )
            return self._terminal(
                service_id=service_id,
                public=public,
                source_kind="installation",
                container_state=container_state,
                partial_action="configure",
            )

        stored = manager._validate_row(connection, bootstrap)
        public = (
            manager._public(bootstrap, stored)
            if service_id == "seerr"
            else manager._public(bootstrap)
        )
        service_verified = (
            service_id == "seerr"
            and public["state"] == "succeeded"
            or service_id == "jellyfin"
            and public["state"] in {"wiring_partial", "succeeded"}
            and stored.readback is not None
        )
        if service_id == "music_assistant" and public["state"] == "succeeded":
            core_row = connection.execute(
                "SELECT * FROM music_assistant_core WHERE installation_id=?",
                (row["id"],),
            ).fetchone()
            if core_row is not None:
                core_stored = manager.core._decode(core_row)
                core_public = manager.core._public(connection, core_row, core_stored)
                service_verified = core_public["state"] == "verified"
        return self._terminal(
            service_id=service_id,
            public=public,
            source_kind="bootstrap",
            container_state="started",
            service_verified=service_verified,
        )

    def _qbittorrent(self, connection):
        rows = connection.execute(
            "SELECT * FROM media_qbittorrent_configurations "
            "ORDER BY sequence DESC LIMIT ?",
            (_MAX_CONFIGURATIONS + 1,),
        ).fetchall()
        if len(rows) > _MAX_CONFIGURATIONS:
            raise ApiError("media_qbittorrent_configuration_storage_unavailable", 503)
        decoded = [
            (row, self.qbittorrent_configurations._validate_row(connection, row))
            for row in rows
        ]
        if not decoded:
            return None
        row, payload = decoded[0]
        public = self.qbittorrent_configurations._public(row, payload)
        return self._terminal(
            service_id="qbittorrent",
            public=public,
            source_kind="configuration",
            container_state=(
                "started"
                if public["containerState"] == "container_started"
                else "pending"
                if public["state"] in {"queued", "running"}
                else "unknown"
            ),
            service_verified=public["serviceState"] == "verified",
        )

    def _arr(self, connection):
        rows = connection.execute(
            "SELECT * FROM media_arr_configurations ORDER BY sequence DESC LIMIT ?",
            (_MAX_CONFIGURATIONS + 1,),
        ).fetchall()
        if len(rows) > _MAX_CONFIGURATIONS:
            raise ApiError("media_arr_configuration_storage_unavailable", 503)
        latest = {}
        for row in rows:
            self.arr_configurations._validate_row(connection, row)
            public = self.arr_configurations._public(row)
            if public["serviceId"] in latest:
                continue
            latest[public["serviceId"]] = self._terminal(
                service_id=public["serviceId"],
                public=public,
                source_kind="configuration",
                container_state=(
                    "started"
                    if public["containerState"] == "container_started"
                    else "pending"
                    if public["state"] in {"queued", "running"}
                    else "unknown"
                ),
                service_verified=public["serviceState"] == "verified",
            )
        return latest

    def read(self, actor):
        with self.db.connection() as connection:
            connection.execute("BEGIN")
            self.installations._assert_admin(connection, actor)
            results = {"larenor_core": self._core()}
            qbittorrent = self._qbittorrent(connection)
            if qbittorrent is not None:
                results["qbittorrent"] = qbittorrent
            results.update(self._arr(connection))
            for service_id, (row, payload) in self._latest_installations(
                connection
            ).items():
                results[service_id] = self._installation_result(
                    connection, service_id, row, payload
                )
            services = [
                results.get(item, self._missing(item)) for item in _SERVICE_ORDER
            ]
            state = (
                "attention"
                if any(
                    item["resultState"] in {"needs_attention", "failed"}
                    for item in services
                )
                else "ready"
                if all(item["resultState"] == "verified" for item in services)
                else "incomplete"
            )
            return MediaRecoveryStatusResponse.model_validate(
                {
                    "schemaVersion": 2,
                    "state": state,
                    "installAvailable": False,
                    "services": services,
                }
            ).model_dump()
