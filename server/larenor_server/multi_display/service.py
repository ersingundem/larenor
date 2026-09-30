"""Read-only authority and public health for an isolated presentation.

No token, provider payload, media metadata, floor-plan data, or private home
resource is projected. The secondary engine can only select a packaged public
surface after the primary engine has checked this exact authority.
"""

import os
import resource
import sys
import time

from ..errors import ApiError
from .models import MultiDisplayAuthority, MultiDisplayProjection, PublicCoreStatus


_ROUTES = ("core.status",)
_MAX_CLIENT_REVISION = 2**53 - 1
_STARTED = time.monotonic()


def _authority(core, actor, core_id, home_id, connection):
    core.auth.assert_current(connection, actor)
    if actor.must_change_password:
        raise ApiError("password_change_required", 403)
    core.home_resources._check_context(connection, core_id, home_id)
    state = core.home_resources._state(connection)
    user = connection.execute(
        "SELECT id,revision,disabled,must_change_password FROM users WHERE id=?",
        (actor.id,),
    ).fetchone()
    if (
        user is None
        or user["disabled"]
        or user["must_change_password"]
        or user["id"] != actor.id
    ):
        raise ApiError("invalid_session", 401)
    account_revision = user["revision"]
    home_revision = state["revision"]
    if not (
        type(account_revision) is int
        and type(home_revision) is int
        and 1 <= account_revision <= _MAX_CLIENT_REVISION
        and 1 <= home_revision <= _MAX_CLIENT_REVISION
    ):
        raise ApiError("server_unavailable", 503)
    return MultiDisplayAuthority(
        coreId=core_id,
        homeId=home_id,
        accountId=actor.id,
        accountRevision=account_revision,
        homeRevision=home_revision,
        sessionFamilyId=actor.family_id,
        allowedSecondaryRoutes=_ROUTES,
    )


def _process_memory_mib():
    try:
        with open("/proc/self/statm", encoding="ascii") as stream:
            pages = int(stream.read().split()[1])
        return max(0, pages * os.sysconf("SC_PAGE_SIZE") // 1_048_576)
    except (OSError, ValueError, IndexError):
        value = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
        byte_count = value if sys.platform == "darwin" else value * 1024
        return max(0, int(byte_count // 1_048_576))


def _public_snapshot(core):
    try:
        observed_at = int(float(core.settings.clock()) * 1000)
        snapshot_revision = max(1, int(time.monotonic() * 1000))
        load = os.getloadavg()[0]
        system_load = max(
            0, min(100, round(load * 100 / max(1, os.cpu_count() or 1)))
        )
        memory = _process_memory_mib()
        volume = os.statvfs(core.settings.data_dir)
        total = volume.f_blocks * volume.f_frsize
        free = volume.f_bavail * volume.f_frsize
        uptime = max(0, int(time.monotonic() - _STARTED))
        values = (observed_at, snapshot_revision, memory, total, free, uptime)
        if (
            any(type(value) is not int or value < 0 for value in values)
            or observed_at + 15_000 > _MAX_CLIENT_REVISION
            or snapshot_revision > _MAX_CLIENT_REVISION
            or memory > 1_048_576
            or total < 1
            or total > _MAX_CLIENT_REVISION
            or free > total
            or uptime > _MAX_CLIENT_REVISION
        ):
            raise ValueError
        return PublicCoreStatus(
            snapshotRevision=snapshot_revision,
            observedAtMs=observed_at,
            expiresAtMs=observed_at + 15_000,
            systemLoadPercent=system_load,
            processMemoryMiB=memory,
            dataDiskFreeBytes=free,
            dataDiskTotalBytes=total,
            processUptimeSeconds=uptime,
        )
    except (OSError, ValueError, TypeError, IndexError):
        raise ApiError("server_unavailable", 503) from None


def read_authority(core, actor, core_id: str, home_id: str) -> MultiDisplayProjection:
    core.auth.rate_limit([("multi_display_read", actor.id, 120)])
    with core.db.transaction() as connection:
        before = _authority(core, actor, core_id, home_id, connection)
    snapshot = _public_snapshot(core)
    with core.db.transaction() as connection:
        after = _authority(core, actor, core_id, home_id, connection)
    if after != before:
        raise ApiError("multi_display_authority_changed", 409)
    return MultiDisplayProjection(authority=after, publicSnapshot=snapshot)
