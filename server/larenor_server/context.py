"""One persistent Core and home identity; no resource or multi-home authority."""

import hashlib
import hmac
import re
import secrets
import sqlite3
from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator

from .errors import StartupError


Identity = Annotated[str, Field(min_length=32, max_length=32, pattern=r"^[0-9a-f]{32}$")]


class ContextResponse(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True, frozen=True)

    schemaVersion: Literal[1]
    coreId: Identity
    homeId: Identity

    @field_validator("schemaVersion", mode="before")
    @classmethod
    def integer_schema_version(cls, value):
        # Literal equality alone also accepts True and 1.0; the wire type is int.
        if type(value) is not int:
            raise ValueError("invalid_context_schema")
        return value


def _authentication_tag(key: bytes, core_id: str, home_id: str) -> str:
    # Bind both identities and their schema together under the existing vault key.
    payload = b"larenor-core-context\0db3\0schema1\0" + core_id.encode("ascii") + b"\0" + home_id.encode("ascii")
    return hmac.new(key, payload, hashlib.sha256).hexdigest()


def migrate_context(connection: sqlite3.Connection, key: bytes) -> ContextResponse:
    """Called after key validation, inside the existing initialization transaction.

    The main DB marker distinguishes a legacy DB from a damaged current DB even
    when the entire identity table is missing. Never recover by generating IDs.
    """
    try:
        marker = connection.execute("SELECT value FROM metadata WHERE key='schema_version'").fetchone()
        objects = connection.execute("SELECT type FROM sqlite_master WHERE name='core_context'").fetchall()
        if marker is not None and marker["value"] == "2":
            if objects:
                raise StartupError("invalid_core_context")
            connection.execute("""CREATE TABLE core_context (
                singleton INTEGER PRIMARY KEY CHECK(singleton=1),
                schema_version INTEGER NOT NULL CHECK(schema_version=1),
                core_id TEXT NOT NULL,
                home_id TEXT NOT NULL,
                authentication_tag TEXT NOT NULL
            )""")
            core_id, home_id = secrets.token_hex(16), secrets.token_hex(16)
            connection.execute("INSERT INTO core_context VALUES(1,1,?,?,?)",
                               (core_id, home_id, _authentication_tag(key, core_id, home_id)))
            connection.execute("UPDATE metadata SET value='3' WHERE key='schema_version'")
        elif (marker is None or marker["value"] != "3" or
              len(objects) != 1 or objects[0]["type"] != "table"):
            raise StartupError("invalid_core_context")

        rows = connection.execute("""SELECT singleton,schema_version,core_id,home_id,authentication_tag
                                     FROM core_context LIMIT 2""").fetchall()
        if (len(rows) != 1 or type(rows[0]["singleton"]) is not int or rows[0]["singleton"] != 1 or
                type(rows[0]["schema_version"]) is not int or rows[0]["schema_version"] != 1):
            raise StartupError("invalid_core_context")
        row = rows[0]
        response = ContextResponse(schemaVersion=1, coreId=row["core_id"], homeId=row["home_id"])
        tag = row["authentication_tag"]
        if (not isinstance(tag, str) or not re.fullmatch(r"[0-9a-f]{64}", tag) or
                not hmac.compare_digest(tag, _authentication_tag(key, response.coreId, response.homeId))):
            raise StartupError("invalid_core_context")
        return response
    except (sqlite3.Error, ValueError, TypeError):
        raise StartupError("invalid_core_context") from None
