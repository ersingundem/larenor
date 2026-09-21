# F41 camera recording search authenticated HTTP route — TDD evidence

## Acceptance boundary

This slice registers the Core metadata-search contract at
`POST /api/v1/camera-search/{coreId}/{homeId}/search`. The request never carries
account authority: Core derives it from the authenticated, password-ready
session and a server-owned live authority resolver.

The three software acceptance criteria are:

1. The route requires a current account session, exact persisted Core/home,
   live account/member/session-family revisions and an allowed camera set.
   Foreign homes and cameras return `not_found` without revealing existence;
   inactive, missing or mismatched account authority is forbidden.
2. The closed request preserves the Core limits for query length, 31-day time
   window, 16 cameras, 50-result maximum and authenticated cursor. The response
   is the closed, secret-free evidence projection; private evidence remains
   visible only under the authority rules enforced by the immutable index.
3. Core rechecks the token, live authority, camera scope and index revision
   after search planning. Session revocation discards computed results with
   `invalid_session`; authority or index drift returns `revision_conflict` and
   no result body is published.

## RED

- `c084dea8` added integration tests against the missing route/runtime. The
  contract could not import `camera_search.api`, proving that no HTTP boundary
  or app registration existed.

## GREEN

Validation on 2026-09-21:

- Existing index plus new authenticated HTTP integration suite: 11 passed.
- Core package compilation passed.
- Missing authentication, foreign home/camera, private-result filtering,
  closed body, index drift, mid-search logout and membership revision drift are
  covered by deterministic fixtures.

## Remaining physical acceptance

A production runtime still needs an NVR/camera metadata ingestion adapter and a
live membership/camera-grant resolver. The route returns `service_unavailable`
when that runtime is not configured. No physical camera, NVR, clip playback or
provider interoperability result is claimed, and F41 progress remains open.
