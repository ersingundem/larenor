"""Durable, evidence-bound F30 media archive action workflows."""

from .schema import migrate_media_archive_actions
from .service import MediaArchiveActionService
from .worker_ipc import (
    MEDIA_ARCHIVE_ACTION_POLICY_DIGEST,
    MediaArchiveActionWorkerClient,
    MediaArchiveActionWorkerServer,
    UnavailableMediaArchiveActionHandler,
)


def __getattr__(name):
    # Keep CoreServices imports acyclic; FastAPI asks for the router later.
    if name == "router":
        from .api import router
        return router
    raise AttributeError(name)

__all__ = [
    "MediaArchiveActionService",
    "MEDIA_ARCHIVE_ACTION_POLICY_DIGEST",
    "MediaArchiveActionWorkerClient",
    "MediaArchiveActionWorkerServer",
    "UnavailableMediaArchiveActionHandler",
    "migrate_media_archive_actions",
    "router",
]
