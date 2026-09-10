from collections.abc import Callable, Iterator
from dataclasses import dataclass
import hashlib
import math
import re
import secrets
import struct
import threading
from typing import Protocol

from ..errors import ApiError
from .models import BlobDescriptor, TransferLimits, TransferRequest


FRAME = struct.Struct(">4s32sQBI")
MAGIC = b"LRB1"
WIRE_TYPE = "application/vnd.larenor.blob-stream.v1"
_IDENTITY = re.compile(r"^[0-9a-f]{32}$")
_CONTENT_TYPE = re.compile(r"^[A-Za-z0-9!#$&^_.+\-/;= ]{1,128}$")


class BlobProvider(Protocol):
    """Trusted packaged provider seam; it accepts only a registry resource id."""

    def resolve(self, resource_id: str) -> BlobDescriptor | None: ...


class EmptyBlobProvider:
    """Production default: no binary resources are implicitly exposed."""

    def resolve(self, resource_id: str) -> BlobDescriptor | None:
        return None


@dataclass(frozen=True)
class TransferMetadata:
    trace_id: str
    content_length: int
    framed_length: int
    sha256: str
    content_type: str
    service_revision: int


class _Frames(Iterator[bytes]):
    def __init__(self, service, actor, scope, resource_id, body, descriptor,
                 metadata, deadline, cancelled):
        self._service = service
        self._actor = actor
        self._scope = scope
        self._resource_id = resource_id
        self._body = body
        self._descriptor = descriptor
        self._metadata = metadata
        self._deadline = deadline
        self._cancelled = cancelled
        self._offset = 0
        self._sequence = 0
        self._closed = False

    def __iter__(self):
        return self

    def __next__(self) -> bytes:
        if self._closed:
            raise StopIteration
        try:
            if self._cancelled():
                raise ApiError("transfer_cancelled", 408)
            if self._service.clock() >= self._deadline:
                raise ApiError("request_timeout", 408)
            self._service._revalidate(
                self._actor, self._scope, self._resource_id, self._body,
                self._descriptor, cancelled=False)
            if self._offset < len(self._descriptor.content):
                payload = self._descriptor.content[
                    self._offset:self._offset + self._service.limits.chunk_bytes]
                self._offset += len(payload)
                frame = self._encode(False, payload)
                self._sequence += 1
                return frame
            frame = self._encode(True, b"")
            self._sequence += 1
            self.close()
            return frame
        except BaseException:
            self.close()
            raise

    def _encode(self, final: bool, payload: bytes) -> bytes:
        return FRAME.pack(
            MAGIC, self._metadata.trace_id.encode("ascii"), self._sequence,
            int(final), len(payload)) + payload

    def close(self) -> None:
        if not self._closed:
            self._closed = True
            self._service._release(self._actor.id)


@dataclass
class OpenTransfer:
    metadata: TransferMetadata
    frames: _Frames

    def close(self) -> None:
        self.frames.close()


