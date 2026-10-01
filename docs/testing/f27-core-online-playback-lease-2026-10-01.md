# F27 Core-bound online playback lease evidence — 2026-10-01

## Scope

Verified-Core catalog items can be opened through a short-lived Core lease
without exposing a Jellyfin URL, API key, service record, or private worker
plan to the Client. The lease reuses the existing authenticated
`read_offline_media_chunk` worker operation. Each private operation remains at
most 32 KiB; the HTTP response joins those bounded reads to serve one standard
single byte range.

The public metadata says `byteIntegrity: source_bound`. It does not claim that
the streamed bytes were verified against a whole-file digest. The archive
projection has no trustworthy MIME, codec, or transcoding result, so this
slice returns `application/octet-stream`. Create now requires a server-held,
one-use F26 observation ID. Core issues that ID only after an item-specific
Jellyfin `PlaybackInfo` read, and this lease accepts it only when the exact
client-reported profile produced `SupportsDirectPlay=true` for one media
source with the same original-byte length. Remux, transcode, multiple-source,
length-mismatch, unavailable, and unknown outcomes never create a lease.

## Authority and lifecycle

- Create binds the current account revision, session family, Core/home,
  installation revision, snapshot revision, Jellyfin service revision, item,
  media key, and profile digest. The Client sends only the opaque
  `playbackObservationId`; it cannot echo or promote a claimed outcome.
- Playback observations live in bounded process memory for 30 seconds. One
  current, exactly owned create attempt consumes the observation for its
  eligibility decision, including a truthful non-direct-play rejection. A
  successful lease create can then be replayed idempotently without a second
  provider observation. No request ID can reuse the consumed observation.
- Every 32 KiB read checks that authority before and after worker I/O. A late
  worker result is discarded when authority changes.
- Renewal is revision-CAS and idempotent by request ID. Retirement is likewise
  revision-CAS; after it completes, content reads do no worker I/O.
- Leases are process-memory records with a 120-second renewable lifetime. A
  Core restart makes the old content URL terminally invalid (HTTP 404); the
  Client must close playback and explicitly create a new lease. It must never
  fall back to direct-local credentials.
- GET and HEAD accept only one bounded `bytes` range. Multiple, malformed, and
  unsatisfiable ranges return 416 without worker I/O. A disconnected response
  stops scheduling further reads; the at-most-one in-flight worker read still
  has its own five-second deadline and post-read authority gate.

## Focused evidence

`server/tests/test_f27_online_playback_lease.py` crosses the normal Core HTTP
router using TestClient and an injected bounded chunk-readback fixture over independent create, HEAD, GET, renew,
retire, family-drift, restart-loss, expiry/range, pre-worker drift, and
post-worker drift cases. Existing offline download behavior remains covered by
`server/tests/test_f27_offline_media_api.py`.

Root independently passed all eight tests across these two files. The added
fresh `create_app(settings)` case creates a separate normal Core/service
instance against the same durable account and verifies that its predecessor's
lease returns 404 without reaching the old worker. This is a real new Core
instance test, not an operating-system process restart. The focused chunk
fixture is not an installed Jellyfin/provider acceptance run.

The focused lease tests additionally prove that a missing, expired,
cross-family, consumed, remux, or otherwise non-direct-play observation cannot
create a lease. A fresh Core object cannot recover an observation from its
predecessor; the Client must request a new provider observation after restart.

This validates the HTTP and authority contract for Core-mediated original bytes. Playback on a
physical device, provider codec negotiation, subtitle/audio-track selection,
and remote Jellyfin progress reporting remain separate evidence boundaries.
F21/F24–F27 remain `reworking` until normal player composition and their full
software criteria are validated; this slice alone does not change queue status.
