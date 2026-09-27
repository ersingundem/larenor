from .immich import ImmichMemoryAdapter
from .models import (
    MemoryAsset,
    MemoryError,
    MemoryPolicy,
    MemorySearch,
    MemorySearchResult,
)
from .selection import (
    MemoryAlbum,
    MemoryAlbumAuthority,
    MemoryAlbumStore,
    MemorySelection,
)
from .service import FamilyMemoriesService


def __getattr__(name):
    if name == "router":
        from .api import router
        return router
    raise AttributeError(name)

__all__ = [
    "ImmichMemoryAdapter",
    "FamilyMemoriesService",
    "MemoryAlbum",
    "MemoryAlbumAuthority",
    "MemoryAlbumStore",
    "MemoryAsset",
    "MemoryError",
    "MemoryPolicy",
    "MemorySearch",
    "MemorySearchResult",
    "MemorySelection",
    "router",
]
