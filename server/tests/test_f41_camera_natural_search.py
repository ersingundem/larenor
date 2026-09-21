import pytest

from larenor_server.camera_search import (
    CameraMetadataRecord,
    CameraSearchAuthority,
    CameraSearchIndex,
    CameraSearchRequest,
)
from larenor_server.errors import ApiError


CORE = "1" * 32
HOME = "2" * 32
ACCOUNT = "3" * 32
SESSION = "4" * 32
FRONT = "5" * 32
GARDEN = "6" * 32


def authority(*, account=ACCOUNT, role="member", cameras=(FRONT,), private=False, member_revision=1):
    return CameraSearchAuthority(
        schemaVersion=1,
        coreId=CORE,
        homeId=HOME,
        homeRevision=7,
        accountId=account,
        accountRevision=3,
        memberRevision=member_revision,
        sessionFamilyId=SESSION,
        role=role,
        accessibleCameraIds=list(cameras),
        allowPrivateEvidence=private,
        active=True,
        canSearch=True,
    )


def record(
    clip, event, camera, start, summary, labels,
    *, visibility="household", owner=None, capture_revision=1,
):
    return CameraMetadataRecord(
        schemaVersion=1,
        coreId=CORE,
        homeId=HOME,
        clipId=clip,
        eventId=event,
        cameraId=camera,
        captureRevision=capture_revision,
        startMs=start,
        endMs=start + 30_000,
        evidenceOffsetMs=2_000,
        visibility=visibility,
        ownerAccountId=owner,
        labels=labels,
        summary=summary,
    )


def records():
    return [
        record("7" * 32, "8" * 32, FRONT, 1_000_000, "Ön kapıda paket bırakıldı", ["paket", "kişi"]),
        record("9" * 32, "a" * 32, FRONT, 1_100_000, "Kedi kapının önünden geçti", ["kedi"]),
        record("b" * 32, "c" * 32, GARDEN, 1_200_000, "Bahçede araç görüldü", ["araç"]),
        record("d" * 32, "e" * 32, FRONT, 1_300_000, "Özel aile olayı", ["aile"],
               visibility="private", owner="f" * 32),
    ]


def request(query="ön kapıda paket", *, cameras=(FRONT,), cursor=None, page_size=10, revision=11):
    return CameraSearchRequest(
        schemaVersion=1,
        query=query,
        expectedIndexRevision=revision,
        startMs=900_000,
        endMs=1_500_000,
        cameraIds=list(cameras),
        pageSize=page_size,
        cursor=cursor,
    )


def index(*, current=None, planner=None, revision=11, source=None):
    current = current or {ACCOUNT: authority()}
    return CameraSearchIndex(
        records() if source is None else source,
        revision=revision,
        cursorKey=b"k" * 32,
        authorityResolver=lambda account_id: current.get(account_id),
        queryPlanner=planner,
    )


def test_local_metadata_search_is_scoped_revision_bound_and_explicitly_degraded():
    foreign = record("0" * 32, "1" * 32, FRONT, 1_400_000,
                     "Ön kapıda paket", ["paket"]).model_copy(update={"homeId": "0" * 32})
    result = index(source=records() + [foreign]).search(authority(), request())
    assert result.indexRevision == 11
    assert result.mode == "local_metadata"
    assert result.status == "degraded"
    assert result.degradedReason == "semantic_provider_unavailable"
    assert result.nextCursor is None
    assert len(result.results) == 1
    match = result.results[0]
    assert match.summary == "Ön kapıda paket bırakıldı"
    assert match.matchedTerms == ["kapida", "on", "paket"]
    assert match.evidence.model_dump() == {
        "schemaVersion": 1,
        "kind": "camera_evidence",
        "coreId": CORE,
        "homeId": HOME,
        "cameraId": FRONT,
        "clipId": "7" * 32,
        "eventId": "8" * 32,
        "captureRevision": 1,
        "indexRevision": 11,
        "capturedAtMs": 1_002_000,
    }


