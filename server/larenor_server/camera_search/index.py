"""Local, revision-bound camera metadata index with opaque pagination."""

from collections import OrderedDict
from dataclasses import dataclass
import hashlib
import hmac
import json
import secrets
import threading
import unicodedata
from typing import Callable, Iterable

from ..errors import ApiError
from .models import (
    CameraEvidenceLink,
    CameraMetadataRecord,
    CameraSearchAuthority,
    CameraSearchMatch,
    CameraSearchPage,
    CameraSearchRequest,
    safe_text,
)


MAX_RECORDS = 10_000
MAX_CURSORS = 4_096
MAX_PLANNER_TERMS = 16


def _normalise(value: str) -> str:
    folded = unicodedata.normalize(
        "NFKD", value.casefold().translate(str.maketrans({"ı": "i", "ş": "s"}))
    )
    return "".join(char for char in folded if not unicodedata.combining(char))


def _terms(value: str) -> tuple[str, ...]:
    normal = _normalise(value)
    words = []
    for raw in normal.split():
        word = "".join(char for char in raw if char.isalnum() or char in "_-").strip(
            "_-"
        )
        if word and word not in words:
            words.append(word)
    return tuple(sorted(words))


def _term_matches(term: str, candidate: str) -> bool:
    if term == candidate:
        return True
    return len(term) >= 3 and (term in candidate or candidate in term)


@dataclass(frozen=True)
class _CursorState:
    request_digest: str
    authority_digest: str
    index_revision: int
    offset: int
    terms: tuple[str, ...]
    mode: str
    status: str


