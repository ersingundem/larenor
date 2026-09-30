"""Evidence-only fault analysis; this module never performs a repair."""

import hashlib
import hmac
import json
import uuid

from ..errors import ApiError, StartupError


MAX_DIAGNOSES = 512
MAX_REPAIR_PREVIEWS = 256
MAX_SOURCE_AGE_MS = 5 * 60 * 1000
MAX_FUTURE_SKEW_MS = 30 * 1000
REPAIR_PREVIEW_LIFETIME_MS = 5 * 60 * 1000
MAX_RESULT_BYTES = 256 * 1024


def _canonical(value) -> bytes:
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=True, allow_nan=False
    ).encode("ascii")


class EvidenceDiagnosticService:
    """Persist deterministic diagnoses and authorization-bound repair previews."""

    def __init__(self, db, auth, settings, key, context, history_observer=None):
        if not isinstance(key, bytes) or len(key) < 32:
            raise ValueError("invalid_diagnostic_key")
        self.db, self.auth, self.settings, self.context = db, auth, settings, context
        self._key = hmac.new(
            key, b"larenor-evidence-diagnostic-v1", hashlib.sha256
        ).digest()
        self._history_observer = history_observer

    def _scope(self, core_id, home_id):
        if (core_id, home_id) != (self.context.coreId, self.context.homeId):
            raise ApiError("not_found", 404)

    def _tag(self, domain, values):
        return hmac.new(
            self._key, domain + b"\0" + _canonical(values), hashlib.sha256
        ).hexdigest()

    def _diagnosis_tag(self, row):
        return self._tag(b"diagnosis", [row[name] for name in (
            "id", "owner_id", "family_id", "request_key", "revision",
            "request_fingerprint", "created_at_ms", "result_json",
        )])

    def _preview_tag(self, row):
        return self._tag(b"repair-preview", [row[name] for name in (
            "id", "diagnosis_id", "owner_id", "family_id", "request_key",
            "diagnosis_revision", "request_fingerprint", "created_at_ms",
            "expires_at_ms", "preview_json",
        )])

    def _verified_diagnosis(self, row):
        if row is None:
            raise ApiError("not_found", 404)
        try:
            if (
                len(row["result_json"].encode("utf-8")) > MAX_RESULT_BYTES
                or not hmac.compare_digest(row["record_tag"], self._diagnosis_tag(row))
            ):
                raise ValueError()
            value = json.loads(row["result_json"])
            if not isinstance(value, dict) or value.get("id") != row["id"]:
                raise ValueError()
            return value
        except (KeyError, TypeError, ValueError, json.JSONDecodeError):
            raise StartupError("evidence_diagnostic_storage_invalid") from None

    def _verified_preview(self, row):
        try:
            if (
                len(row["preview_json"].encode("utf-8")) > MAX_RESULT_BYTES
                or not hmac.compare_digest(row["record_tag"], self._preview_tag(row))
            ):
                raise ValueError()
            value = json.loads(row["preview_json"])
            if not isinstance(value, dict) or value.get("id") != row["id"]:
                raise ValueError()
            return value
        except (KeyError, TypeError, ValueError, json.JSONDecodeError):
            raise StartupError("evidence_diagnostic_storage_invalid") from None

    def validate_storage(self):
        with self.db.connection() as connection:
            diagnoses = connection.execute(
                "SELECT * FROM evidence_diagnostics ORDER BY created_at_ms,id LIMIT ?",
                (MAX_DIAGNOSES + 1,),
            ).fetchall()
            previews = connection.execute(
                "SELECT * FROM evidence_diagnostic_repair_previews "
                "ORDER BY created_at_ms,id LIMIT ?", (MAX_REPAIR_PREVIEWS + 1,)
            ).fetchall()
            if len(diagnoses) > MAX_DIAGNOSES or len(previews) > MAX_REPAIR_PREVIEWS:
                raise StartupError("evidence_diagnostic_storage_invalid")
            for row in diagnoses:
                self._verified_diagnosis(row)
            for row in previews:
                self._verified_preview(row)

    def _normalize_sources(self, sources, *, provenance="synthetic", evidence=None):
        normalized = []
        redactions = []
        for source in sorted(sources, key=lambda item: item.sourceId):
            if source.detail is not None:
                redactions.append({
                    "sourceId": source.sourceId,
                    "field": "detail",
                    "replacement": "[redacted]",
                })
            normalized.append({
                "sourceId": source.sourceId,
                "sourceType": source.sourceType,
                "revision": source.revision,
                "capturedAtMs": source.capturedAtMs,
                "state": source.state,
                "detailRedacted": source.detail is not None,
                "measurements": [item.model_dump(mode="json") for item in source.measurements],
                "events": [item.model_dump(mode="json") for item in source.events],
                "provenance": provenance,
                "evidence": evidence,
            })
        return normalized, redactions

    @staticmethod
    def _require_fresh_sources(sources, now_ms):
        for source in sources:
            if (
                source["capturedAtMs"] > now_ms + MAX_FUTURE_SKEW_MS
                or now_ms - source["capturedAtMs"] > MAX_SOURCE_AGE_MS
                or any(
                    now_ms - event["occurredAtMs"] > MAX_SOURCE_AGE_MS
                    for event in source["events"]
                )
            ):
                raise ApiError("diagnostic_source_stale", 409)

    def _analyze(self, sources):
        findings, unknowns = [], []
        for source in sources:
            source_ref = {"sourceId": source["sourceId"], "sourceRevision": source["revision"]}
            if source["provenance"] == "synthetic":
                unknowns.append({
                    "code": "synthetic_source_unverified",
                    "evidenceRefs": [source_ref],
                })
            if source["state"] in {"attention", "degraded", "critical", "unavailable"}:
                findings.append({
                    "findingId": f"source:{source['sourceId']}",
                    "code": f"source_{source['state']}",
                    "severity": (
                        "critical" if source["state"] in {"critical", "unavailable"}
                        else "warning"
                    ),
                    "evidenceRefs": [source_ref],
                })
            if source["state"] in {"unknown", "unavailable"}:
                unknowns.append({
                    "code": "source_state_unknown",
                    "evidenceRefs": [source_ref],
                })
            thresholdable = False
            for measurement in source["measurements"]:
                if measurement["threshold"] is None:
                    continue
                thresholdable = True
                if self._threshold_breached_object(measurement):
                    findings.append({
                        "findingId": (
                            f"measurement:{source['sourceId']}:"
                            f"{measurement['measurementId']}"
                        ),
                        "code": "measurement_threshold_breached",
                        "severity": "warning",
                        "evidenceRefs": [{
                            **source_ref,
                            "measurementId": measurement["measurementId"],
                        }],
                    })
            if source["sourceType"] == "measurement" and not thresholdable:
                unknowns.append({
                    "code": "measurement_threshold_missing",
                    "evidenceRefs": [source_ref],
                })
            for event in source["events"]:
                if event["severity"] in {"warning", "critical"}:
                    findings.append({
                        "findingId": f"event:{source['sourceId']}:{event['eventId']}",
                        "code": "critical_event_observed" if event["severity"] == "critical"
                                else "warning_event_observed",
                        "severity": event["severity"],
                        "evidenceRefs": [{**source_ref, "eventId": event["eventId"]}],
                    })
                elif event["severity"] == "unknown":
                    unknowns.append({
                        "code": "event_severity_unknown",
                        "evidenceRefs": [{**source_ref, "eventId": event["eventId"]}],
                    })
        findings.sort(key=lambda item: (
            0 if item["severity"] == "critical" else 1, item["findingId"]
        ))
        unknowns.sort(key=lambda item: (item["code"], _canonical(item["evidenceRefs"])))
        return findings[:128], unknowns[:128]

    @staticmethod
    def _threshold_breached_object(measurement):
        value, threshold = measurement["value"], measurement["threshold"]
        return {
            "above": value > threshold,
            "at_or_above": value >= threshold,
            "below": value < threshold,
            "at_or_below": value <= threshold,
        }[measurement["comparator"]]

    @staticmethod
    def _recommendations(findings, unknowns):
        recommendations = []
        if findings:
            recommendations.append({
                "code": "inspect_referenced_source",
                "readOnly": True,
                "applied": False,
                "findingIds": [item["findingId"] for item in findings[:32]],
            })
        if any(item["code"] == "measurement_threshold_breached" for item in findings):
            recommendations.append({
                "code": "compare_measurement_history",
                "readOnly": True,
                "applied": False,
                "findingIds": [
                    item["findingId"] for item in findings
                    if item["code"] == "measurement_threshold_breached"
                ][:32],
            })
        if unknowns:
            recommendations.append({
                "code": "collect_fresh_evidence",
                "readOnly": True,
                "applied": False,
                "findingIds": [],
            })
        return recommendations

    def diagnose(self, actor, core_id, home_id, body):
        self._scope(core_id, home_id)
        sources, redactions = self._normalize_sources(
            body.sources, provenance="synthetic", evidence=None
        )
        return self._diagnose_normalized(
            actor, body.requestKey, sources, redactions
        )

    def diagnose_home_assistant_history(self, actor, core_id, home_id, body):
        self._scope(core_id, home_id)
        if self._history_observer is None:
            raise ApiError("server_unavailable", 503)
        observer = self._history_observer()
        observation = observer.observe(actor, body.sourceResourceId)
        latest_state = observation.states[-1][1]
        state = latest_state if latest_state in {"unavailable", "unknown"} else "unknown"
        sources = [{
            "sourceId": "ha-resource:" + observation.resource_id,
            "sourceType": "health",
            "revision": observation.resource_revision,
            "capturedAtMs": observation.captured_at_ms,
            "state": state,
            "detailRedacted": False,
            "measurements": [],
            "events": [],
            "provenance": "home_assistant_history",
            "evidence": observation.evidence(),
        }]
        return self._diagnose_normalized(
            actor, body.requestKey, sources, [],
            authority_guard=lambda connection: observer.assert_current_in(
                connection, actor, observation
            ),
        )

    def _diagnose_normalized(
        self, actor, request_key, sources, redactions, authority_guard=None,
    ):
        now_ms = round(float(self.settings.clock()) * 1000)
        request = {"schemaVersion": 1, "sources": sources}
        fingerprint = hashlib.sha256(_canonical(request)).hexdigest()
        with self.db.transaction() as connection:
            self.auth.assert_current(connection, actor)
            if authority_guard is not None:
                authority_guard(connection)
            old = connection.execute(
                "SELECT * FROM evidence_diagnostics "
                "WHERE owner_id=? AND family_id=? AND request_key=?",
                (actor.id, actor.family_id, request_key),
            ).fetchone()
            if old is not None:
                result = self._verified_diagnosis(old)
                if not hmac.compare_digest(old["request_fingerprint"], fingerprint):
                    raise ApiError("diagnostic_request_conflict", 409)
                return {"diagnosis": result}
            self._require_fresh_sources(sources, now_ms)
            count = connection.execute(
                "SELECT COUNT(*) AS count FROM evidence_diagnostics"
            ).fetchone()["count"]
            if count >= MAX_DIAGNOSES:
                raise ApiError("diagnostic_limit_reached", 413)
            findings, unknowns = self._analyze(sources)
            recommendations = self._recommendations(findings, unknowns)
            diagnosis_id = uuid.uuid4().hex
            result = {
                "schemaVersion": 1,
                "id": diagnosis_id,
                "revision": 1,
                "createdAtMs": now_ms,
                "status": (
                    "fault" if findings else "unknown" if unknowns else "no_issue"
                ),
                "certainty": "limited" if unknowns else "supported",
                "readOnly": True,
                "applied": False,
                "sources": sources,
                "findings": findings,
                "unknowns": unknowns,
                "recommendations": recommendations,
                "redactions": redactions,
            }
            encoded = _canonical(result).decode("ascii")
            if len(encoded.encode("ascii")) > MAX_RESULT_BYTES:
                raise ApiError("payload_too_large", 413)
            row = {
                "id": diagnosis_id,
                "owner_id": actor.id,
                "family_id": actor.family_id,
                "request_key": request_key,
                "revision": 1,
                "request_fingerprint": fingerprint,
                "created_at_ms": now_ms,
                "result_json": encoded,
            }
            connection.execute(
                "INSERT INTO evidence_diagnostics VALUES(?,?,?,?,?,?,?,?,?)",
                (*[row[name] for name in (
                    "id", "owner_id", "family_id", "request_key", "revision",
                    "request_fingerprint", "created_at_ms", "result_json",
                )], self._diagnosis_tag(row)),
            )
        return {"diagnosis": result}

    def diagnosis(self, actor, core_id, home_id, diagnosis_id):
        self._scope(core_id, home_id)
        with self.db.connection() as connection:
            connection.execute("BEGIN")
            self.auth.assert_current(connection, actor)
            row = connection.execute(
                "SELECT * FROM evidence_diagnostics WHERE id=?", (diagnosis_id,)
            ).fetchone()
            result = self._verified_diagnosis(row)
            if row["family_id"] != actor.family_id and actor.role != "admin":
                raise ApiError("forbidden", 403)
            return {"diagnosis": result}

    def preview_repair(self, actor, core_id, home_id, diagnosis_id, body):
        self._scope(core_id, home_id)
        now_ms = round(float(self.settings.clock()) * 1000)
        with self.db.transaction() as connection:
            self.auth.assert_current(connection, actor)
            if actor.role != "admin":
                raise ApiError("forbidden", 403)
            diagnosis_row = connection.execute(
                "SELECT * FROM evidence_diagnostics WHERE id=?", (diagnosis_id,)
            ).fetchone()
            diagnosis = self._verified_diagnosis(diagnosis_row)
            if diagnosis_row["revision"] != body.expectedDiagnosisRevision:
                raise ApiError("diagnostic_changed", 409)
            fingerprint = hashlib.sha256(_canonical({
                "diagnosisId": diagnosis_id,
                "diagnosisRevision": body.expectedDiagnosisRevision,
                "recommendations": diagnosis["recommendations"],
            })).hexdigest()
            old = connection.execute(
                "SELECT * FROM evidence_diagnostic_repair_previews "
                "WHERE owner_id=? AND family_id=? AND request_key=?",
                (actor.id, actor.family_id, body.requestKey),
            ).fetchone()
            if old is not None:
                preview = self._verified_preview(old)
                if not hmac.compare_digest(old["request_fingerprint"], fingerprint):
                    raise ApiError("diagnostic_repair_preview_conflict", 409)
                return {"repairPreview": preview}
            count = connection.execute(
                "SELECT COUNT(*) AS count FROM evidence_diagnostic_repair_previews"
            ).fetchone()["count"]
            if count >= MAX_REPAIR_PREVIEWS:
                raise ApiError("diagnostic_repair_preview_limit", 413)
            preview_id = uuid.uuid4().hex
            expires_at = now_ms + REPAIR_PREVIEW_LIFETIME_MS
            preview = {
                "schemaVersion": 1,
                "id": preview_id,
                "diagnosisId": diagnosis_id,
                "diagnosisRevision": diagnosis_row["revision"],
                "createdAtMs": now_ms,
                "expiresAtMs": expires_at,
                "authorizedRole": "admin",
                "authorizedSessionFamilyId": actor.family_id,
                "previewOnly": True,
                "applied": False,
                "executionAvailable": False,
                "steps": [{
                    "code": item["code"],
                    "sourceFindingIds": item["findingIds"],
                    "requiresExplicitExecution": True,
                } for item in diagnosis["recommendations"]],
            }
            encoded = _canonical(preview).decode("ascii")
            row = {
                "id": preview_id,
                "diagnosis_id": diagnosis_id,
                "owner_id": actor.id,
                "family_id": actor.family_id,
                "request_key": body.requestKey,
                "diagnosis_revision": diagnosis_row["revision"],
                "request_fingerprint": fingerprint,
                "created_at_ms": now_ms,
                "expires_at_ms": expires_at,
                "preview_json": encoded,
            }
            connection.execute(
                "INSERT INTO evidence_diagnostic_repair_previews VALUES(?,?,?,?,?,?,?,?,?,?,?)",
                (*[row[name] for name in (
                    "id", "diagnosis_id", "owner_id", "family_id", "request_key",
                    "diagnosis_revision", "request_fingerprint", "created_at_ms",
                    "expires_at_ms", "preview_json",
                )], self._preview_tag(row)),
            )
        return {"repairPreview": preview}