def test_cursor_is_opaque_bounded_and_bound_to_query_scope_authority_and_revision():
    scoped = authority(cameras=(FRONT, GARDEN))
    search = index(current={ACCOUNT: scoped})
    first = search.search(scoped, request(query="kapı", page_size=1))
    assert len(first.results) == 1
    assert first.nextCursor is not None and len(first.nextCursor) <= 512
    assert CORE not in first.nextCursor and ACCOUNT not in first.nextCursor
    second = search.search(scoped, request(query="kapı", page_size=1, cursor=first.nextCursor))
    assert second.results[0].evidence.clipId != first.results[0].evidence.clipId
    assert second.nextCursor is None

    for changed in (
        request(query="kedi", page_size=1, cursor=first.nextCursor),
        request(query="kapı", cameras=(GARDEN,), page_size=1, cursor=first.nextCursor),
        request(query="kapı", page_size=2, cursor=first.nextCursor),
    ):
        with pytest.raises(ApiError, match="invalid_request"):
            search.search(scoped, changed)
    with pytest.raises(ApiError, match="revision_conflict"):
        index(revision=12).search(authority(), request(query="kapı", page_size=1, cursor=first.nextCursor))


def test_privacy_camera_and_live_authority_fail_closed_before_planner():
    planned = []
    current = {ACCOUNT: authority()}
    search = index(current=current, planner=lambda query: planned.append(query) or [query])
    with pytest.raises(ApiError, match="not_found"):
        search.search(authority(), request(cameras=(GARDEN,)))
    assert planned == []

    result = search.search(authority(), request(query="aile"))
    assert result.results == []
    assert result.status == "ready"
    current[ACCOUNT] = authority(member_revision=2)
    with pytest.raises(ApiError, match="revision_conflict"):
        search.search(authority(), request())
    assert planned == ["aile"]

    unavailable = CameraSearchIndex(
        records(), revision=11, cursorKey=b"k" * 32,
        authorityResolver=lambda _account: (_ for _ in ()).throw(RuntimeError("private")),
        queryPlanner=lambda query: planned.append(query) or [query],
    )
    with pytest.raises(ApiError, match="forbidden"):
        unavailable.search(authority(), request())
    assert planned == ["aile"]


def test_private_owner_or_explicit_admin_can_read_without_leaking_to_members():
    owner = "f" * 32
    owner_authority = authority(account=owner)
    admin = authority(account="e" * 32, role="admin", cameras=(FRONT, GARDEN), private=True)
    current = {owner: owner_authority, admin.accountId: admin}
    search = index(current=current)
    assert len(search.search(owner_authority, request(query="aile")).results) == 1
    assert len(search.search(admin, request(query="aile")).results) == 1
    with pytest.raises(ValueError):
        authority(private=True)


def test_semantic_planner_is_query_only_bounded_and_failure_degrades_locally():
    calls = []
    ready = index(planner=lambda query: calls.append(query) or ["paket"])
    result = ready.search(authority(), request(query="Bana teslimatı göster"))
    assert calls == ["Bana teslimatı göster"]
    assert result.status == "ready" and result.mode == "semantic_assisted"
    assert result.results[0].matchedTerms == ["paket"]

    degraded = index(planner=lambda _query: (_ for _ in ()).throw(RuntimeError("private")))
    result = degraded.search(authority(), request(query="paket"))
    assert result.status == "degraded"
    assert result.degradedReason == "semantic_provider_unavailable"
    assert len(result.results) == 1


def test_time_bounds_deleted_index_snapshot_and_invalid_contracts_fail_closed():
    search = index()
    assert search.search(authority(), request(query="paket").model_copy(update={"endMs": 999_999})).results == []
    without_clip = index(source=records()[1:], revision=12)
    assert without_clip.search(authority(), request(query="paket", revision=12)).results == []

    with pytest.raises(ValueError):
        CameraSearchRequest.model_validate({**request().model_dump(), "pageSize": 1000})
    with pytest.raises(ValueError):
        CameraSearchRequest(
            schemaVersion=1, query="x", expectedIndexRevision=11,
            startMs=0, endMs=32 * 24 * 60 * 60 * 1000,
            cameraIds=[FRONT], pageSize=10, cursor=None,
        )
    with pytest.raises(ApiError, match="invalid_request"):
        search.search(authority(), request().model_copy(update={"cursor": "tampered"}))


def test_results_are_bounded_deterministic_and_secret_free():
    many = [record(f"{i:032x}", f"{i + 100:032x}", FRONT, 1_000_000 + i,
                   f"Paket {i}", ["paket"]) for i in range(70)]
    result = index(source=many).search(authority(), request(query="paket", page_size=50))
    assert len(result.results) == 50 and result.nextCursor is not None
    assert [entry.startMs for entry in result.results] == sorted(
        [entry.startMs for entry in result.results], reverse=True)
    projection = result.model_dump_json()
    assert "cursorKey" not in projection and "kkkk" not in projection
    assert "sessionFamilyId" not in projection and "accountRevision" not in projection
