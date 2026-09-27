"""Account-scoped AI memory with expiry, tombstones and verified replay."""

import hashlib
import hmac
import json
import re
import uuid

from ..errors import ApiError, StartupError


MAX_RECORDS = 1024
MAX_TOMBSTONES = 2048
MAX_MUTATIONS = 4096
MAX_INDEX_TOKENS = 48
MAX_CACHE_ENTRIES = 128
_WORDS = re.compile(r"[\w'-]+", re.UNICODE)


class AiMemoryService:
    """Durable memory that always exposes why, by whom and until when it exists."""

    def __init__(self, db, auth, settings, key, context):
        self.db, self.auth, self.settings, self.context = db, auth, settings, context
        self._key = hmac.new(key, b"larenor-ai-memory-v1", hashlib.sha256).digest()

    def _scope(self, core_id, home_id):
        if (core_id, home_id) != (self.context.coreId, self.context.homeId):
            raise ApiError("not_found", 404)

    @staticmethod
    def _json(value):
        return json.dumps(
            value,
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=True,
            allow_nan=False,
        )

    def _tag(self, domain, values):
        return hmac.new(
            self._key,
            domain + b"\0" + self._json(values).encode("ascii"),
            hashlib.sha256,
        ).hexdigest()

    def _record_tag(self, row):
        return self._tag(
            b"record",
            [
                row[name]
                for name in (
                    "id",
                    "core_id",
                    "home_id",
                    "account_id",
                    "revision",
                    "source_kind",
                    "source_description",
                    "content",
                    "learned_by",
                    "created_at",
                    "updated_at",
                    "expires_at",
                )
            ],
        )

    def _tombstone_tag(self, row):
        return self._tag(
            b"tombstone",
            [
                row[name]
                for name in (
                    "memory_id",
                    "core_id",
                    "home_id",
                    "account_id",
                    "deleted_revision",
                    "deleted_at",
                    "reason",
                )
            ],
        )

    def _index_tag(self, row):
        return self._tag(
            b"index", [row["memory_id"], row["token_hash"], row["position"]]
        )

    def _cache_tag(self, row):
        return self._tag(
            b"cache",
            [
                row["cache_key"],
                row["core_id"],
                row["home_id"],
                row["account_id"],
                row["result_json"],
                row["expires_at"],
            ],
        )

    def _mutation_tag(self, row):
        return self._tag(
            b"mutation",
            [
                row["core_id"],
                row["home_id"],
                row["account_id"],
                row["request_key"],
                row["action"],
                row["request_hash"],
                row["result_json"],
                row["created_at"],
            ],
        )

    @staticmethod
    def _verified(row, expected):
        if row is None or not hmac.compare_digest(row["record_tag"], expected):
            raise StartupError("ai_memory_storage_invalid")
        return row

    def validate_storage(self):
        checks = (
            ("ai_memory_records", self._record_tag),
            ("ai_memory_tombstones", self._tombstone_tag),
            ("ai_memory_index", self._index_tag),
            ("ai_memory_cache", self._cache_tag),
            ("ai_memory_mutations", self._mutation_tag),
        )
        with self.db.connection() as connection:
            for table, signer in checks:
                rows = connection.execute(f"SELECT * FROM {table}").fetchall()
                if any(
                    not hmac.compare_digest(row["record_tag"], signer(row))
                    for row in rows
                ):
                    raise StartupError("ai_memory_storage_invalid")

    def _tokens(self, content):
        seen = set()
        output = []
        for word in _WORDS.findall(content.casefold()):
            token = hmac.new(
                self._key, b"token\0" + word.encode("utf-8"), hashlib.sha256
            ).hexdigest()
            if token not in seen:
                seen.add(token)
                output.append(token)
            if len(output) >= MAX_INDEX_TOKENS:
                break
        return output

    def _index_record(self, connection, row):
        connection.execute("DELETE FROM ai_memory_index WHERE memory_id=?", (row["id"],))
        for position, token in enumerate(self._tokens(row["content"])):
            index_row = {
                "memory_id": row["id"],
                "token_hash": token,
                "position": position,
            }
            connection.execute(
                "INSERT INTO ai_memory_index VALUES(?,?,?,?)",
                (row["id"], token, position, self._index_tag(index_row)),
            )

    def _invalidate_cache(self, connection, actor):
        connection.execute(
            "DELETE FROM ai_memory_cache WHERE core_id=? AND home_id=? AND account_id=?",
            (self.context.coreId, self.context.homeId, actor.id),
        )

    def _put_tombstone(self, connection, actor, memory_id, revision, now, reason):
        old = connection.execute(
            "SELECT * FROM ai_memory_tombstones WHERE memory_id=?", (memory_id,)
        ).fetchone()
        if old is not None:
            self._verified(old, self._tombstone_tag(old))
            if (old["core_id"], old["home_id"], old["account_id"]) != (
                self.context.coreId,
                self.context.homeId,
                actor.id,
            ):
                raise ApiError("not_found", 404)
            if old["deleted_revision"] >= revision:
                return dict(old)
        elif (
            connection.execute("SELECT COUNT(*) AS count FROM ai_memory_tombstones").fetchone()[
                "count"
            ]
            >= MAX_TOMBSTONES
        ):
            # Never discard a deletion marker: doing so could revive an old backup.
            raise ApiError("payload_too_large", 413)
        row = {
            "memory_id": memory_id,
            "core_id": self.context.coreId,
            "home_id": self.context.homeId,
            "account_id": actor.id,
            "deleted_revision": revision,
            "deleted_at": now,
            "reason": reason,
        }
        connection.execute(
            "INSERT INTO ai_memory_tombstones VALUES(?,?,?,?,?,?,?,?) "
            "ON CONFLICT(memory_id) DO UPDATE SET "
            "deleted_revision=excluded.deleted_revision,deleted_at=excluded.deleted_at,"
            "reason=excluded.reason,record_tag=excluded.record_tag",
            (*row.values(), self._tombstone_tag(row)),
        )
        return row

    def _expire(self, connection, actor, now):
        rows = connection.execute(
            "SELECT * FROM ai_memory_records WHERE core_id=? AND home_id=? "
            "AND account_id=? AND expires_at<=? ORDER BY expires_at,id",
            (self.context.coreId, self.context.homeId, actor.id, now),
        ).fetchall()
        for row in rows:
            self._verified(row, self._record_tag(row))
            self._put_tombstone(
                connection, actor, row["id"], row["revision"] + 1, now, "expired"
            )
            connection.execute("DELETE FROM ai_memory_index WHERE memory_id=?", (row["id"],))
            connection.execute("DELETE FROM ai_memory_records WHERE id=?", (row["id"],))
        if rows:
            self._invalidate_cache(connection, actor)
        connection.execute(
            "DELETE FROM ai_memory_cache WHERE expires_at<=?", (now,)
        )

    def _public_record(self, row):
        return {
            "schemaVersion": 1,
            "memoryId": row["id"],
            "revision": row["revision"],
            "content": row["content"],
            "source": {
                "schemaVersion": 1,
                "kind": row["source_kind"],
                "description": row["source_description"],
            },
            "learnedBy": row["learned_by"],
            "createdAt": row["created_at"],
            "updatedAt": row["updated_at"],
            "retention": {
                "durationSeconds": round(row["expires_at"] - row["updated_at"]),
                "expiresAt": row["expires_at"],
                "explanation": "timeBounded",
            },
        }

    def _public_tombstone(self, row):
        return {
            "schemaVersion": 1,
            "memoryId": row["memory_id"],
            "deletedRevision": row["deleted_revision"],
            "deletedAt": row["deleted_at"],
            "reason": row["reason"],
        }

    def _request_hash(self, action, body):
        return self._tag(b"request", [action, body.model_dump(mode="json")])

    def _replay(self, connection, actor, request_key, action, request_hash):
        row = connection.execute(
            "SELECT * FROM ai_memory_mutations WHERE core_id=? AND home_id=? "
            "AND account_id=? AND request_key=?",
            (self.context.coreId, self.context.homeId, actor.id, request_key),
        ).fetchone()
        if row is None:
            return None
        self._verified(row, self._mutation_tag(row))
        if row["action"] != action or not hmac.compare_digest(
            row["request_hash"], request_hash
        ):
            raise ApiError("idempotency_conflict", 409)
        return json.loads(row["result_json"])

    def _save_receipt(self, connection, actor, request_key, action, request_hash, result, now):
        result_json = self._json(result)
        row = {
            "core_id": self.context.coreId,
            "home_id": self.context.homeId,
            "account_id": actor.id,
            "request_key": request_key,
            "action": action,
            "request_hash": request_hash,
            "result_json": result_json,
            "created_at": now,
        }
        connection.execute(
            "INSERT INTO ai_memory_mutations VALUES(?,?,?,?,?,?,?,?,?)",
            (*row.values(), self._mutation_tag(row)),
        )
        connection.execute(
            "DELETE FROM ai_memory_mutations WHERE rowid IN (SELECT rowid FROM "
            "ai_memory_mutations ORDER BY created_at DESC,rowid DESC LIMIT -1 OFFSET ?)",
            (MAX_MUTATIONS,),
        )

    def snapshot(self, actor, core_id, home_id):
        self._scope(core_id, home_id)
        now = float(self.settings.clock())
        with self.db.transaction() as connection:
            self.auth.assert_current(connection, actor)
            self._expire(connection, actor, now)
            rows = connection.execute(
                "SELECT * FROM ai_memory_records WHERE core_id=? AND home_id=? "
                "AND account_id=? AND expires_at>? ORDER BY updated_at DESC,id",
                (self.context.coreId, self.context.homeId, actor.id, now),
            ).fetchall()
            for row in rows:
                self._verified(row, self._record_tag(row))
        return {
            "schemaVersion": 1,
            "scope": {
                "schemaVersion": 1,
                "coreId": self.context.coreId,
                "homeId": self.context.homeId,
                "accountId": actor.id,
            },
            "memories": [self._public_record(row) for row in rows],
        }

    def remember(self, actor, core_id, home_id, body):
        self._scope(core_id, home_id)
        now = float(self.settings.clock())
        request_hash = self._request_hash("remember", body)
        with self.db.transaction() as connection:
            self.auth.assert_current(connection, actor)
            self._expire(connection, actor, now)
            replay = self._replay(
                connection, actor, body.requestKey, "remember", request_hash
            )
            if replay is not None:
                return replay
            count = connection.execute(
                "SELECT COUNT(*) AS count FROM ai_memory_records WHERE core_id=? "
                "AND home_id=? AND account_id=?",
                (self.context.coreId, self.context.homeId, actor.id),
            ).fetchone()["count"]
            if count >= MAX_RECORDS:
                raise ApiError("payload_too_large", 413)
            row = {
                "id": uuid.uuid4().hex,
                "core_id": self.context.coreId,
                "home_id": self.context.homeId,
                "account_id": actor.id,
                "revision": 1,
                "source_kind": body.source.kind,
                "source_description": body.source.description,
                "content": body.content,
                "learned_by": actor.username,
                "created_at": now,
                "updated_at": now,
                "expires_at": now + body.durationSeconds,
            }
            connection.execute(
                "INSERT INTO ai_memory_records VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (*row.values(), self._record_tag(row)),
            )
            self._index_record(connection, row)
            self._invalidate_cache(connection, actor)
            result = {"memory": self._public_record(row)}
            self._save_receipt(
                connection,
                actor,
                body.requestKey,
                "remember",
                request_hash,
                result,
                now,
            )
            return result

    def correct(self, actor, core_id, home_id, memory_id, body):
        self._scope(core_id, home_id)
        now = float(self.settings.clock())
        request_hash = self._tag(
            b"request", ["correct", memory_id, body.model_dump(mode="json")]
        )
        with self.db.transaction() as connection:
            self.auth.assert_current(connection, actor)
            self._expire(connection, actor, now)
            replay = self._replay(
                connection, actor, body.requestKey, "correct", request_hash
            )
            if replay is not None:
                return replay
            old = connection.execute(
                "SELECT * FROM ai_memory_records WHERE id=? AND core_id=? AND home_id=? "
                "AND account_id=?",
                (memory_id, self.context.coreId, self.context.homeId, actor.id),
            ).fetchone()
            if old is None:
                raise ApiError("not_found", 404)
            self._verified(old, self._record_tag(old))
            if old["revision"] != body.expectedRevision:
                raise ApiError("revision_conflict", 409)
            row = dict(old)
            row.update(
                revision=old["revision"] + 1,
                source_kind=body.source.kind,
                source_description=body.source.description,
                content=body.content,
                learned_by=actor.username,
                updated_at=now,
                expires_at=now + body.durationSeconds,
            )
            connection.execute(
                "UPDATE ai_memory_records SET revision=?,source_kind=?,"
                "source_description=?,content=?,learned_by=?,updated_at=?,expires_at=?,"
                "record_tag=? WHERE id=?",
                (
                    row["revision"],
                    row["source_kind"],
                    row["source_description"],
                    row["content"],
                    row["learned_by"],
                    now,
                    row["expires_at"],
                    self._record_tag(row),
                    memory_id,
                ),
            )
            self._index_record(connection, row)
            self._invalidate_cache(connection, actor)
            result = {"memory": self._public_record(row)}
            self._save_receipt(
                connection,
                actor,
                body.requestKey,
                "correct",
                request_hash,
                result,
                now,
            )
            return result

    def forget(self, actor, core_id, home_id, memory_id, body):
        self._scope(core_id, home_id)
        now = float(self.settings.clock())
        request_hash = self._tag(
            b"request", ["forget", memory_id, body.model_dump(mode="json")]
        )
        with self.db.transaction() as connection:
            self.auth.assert_current(connection, actor)
            self._expire(connection, actor, now)
            replay = self._replay(
                connection, actor, body.requestKey, "forget", request_hash
            )
            if replay is not None:
                return replay
            old = connection.execute(
                "SELECT * FROM ai_memory_records WHERE id=? AND core_id=? AND home_id=? "
                "AND account_id=?",
                (memory_id, self.context.coreId, self.context.homeId, actor.id),
            ).fetchone()
            if old is None:
                raise ApiError("not_found", 404)
            self._verified(old, self._record_tag(old))
            if old["revision"] != body.expectedRevision:
                raise ApiError("revision_conflict", 409)
            tombstone = self._put_tombstone(
                connection,
                actor,
                memory_id,
                old["revision"] + 1,
                now,
                body.reason,
            )
            # Explicit cleanup avoids deleted content surviving in derived stores.
            connection.execute("DELETE FROM ai_memory_index WHERE memory_id=?", (memory_id,))
            connection.execute("DELETE FROM ai_memory_records WHERE id=?", (memory_id,))
            self._invalidate_cache(connection, actor)
            result = {"tombstone": self._public_tombstone(tombstone)}
            self._save_receipt(
                connection,
                actor,
                body.requestKey,
                "forget",
                request_hash,
                result,
                now,
            )
            return result

    def search(self, actor, core_id, home_id, body):
        self._scope(core_id, home_id)
        now = float(self.settings.clock())
        tokens = self._tokens(body.query)
        cache_key = self._tag(
            b"search", [self.context.coreId, self.context.homeId, actor.id, tokens, body.limit]
        )
        with self.db.transaction() as connection:
            self.auth.assert_current(connection, actor)
            self._expire(connection, actor, now)
            cached = connection.execute(
                "SELECT * FROM ai_memory_cache WHERE cache_key=? AND core_id=? "
                "AND home_id=? AND account_id=? AND expires_at>?",
                (cache_key, self.context.coreId, self.context.homeId, actor.id, now),
            ).fetchone()
            if cached is not None:
                self._verified(cached, self._cache_tag(cached))
                ids = json.loads(cached["result_json"])
            elif not tokens:
                ids = []
            else:
                placeholders = ",".join("?" for _ in tokens)
                rows = connection.execute(
                    "SELECT r.id,COUNT(DISTINCT i.token_hash) AS matches,r.updated_at "
                    "FROM ai_memory_index i JOIN ai_memory_records r ON r.id=i.memory_id "
                    f"WHERE i.token_hash IN ({placeholders}) AND r.core_id=? AND "
                    "r.home_id=? AND r.account_id=? AND r.expires_at>? "
                    "GROUP BY r.id ORDER BY matches DESC,r.updated_at DESC,r.id LIMIT ?",
                    (*tokens, self.context.coreId, self.context.homeId, actor.id, now, body.limit),
                ).fetchall()
                ids = [row["id"] for row in rows]
                packed = self._json(ids)
                cache = {
                    "cache_key": cache_key,
                    "core_id": self.context.coreId,
                    "home_id": self.context.homeId,
                    "account_id": actor.id,
                    "result_json": packed,
                    "expires_at": now + 60,
                }
                connection.execute(
                    "INSERT INTO ai_memory_cache VALUES(?,?,?,?,?,?,?)",
                    (*cache.values(), self._cache_tag(cache)),
                )
                connection.execute(
                    "DELETE FROM ai_memory_cache WHERE rowid IN (SELECT rowid FROM "
                    "ai_memory_cache ORDER BY expires_at DESC,rowid DESC LIMIT -1 OFFSET ?)",
                    (MAX_CACHE_ENTRIES,),
                )
            records = []
            for memory_id in ids:
                row = connection.execute(
                    "SELECT * FROM ai_memory_records WHERE id=? AND core_id=? AND home_id=? "
                    "AND account_id=? AND expires_at>?",
                    (
                        memory_id,
                        self.context.coreId,
                        self.context.homeId,
                        actor.id,
                        now,
                    ),
                ).fetchone()
                if row is not None:
                    self._verified(row, self._record_tag(row))
                    records.append(self._public_record(row))
        return {"schemaVersion": 1, "memories": records}

    def export_backup(self, actor, core_id, home_id):
        self._scope(core_id, home_id)
        now = float(self.settings.clock())
        with self.db.transaction() as connection:
            self.auth.assert_current(connection, actor)
            self._expire(connection, actor, now)
            records = connection.execute(
                "SELECT * FROM ai_memory_records WHERE core_id=? AND home_id=? "
                "AND account_id=? ORDER BY updated_at,id",
                (self.context.coreId, self.context.homeId, actor.id),
            ).fetchall()
            tombstones = connection.execute(
                "SELECT * FROM ai_memory_tombstones WHERE core_id=? AND home_id=? "
                "AND account_id=? ORDER BY deleted_at,memory_id",
                (self.context.coreId, self.context.homeId, actor.id),
            ).fetchall()
            for row in records:
                self._verified(row, self._record_tag(row))
            for row in tombstones:
                self._verified(row, self._tombstone_tag(row))
        return {
            "schemaVersion": 1,
            "records": [
                {
                    "schemaVersion": 1,
                    "memoryId": row["id"],
                    "revision": row["revision"],
                    "source": {
                        "schemaVersion": 1,
                        "kind": row["source_kind"],
                        "description": row["source_description"],
                    },
                    "content": row["content"],
                    "learnedBy": row["learned_by"],
                    "createdAt": row["created_at"],
                    "updatedAt": row["updated_at"],
                    "expiresAt": row["expires_at"],
                }
                for row in records
            ],
            "tombstones": [self._public_tombstone(row) for row in tombstones],
        }

    def restore_backup(self, actor, core_id, home_id, body):
        self._scope(core_id, home_id)
        now = float(self.settings.clock())
        request_hash = self._request_hash("restore", body)
        with self.db.transaction() as connection:
            self.auth.assert_current(connection, actor)
            self._expire(connection, actor, now)
            replay = self._replay(
                connection, actor, body.requestKey, "restore", request_hash
            )
            if replay is not None:
                return replay
            restored = blocked = 0
            for item in sorted(body.tombstones, key=lambda value: value.deletedAt):
                collision = connection.execute(
                    "SELECT * FROM ai_memory_tombstones WHERE memory_id=?", (item.memoryId,)
                ).fetchone()
                if collision is not None and (
                    collision["core_id"], collision["home_id"], collision["account_id"]
                ) != (self.context.coreId, self.context.homeId, actor.id):
                    blocked += 1
                    continue
                self._put_tombstone(
                    connection,
                    actor,
                    item.memoryId,
                    item.deletedRevision,
                    item.deletedAt,
                    item.reason,
                )
                connection.execute(
                    "DELETE FROM ai_memory_index WHERE memory_id=?", (item.memoryId,)
                )
                connection.execute(
                    "DELETE FROM ai_memory_records WHERE id=? AND core_id=? AND home_id=? "
                    "AND account_id=?",
                    (item.memoryId, self.context.coreId, self.context.homeId, actor.id),
                )
            active_count = connection.execute(
                "SELECT COUNT(*) AS count FROM ai_memory_records WHERE core_id=? "
                "AND home_id=? AND account_id=?",
                (self.context.coreId, self.context.homeId, actor.id),
            ).fetchone()["count"]
            for item in sorted(body.records, key=lambda value: (value.updatedAt, value.memoryId)):
                deleted = connection.execute(
                    "SELECT * FROM ai_memory_tombstones WHERE memory_id=? AND core_id=? "
                    "AND home_id=? AND account_id=?",
                    (item.memoryId, self.context.coreId, self.context.homeId, actor.id),
                ).fetchone()
                if deleted is not None:
                    self._verified(deleted, self._tombstone_tag(deleted))
                    blocked += 1
                    continue
                collision = connection.execute(
                    "SELECT * FROM ai_memory_records WHERE id=?", (item.memoryId,)
                ).fetchone()
                if collision is not None and (
                    collision["core_id"], collision["home_id"], collision["account_id"]
                ) != (self.context.coreId, self.context.homeId, actor.id):
                    blocked += 1
                    continue
                if item.expiresAt <= now:
                    self._put_tombstone(
                        connection,
                        actor,
                        item.memoryId,
                        item.revision + 1,
                        now,
                        "expired",
                    )
                    blocked += 1
                    continue
                if collision is not None:
                    self._verified(collision, self._record_tag(collision))
                    if collision["revision"] >= item.revision:
                        blocked += 1
                        continue
                elif active_count >= MAX_RECORDS:
                    blocked += 1
                    continue
                row = {
                    "id": item.memoryId,
                    "core_id": self.context.coreId,
                    "home_id": self.context.homeId,
                    "account_id": actor.id,
                    "revision": item.revision,
                    "source_kind": item.source.kind,
                    "source_description": item.source.description,
                    "content": item.content,
                    "learned_by": item.learnedBy,
                    "created_at": item.createdAt,
                    "updated_at": item.updatedAt,
                    "expires_at": item.expiresAt,
                }
                connection.execute(
                    "INSERT INTO ai_memory_records VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?) "
                    "ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,"
                    "source_kind=excluded.source_kind,source_description=excluded.source_description,"
                    "content=excluded.content,learned_by=excluded.learned_by,"
                    "created_at=excluded.created_at,updated_at=excluded.updated_at,"
                    "expires_at=excluded.expires_at,record_tag=excluded.record_tag",
                    (*row.values(), self._record_tag(row)),
                )
                self._index_record(connection, row)
                active_count += collision is None
                restored += 1
            self._invalidate_cache(connection, actor)
            result = {
                "schemaVersion": 1,
                "restoredCount": restored,
                "blockedCount": blocked,
            }
            self._save_receipt(
                connection,
                actor,
                body.requestKey,
                "restore",
                request_hash,
                result,
                now,
            )
            return result
