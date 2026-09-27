"""Additive, closed SQLite schema for the bounded rule arbiter journal."""

import hashlib
import hmac
import json
import sqlite3

from ..errors import StartupError


MAX_DECISIONS = 2_048
MAX_DEVICES = 512
MAX_OBSERVATIONS = 4_096

TABLES = {
    "rule_arbiter_decisions": """CREATE TABLE rule_arbiter_decisions (
        id TEXT PRIMARY KEY, owner_id TEXT NOT NULL, family_id TEXT NOT NULL,
        request_key TEXT NOT NULL, request_hash TEXT NOT NULL,
        device_id TEXT NOT NULL, expected_device_revision INTEGER NOT NULL CHECK(expected_device_revision > 0),
        source TEXT NOT NULL CHECK(source IN ('rule','manual')),
        rule_id TEXT, rule_revision INTEGER, priority INTEGER NOT NULL CHECK(priority BETWEEN 0 AND 101),
        action TEXT NOT NULL, revision INTEGER NOT NULL CHECK(revision > 0),
        state TEXT NOT NULL CHECK(state IN ('authorized','suppressed','superseded','applied','rejected','unknown')),
        reason TEXT NOT NULL CHECK(reason IN ('winner','active_manual','lower_priority','equal_priority','adapter_applied','adapter_rejected','adapter_unknown','replaced')),
        created_at REAL NOT NULL, expires_at REAL NOT NULL, completed_at REAL,
        readback_device_revision INTEGER, envelope_tag TEXT NOT NULL,
        UNIQUE(owner_id,family_id,request_key),
        CHECK((source='rule' AND rule_id IS NOT NULL AND rule_revision IS NOT NULL AND priority <= 100)
           OR (source='manual' AND rule_id IS NULL AND rule_revision IS NULL AND priority=101)))""",
    "rule_arbiter_ownership": """CREATE TABLE rule_arbiter_ownership (
        device_id TEXT PRIMARY KEY, revision INTEGER NOT NULL CHECK(revision > 0),
        decision_id TEXT NOT NULL UNIQUE, source TEXT NOT NULL CHECK(source IN ('rule','manual')),
        rule_id TEXT, owner_id TEXT NOT NULL, priority INTEGER NOT NULL CHECK(priority BETWEEN 0 AND 101),
        action TEXT NOT NULL, expires_at REAL NOT NULL, envelope_tag TEXT NOT NULL,
        FOREIGN KEY(decision_id) REFERENCES rule_arbiter_decisions(id) ON DELETE RESTRICT)""",
    "rule_arbiter_observations": """CREATE TABLE rule_arbiter_observations (
        id TEXT PRIMARY KEY, reporter_id TEXT NOT NULL, family_id TEXT NOT NULL,
        device_id TEXT NOT NULL, provider_revision INTEGER NOT NULL CHECK(provider_revision > 0),
        action TEXT NOT NULL, observed_at REAL NOT NULL, recorded_at REAL NOT NULL,
        matches_decision INTEGER NOT NULL CHECK(matches_decision IN (0,1)),
        control_mode TEXT NOT NULL CHECK(control_mode='observed_only'), envelope_tag TEXT NOT NULL)""",
    "rule_arbiter_state": """CREATE TABLE rule_arbiter_state (
        singleton INTEGER PRIMARY KEY CHECK(singleton=1),
        decision_count INTEGER NOT NULL CHECK(decision_count BETWEEN 0 AND 2048),
        ownership_count INTEGER NOT NULL CHECK(ownership_count BETWEEN 0 AND 512),
        observation_count INTEGER NOT NULL CHECK(observation_count BETWEEN 0 AND 4096),
        inventory_tag TEXT NOT NULL)""",
}


def _empty_inventory_tag(key, context):
    scoped_key = hmac.new(
        key,
        b"larenor-rule-arbitration-v1\0"
        + context.coreId.encode("ascii")
        + b"\0"
        + context.homeId.encode("ascii"),
        hashlib.sha256,
    ).digest()
    payload = json.dumps(
        [[], [], []], ensure_ascii=True, allow_nan=False,
        separators=(",", ":"), sort_keys=True,
    ).encode("ascii")
    return hmac.new(
        scoped_key, b"inventory\0" + payload, hashlib.sha256
    ).hexdigest()


def migrate_rule_arbitration(connection: sqlite3.Connection, key, context) -> None:
    try:
        marker = connection.execute(
            "SELECT value FROM metadata WHERE key='rule_arbiter_schema'"
        ).fetchone()
        rows = connection.execute(
            "SELECT name,type,sql FROM sqlite_master WHERE name GLOB 'rule_arbiter_*'"
        ).fetchall()
        actual = {row["name"]: row for row in rows if row["sql"] is not None}
        if marker is None:
            if actual:
                raise ValueError("unmarked_rule_arbiter_storage")
            for statement in TABLES.values():
                connection.execute(statement)
            connection.execute(
                "INSERT INTO rule_arbiter_state VALUES(1,0,0,0,?)",
                (_empty_inventory_tag(key, context),),
            )
            connection.execute(
                "INSERT INTO metadata VALUES('rule_arbiter_schema','1')"
            )
            return
        if (
            marker["value"] != "1"
            or set(actual) != set(TABLES)
            or any(
                row["type"] != "table"
                or " ".join(row["sql"].split()) != " ".join(TABLES[name].split())
                for name, row in actual.items()
            )
        ):
            raise ValueError("invalid_rule_arbiter_storage")
    except (sqlite3.Error, TypeError, ValueError):
        raise StartupError("rule_arbiter_storage_invalid") from None
