# F44 camera visual sensor Core foundation

Status: **software foundation delivered; F44 remains pending**

This slice accepts bounded detector metadata only. Raw frames, bounding boxes,
embeddings, camera credentials and biometric identity do not enter its public
or stored contracts. It does not register a camera provider or claim physical
camera accuracy.

## Three acceptance criteria

1. **Exact visual authority.** Every batch is tied to the current Core, home,
   home revision, admin account, membership, session family, camera, pipeline,
   model and rule revisions. Foreign cameras, stale authority, changed rules,
   expired evidence and out-of-order captures fail closed before state changes.
2. **Verified hysteresis and explicit degradation.** Confidence thresholds,
   activation hold and clearing delay reduce one-frame noise. A degraded
   detector produces an explicit `unknown` reading, cannot authorize an
   automation transition and breaks the continuous evidence interval. A later
   ready batch must establish a fresh hold period.
3. **Single-effect, private evidence.** Exact request replay returns its saved
   receipt; changed replay is rejected. A keyed append-only audit chain covers
   authority, request fingerprint, transition and evidence digest. Public
   projections contain only bounded sensor metadata and never include the
   session, raw media type, image bytes, boxes, embeddings or audit key.

## TDD evidence and remaining work

- RED `10cfc667`: four authority, hysteresis, degradation, replay, privacy and
  tamper scenarios failed because the module did not exist.
- GREEN `7b664e97`: all four focused scenarios pass using synthetic metadata
  and no production account, camera, image, provider or secret.

The private detector worker, encrypted durable store, authenticated HTTP route,
Home Assistant entity projection, Client surface, provider calibration,
Client-to-Core E2E and physical camera validation remain open. Queue progress
does not change for this foundation.