class BoundedTransferService:
    def __init__(self, registry, settings, provider: BlobProvider | None = None,
                 limits: TransferLimits | None = None):
        self.registry = registry
        self.clock = settings.clock
        self.provider = provider or EmptyBlobProvider()
        self.limits = limits or TransferLimits()
        self._lock = threading.Lock()
        self._active = 0
        self._active_by_actor: dict[str, int] = {}
        self._actor_quota: dict[str, tuple[int, int]] = {}

    @staticmethod
    def python_arguments(values: dict) -> dict:
        body = TransferRequest.model_validate(values)
        return {
            "expected_user_revision": body.expectedUserRevision,
            "expected_revision": body.expectedRevision,
            "expected_acl_revision": body.expectedAclRevision,
            "expected_service_revision": body.expectedServiceRevision,
            "deadline_ms": body.deadlineMs,
        }

    def _descriptor(self, resource_id: str) -> BlobDescriptor:
        descriptor = self.provider.resolve(resource_id)
        if descriptor is None:
            raise ApiError("not_found", 404)
        if (not isinstance(descriptor, BlobDescriptor) or
                descriptor.resource_id != resource_id or
                not _IDENTITY.fullmatch(descriptor.resource_id) or
                type(descriptor.service_revision) is not int or
                not 1 <= descriptor.service_revision <= 2**63 - 1 or
                not isinstance(descriptor.content, bytes) or
                not isinstance(descriptor.content_type, str) or
                not _CONTENT_TYPE.fullmatch(descriptor.content_type) or
                "\r" in descriptor.content_type or "\n" in descriptor.content_type):
            raise ApiError("server_unavailable", 503)
        return descriptor

    @staticmethod
    def _same(left: BlobDescriptor, right: BlobDescriptor) -> bool:
        return (left.resource_id == right.resource_id and
                left.service_revision == right.service_revision and
                left.content_type == right.content_type and
                len(left.content) == len(right.content) and
                hashlib.sha256(left.content).digest() == hashlib.sha256(right.content).digest())

    def _revalidate(self, actor, scope, resource_id, body, descriptor, *, cancelled,
                    consume_rate_limit=False):
        authorize = self.registry.authorize if consume_rate_limit else self.registry.reauthorize
        authorize(
            actor, scope[0], scope[1], resource_id, "read",
            expected_user_revision=body.expectedUserRevision,
            expected_revision=body.expectedRevision,
            expected_acl_revision=body.expectedAclRevision,
            cancelled=cancelled,
        )
        current = self._descriptor(resource_id)
        if current.service_revision != body.expectedServiceRevision or not self._same(current, descriptor):
            raise ApiError("revision_conflict", 409)

    def _reserve(self, actor_id: str, content_length: int) -> None:
        window = int(self.clock() // self.limits.quota_window_seconds)
        with self._lock:
            active = self._active_by_actor.get(actor_id, 0)
            if self._active >= self.limits.max_active_streams or active >= self.limits.max_active_per_actor:
                raise ApiError("rate_limited", 429)
            old_window, used = self._actor_quota.get(actor_id, (window, 0))
            if old_window != window:
                used = 0
            if used + content_length > self.limits.actor_bytes_per_window:
                raise ApiError("rate_limited", 429)
            self._active += 1
            self._active_by_actor[actor_id] = active + 1
            self._actor_quota[actor_id] = (window, used + content_length)
            self._actor_quota = {
                key: value for key, value in self._actor_quota.items()
                if value[0] >= window - 1
            }

    def _release(self, actor_id: str) -> None:
        with self._lock:
            count = self._active_by_actor.get(actor_id, 0)
            if count < 1 or self._active < 1:
                return
            self._active -= 1
            if count == 1:
                self._active_by_actor.pop(actor_id, None)
            else:
                self._active_by_actor[actor_id] = count - 1

    def open(self, actor, core_id: str, home_id: str, resource_id: str, *,
             expected_user_revision: int, expected_revision: int,
             expected_acl_revision: int, expected_service_revision: int,
             deadline_ms: int, cancelled: Callable[[], bool]) -> OpenTransfer:
        body = TransferRequest(
            expectedUserRevision=expected_user_revision,
            expectedRevision=expected_revision,
            expectedAclRevision=expected_acl_revision,
            expectedServiceRevision=expected_service_revision,
            deadlineMs=deadline_ms,
        )
        if cancelled():
            raise ApiError("transfer_cancelled", 408)
        descriptor = self._descriptor(resource_id)
        if descriptor.service_revision != body.expectedServiceRevision:
            raise ApiError("revision_conflict", 409)
        length = len(descriptor.content)
        chunks = math.ceil(length / self.limits.chunk_bytes)
        if length > self.limits.max_blob_bytes or chunks > self.limits.max_chunks:
            raise ApiError("payload_too_large", 413)
        self._revalidate(
            actor, (core_id, home_id), resource_id, body, descriptor,
            cancelled=False, consume_rate_limit=True)
        self._reserve(actor.id, length)
        trace = secrets.token_hex(16)
        metadata = TransferMetadata(
            trace_id=trace,
            content_length=length,
            framed_length=length + FRAME.size * (chunks + 1),
            sha256=hashlib.sha256(descriptor.content).hexdigest(),
            content_type=descriptor.content_type,
            service_revision=descriptor.service_revision,
        )
        frames = _Frames(
            self, actor, (core_id, home_id), resource_id, body, descriptor,
            metadata, self.clock() + deadline_ms / 1000, cancelled)
        return OpenTransfer(metadata, frames)
