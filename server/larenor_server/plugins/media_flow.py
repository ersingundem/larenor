"""Core-owned request-to-playable projection over managed media sources."""

import hashlib
import hmac
import json
import re

from pydantic import ValidationError

from ..errors import ApiError
from .media_flow_models import (
    MediaFlowAuthorityRequest,
    MEDIA_FLOW_PROVIDER_ORDER,
    MediaFlowObservation,
    MediaFlowReadRequest,
    MediaFlowSourceRevision,
    MediaFlowStage,
    MediaFlowStatus,
    MediaSeasonCoverage,
)


_MAX_AGE_SECONDS = 300
_EPISODE_KEY = re.compile(
    r"episode:tvdb:(?P<show>[1-9][0-9]{0,11}):"
    r"(?P<season>[0-9]{1,4}):(?P<episode>[0-9]{1,5})\Z"
)


class MediaFlowManagement:
    def __init__(self, db, auth, settings, key, provider=None):
        self.db = db
        self.auth = auth
        self.settings = settings
        self._key = key
        self.provider = provider

    def _session(self, actor):
        with self.db.connection() as connection:
            self.auth.assert_current(connection, actor)

    @staticmethod
    def _source_revisions(observation):
        return [
            MediaFlowSourceRevision(
                provider=name,
                serviceRevision=getattr(observation, name).serviceRevision,
                snapshotRevision=getattr(observation, name).snapshotRevision,
                observedAt=getattr(observation, name).observedAt,
            )
            for name in MEDIA_FLOW_PROVIDER_ORDER
        ]

    def _current(self, media_key):
        if self.provider is None or not callable(getattr(self.provider, "current", None)):
            raise ApiError("media_flow_provider_unavailable", 503)
        try:
            value = self.provider.current(media_key)
            if type(value) is not MediaFlowObservation:
                raise ValueError()
            current = MediaFlowObservation.model_validate(
                value.model_dump(mode="python")
            )
        except ApiError:
            raise
        except Exception:
            raise ApiError("media_flow_provider_unavailable", 503) from None
        now = int(self.settings.clock())
        sources = self._source_revisions(current)
        if any(
            source.observedAt > now
            or now - source.observedAt > _MAX_AGE_SECONDS
            for source in sources
        ):
            raise ApiError("media_flow_snapshot_stale", 409)
        return current, sources

    def _stable(self, actor, media_key):
        self._session(actor)
        first, sources = self._current(media_key)
        self._session(actor)
        second, second_sources = self._current(media_key)
        self._session(actor)
        if first != second or sources != second_sources:
            raise ApiError("media_flow_authority_changed", 409)
        self._accept_high_water(media_key, second)
        return second, second_sources

    @staticmethod
    def _snapshot_digest(observation):
        encoded = json.dumps(
            observation.model_dump(mode="json"),
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
        return hashlib.sha256(encoded).hexdigest()

    def _high_water_tag(self, media_key, revision, digest):
        payload = f"{media_key}\0{revision}\0{digest}".encode("ascii")
        return hmac.new(self._key, payload, hashlib.sha256).digest()

    def _accept_high_water(self, media_key, observation):
        revision = observation.flowRevision
        digest = self._snapshot_digest(observation)
        tag = self._high_water_tag(media_key, revision, digest)
        try:
            with self.db.transaction() as connection:
                row = connection.execute(
                    "SELECT flow_revision,snapshot_digest,integrity_tag "
                    "FROM media_flow_high_water WHERE media_key=?",
                    (media_key,),
                ).fetchone()
                if row is not None:
                    expected = self._high_water_tag(
                        media_key, row["flow_revision"], row["snapshot_digest"]
                    )
                    if not hmac.compare_digest(expected, row["integrity_tag"]):
                        raise ApiError("media_flow_storage_unavailable", 503)
                    if revision < row["flow_revision"] or (
                        revision == row["flow_revision"]
                        and digest != row["snapshot_digest"]
                    ):
                        raise ApiError("media_flow_snapshot_replayed", 409)
                    if revision == row["flow_revision"]:
                        return
                connection.execute(
                    "INSERT INTO media_flow_high_water("
                    "media_key,flow_revision,snapshot_digest,integrity_tag) "
                    "VALUES(?,?,?,?) ON CONFLICT(media_key) DO UPDATE SET "
                    "flow_revision=excluded.flow_revision,"
                    "snapshot_digest=excluded.snapshot_digest,"
                    "integrity_tag=excluded.integrity_tag",
                    (media_key, revision, digest, tag),
                )
        except ApiError:
            raise
        except Exception:
            raise ApiError("media_flow_storage_unavailable", 503) from None

    def authority(self, actor, body):
        if type(body) is not MediaFlowAuthorityRequest:
            raise ApiError("invalid_request")
        observation, sources = self._stable(actor, body.mediaKey)
        return {
            "requestId": body.requestId,
            "mediaKey": body.mediaKey,
            "flowRevision": observation.flowRevision,
            "sources": [item.model_dump() for item in sources],
        }

    def read(self, actor, body):
        if type(body) is not MediaFlowReadRequest:
            raise ApiError("invalid_request")
        observation, sources = self._stable(actor, body.mediaKey)
        if (
            observation.flowRevision != body.expectedFlowRevision
            or sources != body.expectedSources
        ):
            raise ApiError("media_flow_authority_changed", 409)
        try:
            flow = self._project(body.mediaKey, observation, sources)
        except (ValidationError, ValueError, TypeError, AttributeError):
            raise ApiError("media_flow_provider_unavailable", 503) from None
        return {"requestId": body.requestId, "flow": flow.model_dump()}

    @staticmethod
    def _stage(name, state, provider, observation):
        return MediaFlowStage(
            name=name,
            state=state,
            provider=provider,
            sourceRevision=getattr(observation, provider).serviceRevision,
        )

    @staticmethod
    def _matching_items(media_key, items):
        if media_key.startswith("movie:"):
            return [item for item in items if item.mediaKey == media_key]
        show = media_key.rsplit(":", 1)[1]
        prefix = f"episode:tvdb:{show}:"
        return [
            item for item in items
            if item.mediaKey is not None and item.mediaKey.startswith(prefix)
        ]

    @staticmethod
    def _episode(media_key):
        match = _EPISODE_KEY.fullmatch(media_key)
        if match is None:
            return None
        return int(match.group("season")), int(match.group("episode"))

    @classmethod
    def _seasons(cls, media_key, request, qbit, arr, jellyfin):
        if media_key.startswith("movie:"):
            return []
        requested = set(request.requestedSeasons if request is not None else ())
        known = {}

        for item in arr:
            parsed = cls._episode(item.mediaKey)
            if parsed is None:
                continue
            season, episode = parsed
            known.setdefault(season, {
                "known": set(), "downloaded": set(),
                "imported": set(), "playable": set(),
            })["known"].add(episode)
            if item.state == "available":
                known[season]["imported"].add(episode)
        for item in qbit:
            parsed = cls._episode(item.mediaKey) if item.mediaKey else None
            if parsed is None:
                continue
            season, episode = parsed
            known.setdefault(season, {
                "known": set(), "downloaded": set(),
                "imported": set(), "playable": set(),
            })["known"].add(episode)
            if item.state in {"complete", "seeding"}:
                known[season]["downloaded"].add(episode)
        for item in jellyfin:
            parsed = cls._episode(item.mediaKey)
            if parsed is None:
                continue
            season, episode = parsed
            known.setdefault(season, {
                "known": set(), "downloaded": set(),
                "imported": set(), "playable": set(),
            })["known"].add(episode)
            if item.integrity == "playable":
                known[season]["playable"].add(episode)
        for season in requested:
            known.setdefault(season, {
                "known": set(), "downloaded": set(),
                "imported": set(), "playable": set(),
            })

        result = []
        for season, evidence in sorted(known.items()):
            known_episodes = evidence["known"]
            missing = known_episodes - evidence["playable"]
            result.append(MediaSeasonCoverage(
                seasonNumber=season,
                knownEpisodes=sorted(known_episodes),
                downloadedEpisodes=sorted(evidence["downloaded"]),
                importedEpisodes=sorted(evidence["imported"]),
                playableEpisodes=sorted(evidence["playable"]),
                missingEpisodes=sorted(missing),
                requested=season in requested,
                requestable=(
                    season not in requested
                    and not evidence["downloaded"]
                    and not evidence["imported"]
                    and not evidence["playable"]
                ),
                incomplete=(
                    ((season in requested) or bool(known_episodes))
                    and bool(missing)
                    or season in requested and not known_episodes
                ),
                missingSeason=(
                    ((season in requested) or bool(known_episodes))
                    and not evidence["playable"]
                ),
                partialImport=(
                    bool(evidence["imported"])
                    and bool(known_episodes - evidence["imported"])
                ),
            ))
        return result

    @classmethod
    def _project(cls, media_key, observation, sources):
        request = next(
            (item for item in observation.seerr.requests
             if item.mediaKey == media_key),
            None,
        )
        qbit = cls._matching_items(media_key, observation.qbittorrent.items)
        arr_source = observation.radarr if media_key.startswith("movie:") else observation.sonarr
        arr = cls._matching_items(media_key, arr_source.items)
        jellyfin = cls._matching_items(media_key, observation.jellyfin.items)

        request_state = (
            "not_started" if request is None
            else "pending" if request.state == "pending"
            else "complete" if request.state == "approved"
            else "failed"
        )
        download_state = (
            "not_started" if not qbit
            else "failed" if any(item.state == "error" for item in qbit)
            else "active" if any(item.state in {"downloading", "paused"} for item in qbit)
            else "complete"
        )
        import_state = (
            "not_started" if not arr
            else "failed" if any(item.state == "failed" for item in arr)
            else "active" if any(item.state in {"queued", "downloading"} for item in arr)
            else "partial" if any(item.state != "available" for item in arr)
            else "complete"
        )
        seasons = cls._seasons(media_key, request, qbit, arr, jellyfin)
        playable_items = [item for item in jellyfin if item.integrity == "playable"]
        if media_key.startswith("movie:"):
            playable_state = (
                "complete" if playable_items
                else "failed" if jellyfin
                else "not_started"
            )
        else:
            playable_state = (
                "not_started" if not playable_items
                else "partial" if any(item.incomplete for item in seasons)
                else "complete"
            )
        stages = [
            cls._stage("request", request_state, "seerr", observation),
            cls._stage("download", download_state, "qbittorrent", observation),
            cls._stage(
                "import", import_state,
                "radarr" if media_key.startswith("movie:") else "sonarr",
                observation,
            ),
            cls._stage("playable", playable_state, "jellyfin", observation),
        ]
        if playable_state == "complete":
            state = "playable"
        elif playable_state == "partial" or any(item.incomplete for item in seasons):
            state = "partial"
        elif "failed" in {request_state, download_state, import_state, playable_state}:
            state = "failed"
        elif import_state in {"active", "partial", "complete"}:
            state = "importing"
        elif download_state in {"active", "complete"}:
            state = "downloading"
        elif request_state != "not_started":
            state = "requested"
        else:
            state = "not_requested"
        return MediaFlowStatus(
            mediaKey=media_key,
            flowRevision=observation.flowRevision,
            state=state,
            stages=stages,
            sources=sources,
            seasons=seasons,
        )
