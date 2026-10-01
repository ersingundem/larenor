import sqlite3

from ..errors import ApiError
from ..home_resources.models import HomeScope
from ..plugins.media_playback_models import (
    PlaybackInfoRequest,
    local_playback_profile_digest,
)
from .models import (
    PlaybackInfoObservationRequest,
    PlaybackInfoObservationResponse,
    PlaybackQualityAdviceRequest,
)


_METHOD_REASONS = {
    "direct_play": "server_direct_play",
    "remux": "server_remux",
    "transcode": "server_transcode",
    "unknown": "server_decision_missing",
}
_TRANSCODE_REASONS = {
    "container": "container_conversion",
    "video_codec": "video_codec_mismatch",
    "audio_codec": "audio_codec_mismatch",
    "subtitle": "subtitle_requires_conversion",
    "bitrate": "bitrate_limit",
    "resolution": "resolution_limit",
    "hdr": "hdr_limit",
    "network": "network_limit",
    "receiver": "receiver_limit",
    "unknown": "unspecified_transcode_reason",
}


def _combined_state(*states):
    if "unknown" in states:
        return "unknown"
    if states and all(state == "verified" for state in states):
        return "verified"
    return "reported"


def _append_unique(values, value):
    if value not in values:
        values.append(value)


class PlaybackQualityService:
    """Produces bounded advice; it never controls playback or accepts hardware."""

    def __init__(self, db, auth, settings, context, media_playback=None):
        self.db, self.auth, self.settings = db, auth, settings
        self.scope = HomeScope.model_validate(context.model_dump())
        self.media_playback = media_playback

    def _scope(self, core_id, home_id):
        if (core_id, home_id) != (self.scope.coreId, self.scope.homeId):
            raise ApiError("not_found", 404)

    def _current_actor(self, connection, actor):
        self.auth.assert_current(connection, actor)
        row = connection.execute(
            "SELECT revision,disabled,must_change_password FROM users WHERE id=?",
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

    @staticmethod
    def _bitrate_limit(body):
        limits = []
        if body.media.bitrateBps is not None:
            limits.append(body.media.bitrateBps * 80 // 100)
        if body.network.downstreamKbps is not None:
            limits.append(body.network.downstreamKbps * 1000 * 70 // 100)
        if not limits:
            return None
        return max(1, min(limits))

    @staticmethod
    def _evidence(body):
        media = body.media
        receiver = body.receiver
        codec_known = any((media.container, media.videoCodec, media.audioCodec))
        receiver_codec_known = bool(receiver.videoCodecs or receiver.audioCodecs)
        codec = (
            _combined_state(media.state, receiver.state)
            if codec_known and receiver_codec_known
            else "unknown"
        )
        bitrate = media.state if media.bitrateBps is not None else "unknown"
        hdr_known = media.hdr not in (None, "unknown") and bool(receiver.hdrTypes)
        hdr = (
            _combined_state(media.state, receiver.state)
            if hdr_known
            else "unknown"
        )
        return {
            "schemaVersion": 1,
            "codec": codec,
            "bitrate": bitrate,
            "network": body.network.state,
            "receiver": receiver.state,
            "hdr": hdr,
        }

    @staticmethod
    def _gaps(body, evidence):
        gaps = []
        if body.media.state == "unknown":
            gaps.append("source_telemetry_missing")
        if evidence["codec"] == "unknown":
            gaps.append("codec_telemetry_missing")
        if evidence["bitrate"] == "unknown":
            gaps.append("bitrate_telemetry_missing")
        if evidence["network"] == "unknown":
            gaps.append("network_telemetry_missing")
        if evidence["receiver"] == "unknown":
            gaps.append("receiver_telemetry_missing")
        if evidence["hdr"] == "unknown":
            gaps.append("hdr_telemetry_missing")
        return gaps

    @staticmethod
    def _recommendations(body, gaps):
        recommendations = []

        def add(code, load, bitrate=None):
            if any(item["code"] == code for item in recommendations):
                return
            recommendations.append(
                {
                    "schemaVersion": 1,
                    "code": code,
                    "maxBitrateBps": bitrate,
                    "processingLoad": load,
                }
            )

        reasons = set(body.media.transcodeReasons)
        if body.media.serverDecision in ("direct_play", "remux"):
            add("keep_original", "low")
        if body.media.serverDecision == "transcode":
            if reasons & {"bitrate", "network"}:
                add("lower_bitrate", "high", PlaybackQualityService._bitrate_limit(body))
            if "audio_codec" in reasons:
                add("prefer_compatible_audio", "medium")
            if "subtitle" in reasons:
                add("prefer_external_subtitle", "low")
            if reasons & {"container", "video_codec", "resolution", "receiver"}:
                add("inspect_receiver", "unknown")
            if "hdr" in reasons:
                add("verify_hdr_on_device", "unknown")
        if "receiver_telemetry_missing" in gaps or "codec_telemetry_missing" in gaps:
            add("inspect_receiver", "unknown")
        if "network_telemetry_missing" in gaps:
            add("measure_network", "unknown")
        if "hdr_telemetry_missing" in gaps:
            add("verify_hdr_on_device", "unknown")
        return recommendations

    def advise(self, actor, core_id, home_id, value):
        body = PlaybackQualityAdviceRequest.model_validate(value)
        self._scope(core_id, home_id)
        self.auth.rate_limit([("playback_quality_advice", actor.id, 120)])
        try:
            with self.db.connection() as connection:
                user = self._current_actor(connection, actor)
        except (ValueError, TypeError, sqlite3.Error, OverflowError):
            raise ApiError("server_unavailable", 503) from None

        evidence = self._evidence(body)
        gaps = self._gaps(body, evidence)
        reasons = [_METHOD_REASONS[body.media.serverDecision]]
        for reason in body.media.transcodeReasons:
            _append_unique(reasons, _TRANSCODE_REASONS[reason])
        if body.media.serverDecision == "transcode" and not body.media.transcodeReasons:
            reasons.append("unspecified_transcode_reason")

        confidence = "unknown"
        if body.media.serverDecision != "unknown":
            states = tuple(value for key, value in evidence.items() if key != "schemaVersion")
            confidence = "verified" if states and all(v == "verified" for v in states) else "reported"

        return {
            "schemaVersion": 1,
            "authority": self._authority(actor, user),
            "requestId": body.requestId,
            "advisoryOnly": True,
            "physicalAcceptance": "manual",
            "method": body.media.serverDecision,
            "confidence": confidence,
            "evidence": evidence,
            "gaps": gaps,
            "reasons": reasons,
            "recommendations": self._recommendations(body, gaps),
        }

    def observe_item(self, actor, core_id, home_id, value):
        body = PlaybackInfoObservationRequest.model_validate(value)
        self._scope(core_id, home_id)
        self.auth.rate_limit([("playback_info_observe", actor.id, 120)])
        try:
            with self.db.connection() as connection:
                before = self._current_actor(connection, actor)["revision"]
            provider = self.media_playback() if callable(
                self.media_playback) else self.media_playback
            if provider is None:
                raise ValueError()
            request = PlaybackInfoRequest(
                schemaVersion=1,
                requestId=body.requestId,
                installationId=body.installationId,
                expectedInstallationRevision=(
                    body.expectedInstallationRevision),
                expectedSnapshotRevision=body.expectedSnapshotRevision,
                expectedJellyfinServiceRevision=(
                    body.expectedJellyfinServiceRevision),
                itemId=body.itemId,
                mediaKey=body.mediaKey,
                profile=body.localProfile,
            )
            account_revision, private, readback = provider.playback_info(
                actor, request)
            with self.db.connection() as connection:
                after = self._current_actor(connection, actor)["revision"]
            if before != account_revision or after != before:
                raise ApiError("playback_quality_authority_changed", 409)
            if (private.installationId != body.installationId
                    or private.installationRevision
                    != body.expectedInstallationRevision
                    or private.snapshotRevision
                    != body.expectedSnapshotRevision
                    or private.jellyfinServiceRevision
                    != body.expectedJellyfinServiceRevision
                    or private.itemId != body.itemId
                    or private.mediaKey != body.mediaKey
                    or readback.itemId != body.itemId
                    or readback.profileDigest
                    != local_playback_profile_digest(body.localProfile)):
                raise ApiError("playback_quality_authority_changed", 409)
            recorder = getattr(
                provider, "record_playback_info_observation", None)
            if not callable(recorder):
                raise ValueError()
            observation_id, observed_at, expires_at = recorder(
                actor, before, private, body.localProfile, readback)
            response = PlaybackInfoObservationResponse(
                schemaVersion=1,
                requestId=body.requestId,
                observationId=observation_id,
                authority={
                    **self._authority(actor, {"revision": before}),
                    "installationId": private.installationId,
                    "installationRevision": private.installationRevision,
                    "snapshotRevision": private.snapshotRevision,
                    "jellyfinServiceRevision": (
                        private.jellyfinServiceRevision),
                    "itemId": private.itemId,
                    "mediaKey": private.mediaKey,
                    "profileId": body.localProfile.profileId,
                    "profileRevision": body.localProfile.profileRevision,
                    "displayRevision": body.localProfile.displayRevision,
                    "decoderRevision": body.localProfile.decoderRevision,
                    "networkRevision": body.localProfile.networkRevision,
                    "policyRevision": body.localProfile.policyRevision,
                    "profileDigest": readback.profileDigest,
                },
                observation={
                    "schemaVersion": 1,
                    "assurance": readback.assurance,
                    "originalByteOutcome": readback.originalByteOutcome,
                    "playMethod": readback.playMethod,
                    "source": (
                        None if readback.source is None else {
                            "container": readback.source.container,
                            "bitrateBps": readback.source.bitrate,
                            "videoCodecs": readback.source.videoCodecs,
                            "audioCodecs": readback.source.audioCodecs,
                            "videoRanges": readback.source.videoRanges,
                        }),
                    "transcoding": (
                        None if readback.transcoding is None else {
                            "container": readback.transcoding.container,
                            "videoCodec": readback.transcoding.videoCodec,
                            "audioCodec": readback.transcoding.audioCodec,
                            "bitrateBps": readback.transcoding.bitrate,
                            "reasons": readback.transcoding.reasons,
                        }),
                    "reason": readback.reason,
                    "advisoryOnly": True,
                    "physicalAcceptance": "manual",
                    "observedAt": observed_at,
                    "expiresAt": expires_at,
                },
            )
            return response.model_dump(mode="python")
        except ApiError:
            raise
        except (ValueError, TypeError, sqlite3.Error, OverflowError):
            raise ApiError("server_unavailable", 503) from None
