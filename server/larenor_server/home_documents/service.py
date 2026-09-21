import hashlib
import json
import math
import re
import threading
from collections.abc import Callable
from dataclasses import dataclass
from datetime import date, timedelta
from functools import wraps

from ..errors import ApiError
from ..home_resources.models import HomeScope
from .models import (
    ConfirmWarrantyCommand,
    CreateHomeDocumentCommand,
    DocumentActor,
    DocumentAuthority,
    DocumentBlobRef,
    DocumentCommandResult,
    DocumentPage,
    HomeDocument,
    HomeDocumentRef,
    WarrantyReminder,
    WarrantyReminderPage,
    WarrantyState,
)

MAX_DOCUMENTS = 512
MAX_RECEIPTS = 2048


def _synchronized(method):
    @wraps(method)
    def guarded(self, *args, **kwargs):
        with self._lock:
            return method(self, *args, **kwargs)

    return guarded


@dataclass(frozen=True)
class _Record:
    document: HomeDocument
    created_by: str
    readers: frozenset[str]
    reminder_days: tuple[int, ...]
    library_revision: int


class HomeDocumentLibrary:
    """Bounded reducer; durable encrypted storage and HTTP wiring are later slices."""

    def __init__(
        self,
        scope: HomeScope,
        *,
        blob_current: Callable[[DocumentActor, DocumentBlobRef], bool],
        inventory_current: Callable[[DocumentActor, str], bool],
        clock: Callable[[], float],
    ):
        self.scope = HomeScope.model_validate(scope)
        self._blob_current = blob_current
        self._inventory_current = inventory_current
        self._clock = clock
        self._lock = threading.RLock()
        self._revision = 0
        self._documents: dict[str, _Record] = {}
        self._receipts: dict[tuple[str, str], tuple[str, DocumentCommandResult]] = {}

    @property
    def revision(self):
        return self._revision

    def snapshot_state(self):
        return {
            "schemaVersion": 1,
            "scope": self.scope.model_dump(mode="json"),
            "revision": self._revision,
            "documents": [
                {
                    "document": record.document.model_dump(mode="json"),
                    "createdBy": record.created_by,
                    "readerIds": sorted(record.readers),
                    "reminderLeadDays": list(record.reminder_days),
                    "libraryRevision": record.library_revision,
                }
                for _identity, record in sorted(self._documents.items())
            ],
            "receipts": [
                {
                    "familyId": family_id,
                    "requestId": request_id,
                    "fingerprint": fingerprint,
                    "result": result.model_dump(mode="json"),
                }
                for (family_id, request_id), (fingerprint, result) in sorted(
                    self._receipts.items()
                )
            ],
        }

    def restore_state(self, value):
        if (
            type(value) is not dict
            or set(value)
            != {
                "schemaVersion",
                "scope",
                "revision",
                "documents",
                "receipts",
            }
            or value["schemaVersion"] != 1
            or HomeScope.model_validate(value["scope"]) != self.scope
            or type(value["revision"]) is not int
            or not 0 <= value["revision"] <= 2**63 - 1
            or type(value["documents"]) is not list
            or len(value["documents"]) > MAX_DOCUMENTS
            or type(value["receipts"]) is not list
            or len(value["receipts"]) > MAX_RECEIPTS
        ):
            raise ValueError("invalid_home_document_state")
        documents = {}
        for raw in value["documents"]:
            if type(raw) is not dict or set(raw) != {
                "document",
                "createdBy",
                "readerIds",
                "reminderLeadDays",
                "libraryRevision",
            }:
                raise ValueError("invalid_home_document_record")
            document = HomeDocument.model_validate(raw["document"])
            readers, days = raw["readerIds"], raw["reminderLeadDays"]
            if (
                document.ref.coreId != self.scope.coreId
                or document.ref.homeId != self.scope.homeId
                or document.ref.id in documents
                or not isinstance(raw["createdBy"], str)
                or re.fullmatch(r"[0-9a-f]{32}", raw["createdBy"]) is None
                or type(readers) is not list
                or len(readers) > 64
                or readers != sorted(set(readers))
                or any(
                    re.fullmatch(r"[0-9a-f]{32}", item or "") is None
                    for item in readers
                )
                or type(days) is not list
                or days != sorted(set(days), reverse=True)
                or any(type(day) is not int or not 0 <= day <= 365 for day in days)
                or type(raw["libraryRevision"]) is not int
                or not 1 <= raw["libraryRevision"] <= value["revision"]
                or document.revision > raw["libraryRevision"]
            ):
                raise ValueError("invalid_home_document_record")
            documents[document.ref.id] = _Record(
                document=document,
                created_by=raw["createdBy"],
                readers=frozenset(readers),
                reminder_days=tuple(days),
                library_revision=raw["libraryRevision"],
            )
        receipts = {}
        for raw in value["receipts"]:
            if type(raw) is not dict or set(raw) != {
                "familyId",
                "requestId",
                "fingerprint",
                "result",
            }:
                raise ValueError("invalid_home_document_receipt")
            result = DocumentCommandResult.model_validate(raw["result"])
            key = (raw["familyId"], raw["requestId"])
            if (
                key in receipts
                or any(
                    re.fullmatch(r"[0-9a-f]{32}", item or "") is None for item in key
                )
                or re.fullmatch(r"[0-9a-f]{64}", raw["fingerprint"] or "") is None
                or result.replayed
                or result.authority.coreId != self.scope.coreId
                or result.authority.homeId != self.scope.homeId
                or result.authority.sessionFamilyId != raw["familyId"]
                or result.authority.libraryRevision > value["revision"]
            ):
                raise ValueError("invalid_home_document_receipt")
            receipts[key] = (raw["fingerprint"], result)
        self._revision = value["revision"]
        self._documents = documents
        self._receipts = receipts

    @staticmethod
    def _fingerprint(command):
        payload = json.dumps(
            command.model_dump(mode="json"),
            ensure_ascii=True,
            allow_nan=False,
            separators=(",", ":"),
            sort_keys=True,
        ).encode("ascii")
        return hashlib.sha256(payload).hexdigest()

    def _authority(self, actor, *, projected=False):
        revision = self._revision
        if projected and actor.role != "admin":
            revision = max(
                (
                    record.library_revision
                    for record in self._documents.values()
                    if self._visible(actor, record)
                ),
                default=0,
            )
        return DocumentAuthority(
            **self.scope.model_dump(),
            accountId=actor.accountId,
            sessionFamilyId=actor.sessionFamilyId,
            accountRevision=actor.accountRevision,
            libraryRevision=revision,
        )

    def _base(self, actor, command, fingerprint):
        if (command.coreId, command.homeId) != (
            self.scope.coreId,
            self.scope.homeId,
        ):
            raise ApiError("not_found", 404)
        if command.expectedAccountRevision != actor.accountRevision:
            raise ApiError("revision_conflict", 409)
        key = (actor.sessionFamilyId, command.requestId)
        prior = self._receipts.get(key)
        if prior is not None:
            if prior[0] != fingerprint:
                raise ApiError("idempotency_conflict", 409)
            return key, prior[1].model_copy(update={"replayed": True})
        if command.expectedRevision != self._revision:
            raise ApiError("revision_conflict", 409)
        if actor.role != "admin":
            raise ApiError("forbidden", 403)
        if len(self._receipts) >= MAX_RECEIPTS:
            raise ApiError("revision_conflict", 409)
        return key, None

    def _references(self, actor, command):
        try:
            blob = self._blob_current(actor, command.blob)
            inventory = self._inventory_current(actor, command.inventoryItemId)
            valid = blob is True and inventory is True
        except Exception:  # noqa: BLE001 -- reference providers fail closed.
            valid = False
        if not valid:
            raise ApiError("not_found", 404)

    def _result(self, actor, document, replayed=False):
        return DocumentCommandResult(
            authority=self._authority(actor),
            document=document,
            replayed=replayed,
        )

    @_synchronized
    def create(self, actor, value):
        actor = DocumentActor.model_validate(actor)
        command = CreateHomeDocumentCommand.model_validate(value)
        fingerprint = self._fingerprint(command)
        key, replay = self._base(actor, command, fingerprint)
        if replay is not None:
            return replay
        if command.documentId in self._documents:
            raise ApiError("revision_conflict", 409)
        if len(self._documents) >= MAX_DOCUMENTS:
            raise ApiError("revision_conflict", 409)
        self._references(actor, command)
        timestamp = self._clock()
        if type(timestamp) not in (int, float) or not math.isfinite(timestamp) or timestamp < 0:
            raise ApiError("server_unavailable", 503)
        document = HomeDocument(
            schemaVersion=1,
            ref=HomeDocumentRef(
                **self.scope.model_dump(), kind="home_document", id=command.documentId
            ),
            revision=1,
            title=command.title,
            kind=command.kind,
            inventoryItemId=command.inventoryItemId,
            blob=command.blob,
            warranty=WarrantyState(
                candidate=command.ocrCandidate,
                confirmedDate=None,
                confirmedBy=None,
                confirmedAt=None,
                correctedFromOcr=False,
            ),
            createdAt=float(timestamp),
            updatedAt=float(timestamp),
        )
        self._documents[command.documentId] = _Record(
            document=document,
            created_by=actor.accountId,
            readers=frozenset(command.readerIds),
            reminder_days=tuple(sorted(command.reminderLeadDays, reverse=True)),
            library_revision=self._revision + 1,
        )
        self._revision += 1
        result = self._result(actor, document)
        self._receipts[key] = (fingerprint, result)
        return result

    @_synchronized
    def confirm_warranty(self, actor, value):
        actor = DocumentActor.model_validate(actor)
        command = ConfirmWarrantyCommand.model_validate(value)
        fingerprint = self._fingerprint(command)
        key, replay = self._base(actor, command, fingerprint)
        if replay is not None:
            return replay
        record = self._documents.get(command.documentId)
        if record is None:
            raise ApiError("not_found", 404)
        if record.document.revision != command.expectedDocumentRevision:
            raise ApiError("revision_conflict", 409)
        timestamp = self._clock()
        if type(timestamp) not in (int, float) or not math.isfinite(timestamp) or timestamp < 0:
            raise ApiError("server_unavailable", 503)
        candidate = record.document.warranty.candidate
        updated = HomeDocument.model_validate(
            {
                **record.document.model_dump(),
                "revision": record.document.revision + 1,
                "warranty": WarrantyState(
                    candidate=candidate,
                    confirmedDate=command.confirmedDate,
                    confirmedBy=actor.accountId,
                    confirmedAt=float(timestamp),
                    correctedFromOcr=(
                        candidate is not None
                        and candidate.extractedDate != command.confirmedDate
                    ),
                ),
                "updatedAt": float(timestamp),
            }
        )
        self._documents[command.documentId] = _Record(
            document=updated,
            created_by=record.created_by,
            readers=record.readers,
            reminder_days=record.reminder_days,
            library_revision=self._revision + 1,
        )
        self._revision += 1
        result = self._result(actor, updated)
        self._receipts[key] = (fingerprint, result)
        return result

    @staticmethod
    def _visible(actor, record):
        return (
            actor.role == "admin"
            or actor.accountId == record.created_by
            or actor.accountId in record.readers
        )

    @_synchronized
    def search(self, actor, query, *, limit=50):
        actor = DocumentActor.model_validate(actor)
        if (
            type(query) is not str
            or query != query.strip()
            or len(query) > 120
            or any(ord(char) < 32 or ord(char) == 127 for char in query)
            or type(limit) is not int
            or not 1 <= limit <= 50
        ):
            raise ApiError("invalid_request")
        needle = query.casefold()
        items = [
            record.document
            for record in self._documents.values()
            if self._visible(actor, record)
            and (not needle or needle in record.document.title.casefold())
        ]
        items.sort(key=lambda item: (item.title.casefold(), item.ref.id))
        return DocumentPage(
            schemaVersion=1,
            authority=self._authority(actor, projected=True),
            items=items[:limit],
            hasMore=len(items) > limit,
        )

    @_synchronized
    def due(self, actor, *, today):
        actor = DocumentActor.model_validate(actor)
        try:
            current = date.fromisoformat(today)
        except (TypeError, ValueError):
            raise ApiError("invalid_request") from None
        if current.isoformat() != today:
            raise ApiError("invalid_request")
        reminders = []
        for record in self._documents.values():
            confirmed = record.document.warranty.confirmedDate
            if confirmed is None or not self._visible(actor, record):
                continue
            expires = date.fromisoformat(confirmed)
            reached = [
                expires - timedelta(days=days)
                for days in record.reminder_days
                if expires - timedelta(days=days) <= current <= expires
            ]
            if not reached:
                continue
            reminders.append(
                WarrantyReminder(
                    schemaVersion=1,
                    documentId=record.document.ref.id,
                    inventoryItemId=record.document.inventoryItemId,
                    title=record.document.title,
                    remindOn=min(reached).isoformat(),
                    expiresOn=confirmed,
                )
            )
        reminders.sort(key=lambda item: (item.expiresOn, item.documentId))
        return WarrantyReminderPage(
            schemaVersion=1,
            authority=self._authority(actor, projected=True),
            items=reminders[:100],
            hasMore=len(reminders) > 100,
        )
