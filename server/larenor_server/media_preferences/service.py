import hashlib
import hmac
import json
import math
import re
import sqlite3

from ..errors import ApiError, StartupError
from ..home_resources.models import HomeScope
from .models import PutJellyfinTrackPreference


_DIGEST = re.compile(r"^[0-9a-f]{64}$")


class JellyfinTrackPreferenceService:
    """Bounded per-account playback preferences without Jellyfin credentials."""

    def __init__(self, db, auth, settings, key, context):
        self.db, self.auth, self.settings, self._key = db, auth, settings, key
        self.scope = HomeScope.model_validate(context.model_dump())

    def _scope(self, core_id, home_id):
        if (core_id, home_id) != (self.scope.coreId, self.scope.homeId):
            raise ApiError("not_found", 404)

    def _tag(self, row):
        payload = json.dumps(
            [
                self.scope.coreId,
                self.scope.homeId,
                row["owner_id"],
                row["revision"],
                row["audio_language"],
                row["subtitle_language"],
                row["updated_at"],
            ],
            separators=(",", ":"),
            allow_nan=False,
        ).encode("ascii")
        return hmac.new(
            self._key,
            b"larenor-jellyfin-track-preference-v1\0" + payload,
            hashlib.sha256,
        ).hexdigest()

    def _validate(self, row, owner_id=None):
        if row is None:
            return None
        body = PutJellyfinTrackPreference.model_validate(
            {
                "schemaVersion": 1,
                "expectedRevision": 0,
                "audioLanguage": row["audio_language"],
                "subtitleLanguage": row["subtitle_language"],
            }
        )
        if (
            type(row["owner_id"]) is not str
            or owner_id is not None
            and row["owner_id"] != owner_id
            or type(row["revision"]) is not int
            or not 1 <= row["revision"] <= 2**63 - 1
            or type(row["updated_at"]) is not float
            or not math.isfinite(row["updated_at"])
            or type(row["authentication_tag"]) is not str
            or _DIGEST.fullmatch(row["authentication_tag"]) is None
            or not hmac.compare_digest(row["authentication_tag"], self._tag(row))
        ):
            raise ValueError("invalid_jellyfin_preference")
        return body

    def _current_actor(self, connection, actor):
        self.auth.assert_current(connection, actor)
        row = connection.execute(
            "SELECT id,revision,disabled,must_change_password FROM users WHERE id=?",
            (actor.id,),
        ).fetchone()
        if row is None or row["disabled"] or row["must_change_password"]:
            raise ApiError("invalid_session", 401)
        return row

    def _authority(self, actor, user):
        return {
            "schemaVersion": 1,
            **self.scope.model_dump(),
            "accountId": actor.id,
            "accountRevision": user["revision"],
            "sessionFamilyId": actor.family_id,
        }

    def _public(self, actor, user, row):
        preference = None
        if row is not None:
            preference = {
                "schemaVersion": 1,
                "ref": {
                    **self.scope.model_dump(),
                    "accountId": actor.id,
                    "kind": "jellyfin_track_preferences",
                },
                "revision": row["revision"],
                "audioLanguage": row["audio_language"],
                "subtitleLanguage": row["subtitle_language"],
            }
        return {
            "schemaVersion": 1,
            "authority": self._authority(actor, user),
            "preference": preference,
        }

    def read(self, actor, core_id, home_id):
        self._scope(core_id, home_id)
        self.auth.rate_limit([("jellyfin_preference_read", actor.id, 240)])
        try:
            with self.db.connection() as connection:
                user = self._current_actor(connection, actor)
                row = connection.execute(
                    "SELECT * FROM jellyfin_track_preferences WHERE owner_id=?",
                    (actor.id,),
                ).fetchone()
                self._validate(row, actor.id)
                return self._public(actor, user, row)
        except (ValueError, TypeError, sqlite3.Error, OverflowError):
            raise ApiError("media_preference_storage_unavailable", 503) from None

    def put(self, actor, core_id, home_id, value):
        body = PutJellyfinTrackPreference.model_validate(value)
        self._scope(core_id, home_id)
        self.auth.rate_limit([("jellyfin_preference_write", actor.id, 120)])
        try:
            with self.db.transaction() as connection:
                user = self._current_actor(connection, actor)
                old = connection.execute(
                    "SELECT * FROM jellyfin_track_preferences WHERE owner_id=?",
                    (actor.id,),
                ).fetchone()
                self._validate(old, actor.id)
                revision = 0 if old is None else old["revision"]
                if revision != body.expectedRevision:
                    raise ApiError("revision_conflict", 409)
                if revision >= 2**63 - 1:
                    raise ApiError("revision_conflict", 409)
                row = {
                    "owner_id": actor.id,
                    "revision": revision + 1,
                    "audio_language": body.audioLanguage,
                    "subtitle_language": body.subtitleLanguage,
                    "updated_at": float(self.settings.clock()),
                }
                row["authentication_tag"] = self._tag(row)
                connection.execute(
                    "INSERT INTO jellyfin_track_preferences VALUES(?,?,?,?,?,?) "
                    "ON CONFLICT(owner_id) DO UPDATE SET "
                    "revision=excluded.revision,audio_language=excluded.audio_language,"
                    "subtitle_language=excluded.subtitle_language,"
                    "updated_at=excluded.updated_at,"
                    "authentication_tag=excluded.authentication_tag",
                    tuple(
                        row[key]
                        for key in (
                            "owner_id",
                            "revision",
                            "audio_language",
                            "subtitle_language",
                            "updated_at",
                            "authentication_tag",
                        )
                    ),
                )
                return self._public(actor, user, row)
        except (ValueError, TypeError, sqlite3.Error, OverflowError):
            raise ApiError("media_preference_storage_unavailable", 503) from None

    def validate_storage(self):
        try:
            with self.db.connection() as connection:
                rows = connection.execute(
                    "SELECT * FROM jellyfin_track_preferences LIMIT 257"
                ).fetchall()
                if len(rows) > 256:
                    raise ValueError("jellyfin_preference_limit")
                for row in rows:
                    self._validate(row)
                    if connection.execute(
                        "SELECT 1 FROM users WHERE id=?", (row["owner_id"],)
                    ).fetchone() is None:
                        raise ValueError("unknown_jellyfin_preference_owner")
        except (ValueError, TypeError, sqlite3.Error, OverflowError):
            raise StartupError("jellyfin_track_preferences_storage_invalid") from None
