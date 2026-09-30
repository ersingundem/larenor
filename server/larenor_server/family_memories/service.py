"""Authorized F38 orchestration over the real Immich adapter and album store."""

from ..errors import ApiError
from .contracts import (
    CreateMemoryAlbumRequest, DeleteMemoryAlbumRequest, MemoryAlbumContract,
    MemoryAssetContract, MemoryAuthorityContract, MemorySearchRequest,
    MemorySnapshotRequest, ReconcileMemoryAlbumRequest,
    ReplaceMemorySelectionsRequest,
    UpdateMemoryAlbumRequest,
)
from .immich import ImmichMemoryAdapter
from ..services.service import ServiceConnection
from .models import MemoryError, MemoryPolicy, MemorySearch
from .selection import MemoryAlbumAuthority, MemorySelection


class FamilyMemoriesService:
    """All authorities are injected current facts; no detached grants."""

    def __init__(self, store, auth, authority_provider, connection_provider,
                 policy_provider, *, adapter_factory=ImmichMemoryAdapter):
        if any(not callable(value) for value in (
                authority_provider, connection_provider, policy_provider,
                adapter_factory)):
            raise ValueError("invalid_family_memories_dependencies")
        self.store, self.auth = store, auth
        self._authority_provider = authority_provider
        self._connection_provider = connection_provider
        self._policy_provider = policy_provider
        self._adapter_factory = adapter_factory

    def _facts(self, actor, expected_members_revision=None):
        with self.store.database.connection() as connection:
            connection.execute("BEGIN")
            self.auth.assert_current(connection, actor)
        authority, member_ids = self._authority_provider(actor)
        if (type(authority) is not MemoryAlbumAuthority
                or type(member_ids) is not tuple
                or authority.account_id != actor.id
                or authority.session_id != actor.family_id
                or expected_members_revision is not None
                and authority.members_revision != expected_members_revision
                or actor.id not in member_ids
                or len(member_ids) > 32):
            raise ApiError("memory_authority_changed", 409)
        return authority, member_ids

    def _policy(self, actor, authority, service_id, service_revision):
        try:
            policy = self._policy_provider(actor, service_id, service_revision)
        except MemoryError as error:
            if error.code == "binding_changed":
                raise ApiError("memory_binding_changed", 409) from None
            raise ApiError("memory_policy_unavailable", 503) from None
        if type(policy) is not MemoryPolicy:
            raise ApiError("memory_policy_unavailable", 503)
        if (policy.core_id != authority.core_id
                or policy.home_id != authority.home_id
                or policy.account_id != actor.id
                or service_id is not None and policy.service_id != service_id
                or service_revision is not None
                and policy.service_revision != service_revision):
            raise ApiError("memory_binding_changed", 409)
        return policy

    def _connection(self, actor, policy):
        connection = self._connection_provider(
            actor, policy.service_id, policy.service_revision)
        if (type(connection) is not ServiceConnection
                or connection.id != policy.service_id
                or connection.revision != policy.service_revision
                or connection.kind != "immich"):
            raise ApiError("memory_binding_changed", 409)
        return connection

    def _recheck(self, actor, authority, policy):
        current, _members = self._facts(actor, authority.members_revision)
        if current != authority or self._policy(
                actor, current, policy.service_id, policy.service_revision) != policy:
            raise ApiError("memory_binding_changed", 409)
        self._connection(actor, policy)

    @staticmethod
    def _authority(value):
        return MemoryAuthorityContract(
            coreId=value.core_id, homeId=value.home_id,
            accountId=value.account_id, sessionId=value.session_id,
            membersRevision=value.members_revision,
        )

    @staticmethod
    def _album(value):
        return MemoryAlbumContract(
            albumId=value.id, revision=value.revision, title=value.title,
            visibility=value.visibility, ownerId=value.owner_id,
            memberIds=list(value.member_ids), serviceId=value.service_id,
            serviceRevision=value.service_revision,
            assets=[{
                "assetId": item.asset_id,
                "sourceAlbumId": item.source_album_id,
                "sourceEtag": item.source_etag,
            } for item in value.assets], updatedAt=value.updated_at,
        )

    @staticmethod
    def _members(actor, visibility, requested, current):
        values = tuple(requested)
        if (len(set(values)) != len(values) or actor.id not in values
                or not set(values).issubset(current)
                or visibility == "personal" and values != (actor.id,)):
            raise ApiError("memory_members_changed", 409)
        return values

    def snapshot(self, actor, body: MemorySnapshotRequest):
        authority, members = self._facts(actor)
        policy = self._policy(actor, authority, None, None)
        self._connection(actor, policy)
        return {"requestId": body.requestId, "snapshot": {
            "schemaVersion": 1,
            "authority": self._authority(authority),
            "binding": {
                "serviceId": policy.service_id,
                "serviceRevision": policy.service_revision,
                "allowedAlbumIds": list(policy.allowed_album_ids),
                "faceSearchEnabled": policy.face_search_enabled,
            },
            "memberIds": list(members),
            "albums": [self._album(value)
                       for value in self.store.list(actor, authority)],
        }}

    def search(self, actor, body: MemorySearchRequest):
        authority, _members = self._facts(actor, body.expectedMembersRevision)
        policy = self._policy(
            actor, authority, body.serviceId, body.expectedServiceRevision)
        connection = self._connection(actor, policy)
        try:
            with self._adapter_factory(connection, policy) as adapter:
                result = adapter.search(MemorySearch(
                    body.query, tuple(body.albumIds), body.limit,
                    body.language, tuple(body.personIds),
                    body.takenAfter, body.takenBefore,
                ))
        except MemoryError as error:
            status = 409 if error.code in {
                "binding_changed", "album_forbidden",
                "face_consent_required",
            } else 503
            raise ApiError(f"memory_{error.code}", status) from None
        self._recheck(actor, authority, policy)
        return {"requestId": body.requestId, "assets": [
            MemoryAssetContract(
                assetId=item.id, fileName=item.file_name,
                takenAt=item.taken_at, thumbhash=item.thumbhash,
                sourceEtag=item.source_etag,
                sourceAlbumId=item.source_album_id,
            ) for item in result.assets
        ]}

    def create(self, actor, body: CreateMemoryAlbumRequest):
        authority, current = self._facts(actor, body.expectedMembersRevision)
        members = self._members(actor, body.visibility, body.memberIds, current)
        policy = self._policy(
            actor, authority, body.serviceId, body.expectedServiceRevision)
        self._connection(actor, policy)
        try:
            album = self.store.create(
                actor, authority, album_id=body.requestId, title=body.title,
                visibility=body.visibility, member_ids=members,
                service_id=body.serviceId,
                service_revision=body.expectedServiceRevision,
            )
        except ApiError as error:
            if error.code != "memory_album_conflict":
                raise
            album = self.store.read(actor, authority, body.requestId)
            if (album.title != body.title.strip()
                    or album.visibility != body.visibility
                    or album.member_ids != members
                    or album.service_id != body.serviceId
                    or album.service_revision != body.expectedServiceRevision):
                raise ApiError("memory_request_conflict", 409) from None
        return {"requestId": body.requestId, "album": self._album(album)}

    def update(self, actor, album_id, body: UpdateMemoryAlbumRequest):
        authority, current = self._facts(actor, body.expectedMembersRevision)
        members = self._members(actor, body.visibility, body.memberIds, current)
        album = self.store.update(
            actor, authority, album_id=album_id,
            expected_revision=body.expectedRevision, title=body.title,
            visibility=body.visibility, member_ids=members,
        )
        return {"requestId": body.requestId, "album": self._album(album)}

    def replace(self, actor, album_id, body: ReplaceMemorySelectionsRequest):
        authority, _current = self._facts(actor, body.expectedMembersRevision)
        policy = self._policy(
            actor, authority, body.serviceId, body.expectedServiceRevision)
        connection = self._connection(actor, policy)
        assets = tuple(MemorySelection(
            item.assetId, item.sourceAlbumId, item.sourceEtag)
            for item in body.assets)
        if not {item.source_album_id for item in assets}.issubset(
                policy.allowed_album_ids):
            raise ApiError("memory_album_forbidden", 409)
        try:
            with self._adapter_factory(connection, policy) as adapter:
                for item in assets:
                    source = adapter.asset(item.asset_id, source_album_id=item.source_album_id)
                    if source is None or source.source_etag != item.source_etag:
                        raise ApiError("memory_asset_changed", 409)
        except MemoryError as error:
            raise ApiError(f"memory_{error.code}", 503) from None
        self._recheck(actor, authority, policy)
        album = self.store.replace(
            actor, authority, album_id=album_id,
            expected_revision=body.expectedRevision,
            service_id=body.serviceId,
            service_revision=body.expectedServiceRevision, assets=assets,
        )
        return {"requestId": body.requestId, "album": self._album(album)}

    def reconcile(self, actor, album_id, body: ReconcileMemoryAlbumRequest):
        authority, _current = self._facts(actor, body.expectedMembersRevision)
        album = self.store.read(actor, authority, album_id)
        if (album.revision != body.expectedRevision
                or album.service_id != body.serviceId
                or album.service_revision != body.expectedServiceRevision):
            raise ApiError("memory_album_changed", 409)
        policy = self._policy(
            actor, authority, body.serviceId, body.expectedServiceRevision)
        connection = self._connection(actor, policy)
        if not {item.source_album_id for item in album.assets}.issubset(
                policy.allowed_album_ids):
            raise ApiError("memory_album_forbidden", 409)
        try:
            with self._adapter_factory(connection, policy) as adapter:
                retained = tuple(
                    item for item in album.assets
                    if (source := adapter.asset(item.asset_id,
                            source_album_id=item.source_album_id)) is not None
                    and source.source_etag == item.source_etag
                )
        except MemoryError as error:
            raise ApiError(f"memory_{error.code}", 503) from None
        self._recheck(actor, authority, policy)
        if retained != album.assets:
            album = self.store.replace(
                actor, authority, album_id=album_id,
                expected_revision=album.revision,
                service_id=album.service_id,
                service_revision=album.service_revision, assets=retained,
            )
        return {"requestId": body.requestId, "album": self._album(album)}

    def delete(self, actor, album_id, body: DeleteMemoryAlbumRequest):
        authority, _current = self._facts(actor, body.expectedMembersRevision)
        self.store.delete(
            actor, authority, album_id=album_id,
            expected_revision=body.expectedRevision,
        )
