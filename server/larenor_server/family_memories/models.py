import re
from dataclasses import dataclass
from datetime import datetime

_UUID = re.compile(
    r"[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\Z"
)
_ID = re.compile(r"[0-9a-f]{32}\Z")
_LANGUAGE = re.compile(r"[a-z]{2,3}(?:-[A-Z]{2})?\Z")


class MemoryError(Exception):
    def __init__(self, code: str):
        self.code = code
        super().__init__(code)


def _uuid(value: object) -> bool:
    return isinstance(value, str) and bool(_UUID.fullmatch(value))


def _id(value: object) -> bool:
    return isinstance(value, str) and bool(_ID.fullmatch(value))


def _safe_text(value: object, limit: int) -> bool:
    return (
        isinstance(value, str)
        and 0 < len(value) <= limit
        and not any(
            ord(char) < 32 or ord(char) == 127 or 0xD800 <= ord(char) <= 0xDFFF
            for char in value
        )
    )


@dataclass(frozen=True)
class MemoryPolicy:
    core_id: str
    home_id: str
    account_id: str
    service_id: str
    service_revision: int
    allowed_album_ids: tuple[str, ...]
    face_search_enabled: bool = False

    def __post_init__(self) -> None:
        if (
            not all(
                _id(value)
                for value in (
                    self.core_id,
                    self.home_id,
                    self.account_id,
                    self.service_id,
                )
            )
            or type(self.service_revision) is not int
            or not 1 <= self.service_revision <= 2**63 - 1
            or not isinstance(self.allowed_album_ids, tuple)
            or not 1 <= len(self.allowed_album_ids) <= 32
            or len(set(self.allowed_album_ids)) != len(self.allowed_album_ids)
            or any(not _uuid(value) for value in self.allowed_album_ids)
            or type(self.face_search_enabled) is not bool
        ):
            raise MemoryError("invalid_policy")


@dataclass(frozen=True)
class MemorySearch:
    query: str
    album_ids: tuple[str, ...]
    limit: int = 48
    language: str = "tr"
    person_ids: tuple[str, ...] = ()
    taken_after: str | None = None
    taken_before: str | None = None

    def __post_init__(self) -> None:
        query = self.query.strip() if isinstance(self.query, str) else ""
        if (
            not _safe_text(query, 256)
            or query != self.query
            or not isinstance(self.album_ids, tuple)
            or not 1 <= len(self.album_ids) <= 16
            or len(set(self.album_ids)) != len(self.album_ids)
            or any(not _uuid(value) for value in self.album_ids)
            or type(self.limit) is not int
            or not 1 <= self.limit <= 100
            or not isinstance(self.language, str)
            or not _LANGUAGE.fullmatch(self.language)
            or not isinstance(self.person_ids, tuple)
            or len(self.person_ids) > 16
            or len(set(self.person_ids)) != len(self.person_ids)
            or any(not _uuid(value) for value in self.person_ids)
        ):
            raise MemoryError("invalid_search")
        after = _instant(self.taken_after)
        before = _instant(self.taken_before)
        if after is not None and before is not None and after >= before:
            raise MemoryError("invalid_search")


@dataclass(frozen=True)
class MemoryAsset:
    id: str
    file_name: str
    taken_at: str
    thumbhash: str | None


@dataclass(frozen=True)
class MemorySearchResult:
    assets: tuple[MemoryAsset, ...]


def _instant(value: str | None) -> datetime | None:
    if value is None:
        return None
    if not isinstance(value, str) or len(value) > 40:
        raise MemoryError("invalid_search")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        raise MemoryError("invalid_search") from None
    if parsed.tzinfo is None:
        raise MemoryError("invalid_search")
    return parsed