class CameraSearchIndex:
    """Immutable metadata snapshot; no clip bytes or provider credentials enter it."""

    def __init__(
        self,
        records: Iterable[CameraMetadataRecord],
        *,
        revision: int,
        cursorKey: bytes,
        authorityResolver: Callable[[str], CameraSearchAuthority | None],
        queryPlanner: Callable[[str], Iterable[str]] | None = None,
    ):
        if type(revision) is not int or revision < 1 or revision > 2**63 - 1:
            raise ValueError("invalid_revision")
        if not isinstance(cursorKey, bytes) or len(cursorKey) < 32:
            raise ValueError("invalid_cursor_key")
        source = tuple(CameraMetadataRecord.model_validate(item) for item in records)
        if len(source) > MAX_RECORDS:
            raise ValueError("record_limit")
        if len(
            {(item.homeId, item.clipId, item.captureRevision) for item in source}
        ) != len(source):
            raise ValueError("duplicate_record")
        self._records = source
        self._revision = revision
        self._cursor_key = cursorKey
        self._resolve_authority = authorityResolver
        self._planner = queryPlanner
        self._cursors: OrderedDict[str, _CursorState] = OrderedDict()
        self._cursor_lock = threading.Lock()

    @property
    def revision(self) -> int:
        return self._revision

    @staticmethod
    def _request_digest(request: CameraSearchRequest) -> str:
        raw = json.dumps(
            {
                "query": request.query,
                "start": request.startMs,
                "end": request.endMs,
                "cameras": request.cameraIds,
                "page": request.pageSize,
            },
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
        ).encode("utf-8")
        return hashlib.sha256(raw).hexdigest()

    @staticmethod
    def _authority_digest(authority: CameraSearchAuthority) -> str:
        raw = json.dumps(
            {
                "core": authority.coreId,
                "home": authority.homeId,
                "homeRevision": authority.homeRevision,
                "account": authority.accountId,
                "accountRevision": authority.accountRevision,
                "memberRevision": authority.memberRevision,
                "session": authority.sessionFamilyId,
                "role": authority.role,
                "private": authority.allowPrivateEvidence,
                "cameras": authority.accessibleCameraIds,
            },
            separators=(",", ":"),
            sort_keys=True,
        ).encode("utf-8")
        return hashlib.sha256(raw).hexdigest()

    def _open_cursor(self, cursor: str) -> _CursorState:
        try:
            nonce, signature = cursor.split(".", 1)
            expected = hmac.new(
                self._cursor_key, nonce.encode("ascii"), hashlib.sha256
            ).hexdigest()
            if not hmac.compare_digest(signature, expected):
                raise ValueError
        except (AttributeError, UnicodeError, ValueError):
            raise ApiError("invalid_request") from None
        with self._cursor_lock:
            state = self._cursors.get(cursor)
        if state is None:
            raise ApiError("invalid_request")
        return state

    def _new_cursor(self, state: _CursorState) -> str:
        nonce = secrets.token_urlsafe(24)
        signature = hmac.new(
            self._cursor_key, nonce.encode("ascii"), hashlib.sha256
        ).hexdigest()
        cursor = nonce + "." + signature
        with self._cursor_lock:
            self._cursors[cursor] = state
            while len(self._cursors) > MAX_CURSORS:
                self._cursors.popitem(last=False)
        return cursor

    def _validate_authority(
        self, presented: CameraSearchAuthority
    ) -> CameraSearchAuthority:
        try:
            authority = CameraSearchAuthority.model_validate(presented)
        except ValueError:
            raise ApiError("invalid_request") from None
        try:
            current = self._resolve_authority(authority.accountId)
        except Exception:
            raise ApiError("forbidden", 403) from None
        if current is None:
            raise ApiError("forbidden", 403)
        try:
            current = CameraSearchAuthority.model_validate(current)
        except ValueError:
            raise ApiError("forbidden", 403) from None
        if current != authority:
            raise ApiError("revision_conflict", 409)
        if not authority.active or not authority.canSearch:
            raise ApiError("forbidden", 403)
        return authority

    def _plan(self, query: str) -> tuple[tuple[str, ...], str, str]:
        local = _terms(query)
        if not local:
            raise ApiError("invalid_request")
        if self._planner is None:
            return local, "local_metadata", "degraded"
        try:
            planned = tuple(self._planner(query))
            if not 1 <= len(planned) <= MAX_PLANNER_TERMS:
                raise ValueError
            cleaned = tuple(
                sorted(set(_terms(" ".join(safe_text(item) for item in planned))))
            )
            if not cleaned or len(cleaned) > MAX_PLANNER_TERMS:
                raise ValueError
            return cleaned, "semantic_assisted", "ready"
        except Exception:
            return local, "local_metadata", "degraded"

    def search(
        self, presentedAuthority: CameraSearchAuthority, rawRequest: CameraSearchRequest
    ) -> CameraSearchPage:
        authority = self._validate_authority(presentedAuthority)
        try:
            request = CameraSearchRequest.model_validate(rawRequest)
        except ValueError:
            raise ApiError("invalid_request") from None
        if request.expectedIndexRevision != self._revision:
            raise ApiError("revision_conflict", 409)
        accessible = set(authority.accessibleCameraIds)
        if not set(request.cameraIds).issubset(accessible):
            # Do not disclose whether a camera exists outside this authority.
            raise ApiError("not_found", 404)

        request_digest = self._request_digest(request)
        authority_digest = self._authority_digest(authority)
        if request.cursor is None:
            terms, mode, status = self._plan(request.query)
            offset = 0
        else:
            state = self._open_cursor(request.cursor)
            if state.index_revision != self._revision:
                raise ApiError("revision_conflict", 409)
            if (
                state.request_digest != request_digest
                or state.authority_digest != authority_digest
            ):
                raise ApiError("invalid_request")
            terms, mode, status, offset = (
                state.terms,
                state.mode,
                state.status,
                state.offset,
            )

        candidates: list[tuple[int, CameraMetadataRecord, tuple[str, ...]]] = []
        requested_cameras = set(request.cameraIds)
        for item in self._records:
            if item.coreId != authority.coreId or item.homeId != authority.homeId:
                continue
            if item.cameraId not in requested_cameras:
                continue
            if item.startMs >= request.endMs or item.endMs <= request.startMs:
                continue
            if item.visibility == "private" and not (
                item.ownerAccountId == authority.accountId
                or authority.allowPrivateEvidence
            ):
                continue
            metadata = _terms(item.summary + " " + " ".join(item.labels))
            matched = tuple(
                term
                for term in terms
                if any(_term_matches(term, word) for word in metadata)
            )
            if matched:
                candidates.append((len(matched), item, matched))
        candidates.sort(
            key=lambda entry: (-entry[0], -entry[1].startMs, entry[1].clipId)
        )

        page_source = candidates[offset : offset + request.pageSize]
        results = [
            CameraSearchMatch(
                schemaVersion=1,
                startMs=item.startMs,
                endMs=item.endMs,
                summary=item.summary,
                matchedTerms=list(matched),
                evidence=CameraEvidenceLink(
                    schemaVersion=1,
                    kind="camera_evidence",
                    coreId=item.coreId,
                    homeId=item.homeId,
                    cameraId=item.cameraId,
                    clipId=item.clipId,
                    eventId=item.eventId,
                    captureRevision=item.captureRevision,
                    indexRevision=self._revision,
                    capturedAtMs=item.startMs + item.evidenceOffsetMs,
                ),
            )
            for _, item, matched in page_source
        ]
        next_offset = offset + len(page_source)
        next_cursor = None
        if next_offset < len(candidates):
            next_cursor = self._new_cursor(
                _CursorState(
                    request_digest=request_digest,
                    authority_digest=authority_digest,
                    index_revision=self._revision,
                    offset=next_offset,
                    terms=terms,
                    mode=mode,
                    status=status,
                )
            )
        return CameraSearchPage(
            schemaVersion=1,
            indexRevision=self._revision,
            mode=mode,
            status=status,
            degradedReason="semantic_provider_unavailable"
            if status == "degraded"
            else None,
            results=results,
            nextCursor=next_cursor,
        )
