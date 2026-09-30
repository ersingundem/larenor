# F38 — normal Core Immich source binding

This supersedes the earlier adapter/store foundation records. Normal Core now
uses encrypted account grants and its configured private Immich service; no
injected provider is required. F38 is implemented, awaiting complete software
acceptance and exact commit CI. Counters remain 37/126 and 3/63.

An administrator selects an authenticated Immich 3.2.x connection and reads
its real album catalogue. The grant binds the exact account revision, service
revision and up to 32 album IDs. Regranting resets face search to disabled;
only the affected account can enable it. Members cannot enumerate services or
other accounts. Revocation and account changes invalidate access immediately,
including results that finish after revocation or an identical regrant. AES-GCM protects grants at rest;
startup rejects corrupted storage. Credentials stay in private service storage.

Every catalogue, search and asset reconciliation checks the actual peer through
`GET /api/server/about`. Older, prerelease and other minor versions are rejected
before structured search dispatch. Search is confined to one allowed album;
selection and reconciliation independently verify upstream membership through
`GET /api/albums?assetId=...`. Original images are never downloaded or deleted.
The Cupertino source settings allow actual service/album selection, account
grants, self-only face consent and explicit revocation.

## Pinned upstream contracts

- [Immich v3.2.4 structured search DTO](https://github.com/immich-app/immich/blob/v3.2.4/server/src/dtos/search.dto.ts): structured album, image, person and date filters were added in 3.2.0.
- [Immich v3.2.4 server DTO](https://github.com/immich-app/immich/blob/v3.2.4/server/src/dtos/server.dto.ts): actual server version.
- [Immich v3.2.4 album DTO](https://github.com/immich-app/immich/blob/v3.2.4/server/src/dtos/album.dto.ts): `assetId` catalogue filter.
- [Immich v3.2.4 album controller](https://github.com/immich-app/immich/blob/v3.2.4/server/src/controllers/album.controller.ts): authenticated catalogue read.

## Executed evidence

`cd server && uv run pytest tests/test_f38_family_memories.py
tests/test_f38_memory_albums.py tests/test_f38_memory_sources_core.py
tests/test_api_boundary.py -q` passed **38 tests**. The normal Core tests use an
actual loopback HTTP server and normal private transport, covering grant/search,
encrypted restart, current membership, forged selections, index reconciliation,
admin/member boundaries, consent/CAS, late revocation and actual version downgrade
with no subsequent search request. This is contract acceptance against controlled
HTTP fixtures, not an installed Immich server or physical device acceptance.

`flutter test test/features/server/server_family_memories_source_test.dart`
passed **7 tests**: strict source parsing/privacy, unbound setup, retired account
responses, atomic refresh failure, source/snapshot drift rejection, switching
another account back to the actor, and UI service/album selection leading to an actual API grant request.
Focused Flutter analysis passed with zero issues.

## Open acceptance

Installed Immich 3.2.4 with its real model/index, Turkish semantic relevance,
isolated full Flutter Client → Core → Immich acceptance, backup/restore of grants
and manifests, Android usability and exact HEAD CI remain open. A transport
fixture or static analysis does not close those gates. Face consent permits
existing person-ID filtering; this does not claim creation of upstream face
labels or training a model. Physical and household credentials stay in the
separate manual matrix.
