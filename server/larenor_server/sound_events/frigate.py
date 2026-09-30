"""Read-only Frigate review ingestion through the authorized F41 source."""

import hashlib
import hmac
import json
import math
import re

from ..errors import ApiError
from .models import SoundEvent, SoundEventAuthority, SoundSourceStatus
from .source_models import (
    FrigateSoundSource,
    FrigateSoundSourceInput,
    SoundSourceChoice,
    SoundSourceRefresh,
    SoundSourceSetup,
)

_REVIEW = re.compile(r"[A-Za-z0-9_.:-]{1,128}\Z")


class FrigateSoundEventRuntime:
    """Read-only Frigate ingress through F41's bounded authorized-read lease."""

    def __init__(self, camera_runtime, home_resources, repository, store, key, context, clock):
        self._camera = camera_runtime
        self._resources = home_resources
        self._repository = repository
        self._store = store
        self._clock = clock
        self._core_id, self._home_id = context.coreId, context.homeId
        self._key = hmac.new(key, b"frigate-sound-events-v1", hashlib.sha256).digest()

    def _opaque(self, domain, *values):
        raw = json.dumps(values, separators=(",", ":"), ensure_ascii=False).encode()
        return hmac.new(self._key, domain.encode() + b"\0" + raw, hashlib.sha256).hexdigest()[:32]

    @staticmethod
    def _revision(value):
        raw = hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).digest()
        return int.from_bytes(raw[:6], "big") + 1

    def _scope(self, core_id, home_id):
        if (core_id, home_id) != (self._core_id, self._home_id):
            raise ApiError("not_found", 404)

    def _record(self, actor, record_id, kind):
        value = self._resources.get(actor, self._core_id, self._home_id, record_id)["record"]
        if value["ref"]["kind"] != kind:
            raise ApiError("invalid_request")
        return value

    def _rooms(self, actor):
        entries, after, snapshot, scanned = [], None, None, 0
        while scanned <= 512:
            page = self._resources.list(
                actor, self._core_id, self._home_id,
                after=after, expected_snapshot=snapshot, limit=100,
            )
            scanned += len(page["entries"])
            snapshot = page["snapshot"]
            entries.extend(item for item in page["entries"] if item["ref"]["kind"] == "room")
            after = page["nextAfter"]
            if after is None:
                break
        if after is not None or scanned > 512 or len(entries) > 128:
            raise ApiError("rate_limited", 429)
        return entries

    @staticmethod
    def _unavailable_status():
        return SoundSourceStatus(
            schemaVersion=1, state="unavailable", capabilityRevision=None,
            providerRevision=None, modelRevision=None, lastObservationAtMs=None,
            freshnessDeadlineMs=None, silenceProven=False, clipAvailable=False,
        )

    def setup(self, actor, core_id, home_id):
        self._scope(core_id, home_id)
        source = self._store.get(actor)
        cameras, rooms = [], []
        if source is not None:
            camera_label, room_label = "Configured camera", "Configured room"
            try:
                camera = self._record(actor, source.cameraResourceId, "resource")
                if camera["revision"] == source.cameraRevision:
                    camera_label = camera["label"]
            except ApiError:
                pass
            try:
                room = self._record(actor, source.roomId, "room")
                if room["revision"] == source.roomRevision:
                    room_label = room["label"]
            except ApiError:
                pass
            cameras = [SoundSourceChoice(
                id=source.cameraResourceId, revision=source.cameraRevision,
                label=camera_label,
                audioLabels=sorted(set(source.labels.bark) | set(source.labels.noise)),
            )]
            rooms = [SoundSourceChoice(
                id=source.roomId, revision=source.roomRevision, label=room_label,
            )]
        return SoundSourceSetup(
            schemaVersion=1, revision=0 if source is None else source.revision,
            discoveryVerified=False, configuration=source,
            cameras=cameras, rooms=rooms,
        )

    def discover(self, actor, core_id, home_id):
        self._scope(core_id, home_id)
        source = self._store.get(actor)
        lease = self._prepared(actor)
        authority, mapping = lease.authority, lease.camera_mapping
        config = self._config(lease)
        cameras = []
        for resource_id, camera_name in mapping.items():
            if resource_id not in authority.accessibleCameraIds:
                continue
            record = self._record(actor, resource_id, "resource")
            camera_config = config["cameras"].get(camera_name)
            audio = camera_config.get("audio") if type(camera_config) is dict else None
            listen = audio.get("listen") if type(audio) is dict else None
            if (audio.get("enabled") is not True if type(audio) is dict else True):
                listen = []
            if (type(listen) is not list or len(listen) > 256
                    or any(not isinstance(label, str) or len(label) > 64 for label in listen)):
                listen = []
            cameras.append(SoundSourceChoice(
                id=resource_id, revision=record["revision"], label=record["label"],
                audioLabels=sorted(set(listen)),
            ))
        rooms = [SoundSourceChoice(id=item["ref"]["id"], revision=item["revision"], label=item["label"])
                 for item in self._rooms(actor)]
        if source is not None:
            if not any(item.id == source.cameraResourceId and item.revision == source.cameraRevision
                       for item in cameras):
                raise ApiError("revision_conflict", 409)
            if not any(item.id == source.roomId and item.revision == source.roomRevision
                       for item in rooms):
                raise ApiError("revision_conflict", 409)
        return SoundSourceSetup(
            schemaVersion=1,
            revision=0 if source is None else source.revision,
            discoveryVerified=True,
            configuration=source,
            cameras=sorted(cameras, key=lambda item: (item.label, item.id)),
            rooms=sorted(rooms, key=lambda item: (item.label, item.id)),
        )

    def _prepared(self, actor):
        return self._camera.authorized_read(actor, self._core_id, self._home_id)

    @staticmethod
    def _config(lease):
        raw = lease.get_json("/api/config")
        if type(raw) is not dict or type(raw.get("cameras")) is not dict or len(raw["cameras"]) > 512:
            raise ApiError("camera_search_source_unavailable", 503)
        return raw

    @staticmethod
    def _audio(config, camera, labels):
        value = config["cameras"].get(camera)
        audio = value.get("audio") if type(value) is dict else None
        listen = audio.get("listen") if type(audio) is dict else None
        if (type(audio) is not dict or audio.get("enabled") is not True
                or type(listen) is not list or len(listen) > 256
                or any(not isinstance(item, str) for item in listen)
                or not (set(labels.bark) | set(labels.noise)) <= set(listen)):
            raise ApiError("camera_search_source_unavailable", 409)
        return {"enabled": True, "listen": sorted(set(listen))}

    def configure(self, actor, core_id, home_id, raw):
        self._scope(core_id, home_id)
        try:
            body = FrigateSoundSourceInput.model_validate(raw)
        except ValueError:
            raise ApiError("invalid_request") from None
        old = self._store.get(actor)
        if not body.consentGranted:
            if (old is None or body.expectedRevision != old.revision
                    or body.cameraResourceId != old.cameraResourceId
                    or body.expectedCameraRevision != old.cameraRevision
                    or body.roomId != old.roomId
                    or body.expectedRoomRevision != old.roomRevision):
                raise ApiError("revision_conflict", 409)
            revision = old.revision + 1
            value = old.model_copy(update={
                "revision": revision,
                "consentGranted": False,
                "consentRevision": revision,
            })
            return self._store.put(actor, value, old.revision)
        lease = self._prepared(actor)
        authority, mapping = lease.authority, lease.camera_mapping
        if body.cameraResourceId not in authority.accessibleCameraIds or body.cameraResourceId not in mapping:
            raise ApiError("forbidden", 403)
        camera = self._record(actor, body.cameraResourceId, "resource")
        room = self._record(actor, body.roomId, "room")
        if camera["revision"] != body.expectedCameraRevision or room["revision"] != body.expectedRoomRevision:
            raise ApiError("revision_conflict", 409)
        config = self._config(lease)
        self._audio(config, mapping[body.cameraResourceId], body.labels)
        if (old is None) != (body.expectedRevision is None) or (old is not None and old.revision != body.expectedRevision):
            raise ApiError("revision_conflict", 409)
        revision = 1 if old is None else old.revision + 1
        lease.assert_current()
        value = FrigateSoundSource(
            schemaVersion=1, revision=revision, ownerId=actor.id,
            cameraResourceId=body.cameraResourceId,
            cameraRevision=body.expectedCameraRevision,
            roomId=body.roomId, roomRevision=body.expectedRoomRevision,
            frigateCamera=mapping[body.cameraResourceId],
            providerRevision=lease.source_revision, labels=body.labels,
            consentGranted=body.consentGranted, consentRevision=revision,
            retentionSeconds=body.retentionSeconds,
            configuredAtMs=int(self._clock() * 1000),
        )
        lease.assert_current()
        return self._store.put(actor, value, body.expectedRevision)

    def _authorized_source(self, actor):
        source = self._store.get(actor)
        if source is None or not source.consentGranted:
            return None
        lease = self._prepared(actor)
        authority, mapping = lease.authority, lease.camera_mapping
        if (source.cameraResourceId not in authority.accessibleCameraIds
                or source.providerRevision != lease.source_revision
                or mapping.get(source.cameraResourceId) != source.frigateCamera):
            raise ApiError("forbidden", 403)
        camera = self._record(actor, source.cameraResourceId, "resource")
        room = self._record(actor, source.roomId, "room")
        if (camera["revision"] != source.cameraRevision
                or room["revision"] != source.roomRevision):
            raise ApiError("revision_conflict", 409)
        self._audio(self._config(lease), source.frigateCamera, source.labels)
        lease.assert_current()
        return source

    @staticmethod
    def _reviews(value, camera):
        if type(value) is not list or len(value) > 256:
            raise ApiError("camera_search_source_unavailable", 503)
        result, seen = [], set()
        for item in value:
            if (type(item) is not dict or not isinstance(item.get("id"), str)
                    or not _REVIEW.fullmatch(item["id"]) or item.get("camera") != camera
                    or item["id"] in seen):
                raise ApiError("camera_search_source_unavailable", 503)
            seen.add(item["id"])
            result.append(item)
        return result

    @staticmethod
    def _review(item, camera):
        data = item.get("data")
        audio = data.get("audio") if type(data) is dict else None
        start, end = item.get("start_time"), item.get("end_time")
        if (item.get("camera") != camera or type(audio) is not list or len(audio) > 256
                or any(not isinstance(label, str) or len(label) > 64 for label in audio)
                or isinstance(start, bool) or isinstance(end, bool)
                or not isinstance(start, (int, float)) or not isinstance(end, (int, float))
                or not math.isfinite(start) or not math.isfinite(end) or end < start):
            raise ApiError("camera_search_source_unavailable", 503)
        start_ms, end_ms = round(start * 1000), round(end * 1000)
        duration = end_ms - start_ms
        if not 100 <= duration <= 60_000 or not 0 <= start_ms <= end_ms <= 2**63 - 1:
            return None
        return sorted(set(audio)), start_ms, duration

    def refresh(self, actor, core_id, home_id, *, cancelled=lambda: False):
        self._scope(core_id, home_id)
        source = self._store.get(actor)
        if source is None:
            raise ApiError("camera_search_not_configured", 409)
        if not source.consentGranted:
            raise ApiError("forbidden", 403)
        if cancelled():
            raise ApiError("revision_conflict", 409)
        now_ms = int(self._clock() * 1000)
        lease = self._prepared(actor)
        authority, mapping = lease.authority, lease.camera_mapping
        if (source.providerRevision != lease.source_revision
                or mapping.get(source.cameraResourceId) != source.frigateCamera):
            raise ApiError("revision_conflict", 409)
        camera = self._record(actor, source.cameraResourceId, "resource")
        room = self._record(actor, source.roomId, "room")
        if camera["revision"] != source.cameraRevision or room["revision"] != source.roomRevision:
            raise ApiError("revision_conflict", 409)
        config = self._config(lease)
        audio_capability = self._audio(config, source.frigateCamera, source.labels)
        model_revision = self._revision([source.frigateCamera, audio_capability])
        after_ms = max(source.configuredAtMs, now_ms - source.retentionSeconds * 1000)
        raw_reviews = lease.get_json(
            "/api/review",
            query={"cameras": source.frigateCamera, "after": str(after_ms // 1000),
                   "before": str(now_ms // 1000 + 1), "limit": "64"},
        )
        reviews = self._reviews(raw_reviews, source.frigateCamera)
        pending, observed = [], None
        authority_value = SoundEventAuthority(
            schemaVersion=1, coreId=self._core_id, homeId=self._home_id,
            homeRevision=authority.homeRevision, accountId=actor.id,
            accountRevision=authority.accountRevision,
            memberRevision=authority.memberRevision,
            sessionFamilyId=actor.family_id,
            accessibleRoomIds=[source.roomId], accessibleDeviceIds=[source.cameraResourceId],
            active=True, canObserve=True,
        )
        for candidate in reviews:
            if cancelled():
                raise ApiError("revision_conflict", 409)
            exact = lease.get_json("/api/review/" + candidate["id"])
            if type(exact) is not dict or exact.get("id") != candidate["id"]:
                raise ApiError("camera_search_source_unavailable", 503)
            parsed = self._review(exact, source.frigateCamera)
            if parsed is None:
                continue
            labels, observed_ms, duration_ms = parsed
            if observed_ms < after_ms or observed_ms > now_ms:
                continue
            mapped = [(label, "bark") for label in labels if label in source.labels.bark]
            mapped += [(label, "noise") for label in labels if label in source.labels.noise]
            if mapped:
                observed = observed_ms if observed is None else max(observed, observed_ms)
            for label, class_name in mapped:
                expires = observed_ms + source.retentionSeconds * 1000
                if expires <= now_ms:
                    continue
                canonical = json.dumps(exact, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()
                event = SoundEvent(
                    schemaVersion=1,
                    eventId=self._opaque("review", actor.id, source.cameraResourceId, exact["id"], label),
                    coreId=self._core_id, homeId=self._home_id,
                    roomId=source.roomId, roomRevision=source.roomRevision,
                    deviceId=source.cameraResourceId, deviceRevision=source.cameraRevision,
                    modelId=self._opaque("model", source.frigateCamera),
                    modelRevision=model_revision, providerRevision=source.providerRevision,
                    policyRevision=source.revision, consentRevision=source.consentRevision,
                    className=class_name,
                    # Frigate reviews expose a categorical audio label, not a probability.
                    # 1.0 means exact upstream label presence, never a synthesized score.
                    confidence=1.0, durationMs=duration_ms, observedAtMs=observed_ms,
                    evidenceDigest=hashlib.sha256(canonical).hexdigest(),
                    retentionExpiresAtMs=expires, automationVerified=False,
                )
                pending.append(event)
        lease.assert_current()
        self._store.assert_current(actor, source)
        if cancelled():
            raise ApiError("revision_conflict", 409)
        imported = 0 if not pending else self._repository.record_batch(
            authority_value, pending, cancelled=cancelled
        )
        self._repository.purge_expired(actor, now_ms)

        with self._store.current_lease(actor, source) as source_current:
            def assert_current(connection=None):
                if connection is None:
                    lease.assert_current()
                else:
                    lease.assert_current_in(connection)
                source_current()

            self._repository.dispatch_notifications(
                actor,
                source_revision=source.revision,
                consent_revision=source.consentRevision,
                assert_current=assert_current,
                cancelled=cancelled,
            )
        status = SoundSourceStatus(
            schemaVersion=1, state="ready" if observed is not None else "degraded",
            capabilityRevision=source.revision, providerRevision=source.providerRevision,
            modelRevision=model_revision, lastObservationAtMs=observed,
            freshnessDeadlineMs=now_ms + 60_000, silenceProven=False, clipAvailable=False,
        )
        lease.assert_current()
        if cancelled():
            raise ApiError("revision_conflict", 409)
        self._store.save_status(actor, source, status)
        return SoundSourceRefresh(
            schemaVersion=1, configurationRevision=source.revision,
            importedEvents=imported, reviewedRecords=len(reviews),
        )

    def status(self, actor):
        try:
            source = self._authorized_source(actor)
        except ApiError:
            return self._unavailable_status()
        if source is None:
            return self._unavailable_status()
        value = self._store.status(actor)
        if value is None:
            return self._unavailable_status()
        if value.freshnessDeadlineMs < int(self._clock() * 1000):
            return value.model_copy(update={"state": "stale"})
        return value

    def access(self, actor):
        """Return local consent state; None means this account has no F45 source."""
        source = self._store.get(actor)
        return None if source is None else source.consentGranted
