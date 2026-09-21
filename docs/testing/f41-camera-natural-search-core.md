# F41 camera recording search Core foundation

This slice defines a local, read-only metadata search boundary. It does not send
camera metadata, clips, evidence identifiers, account facts, or home facts to a
provider. An optional semantic planner receives only the bounded query text; if
it is absent, fails, or returns an invalid plan, the response explicitly reports
`local_metadata`, `degraded`, and `semantic_provider_unavailable`.

## Acceptance criteria

1. **Exact local scope and evidence.** Search validates the live account
   authority before planning, limits every result to the exact Core, home,
   allowed camera set and 31-day time window, and returns an internal evidence
   link bound to clip, event, camera, capture revision, index revision and
   timestamp. Private evidence is visible only to its owner or an explicitly
   authorized administrator. A removed record is absent from the next immutable
   index revision.
2. **Bounded, revision-bound pagination.** Results are deterministic and capped
   at 50 per page. Opaque authenticated cursors are bounded in memory and bind
   the request, authority, page size, resolved query plan and index revision.
   Changed scope, query or authority is rejected; an old index revision returns
   `revision_conflict`; a repeated cursor reads the same immutable page without
   re-running the semantic planner.
3. **Fail-closed contracts and graceful degradation.** Closed Pydantic models
   bound identifiers, text, labels, cameras, records and time spans. Missing,
   inactive, stale or failed authority resolution stops before planning, an
   unauthorized camera is indistinguishable from a missing one, and planner
   exceptions never cross the boundary. Local normalized Turkish/English
   metadata matching remains available without a provider or LLM.

## Evidence and remaining gates

The focused pytest suite covers local and semantic-assisted search, EN/TR text
normalization, home/camera/time/privacy scope, authority failure order, deleted
snapshot behavior, deterministic pagination, cursor tampering and secret-free
projection. This foundation intentionally does not register an HTTP route or
claim camera-provider discovery, clip playback, correction feedback, Android
Client-to-Core E2E, or physical camera validation. F41 remains open until those
queue acceptance gates and its F43/F08 dependencies are proven. Queue progress
therefore remains **21/125 (16.8%)** and selected-feature progress remains
**0/63 (0.0%)**.
