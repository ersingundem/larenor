# F45 Frigate sound-event production gate — 2026-09-30

## Official source contract

- Home Assistant REST calls require bearer authentication and JSON responses. The
  camera binding remains the existing HA entity-registry-backed F41 source; F45
  never accepts a caller-supplied provider URL or credential.
  <https://developers.home-assistant.io/docs/api/rest/>
- Home Assistant recommends event entities for stateless occurrences. F45 does
  not reinterpret a binary sensor's current state, or the absence of a state, as
  a completed sound occurrence.
  <https://developers.home-assistant.io/docs/integration_events/>
- Frigate audio detection must be explicitly enabled and its `listen` labels
  configured. Audio detections create Frigate events. F45 verifies the effective
  per-camera `audio.enabled` and `audio.listen` values before saving and before
  every refresh.
  <https://docs.frigate.video/configuration/audio_detectors/>
- The bounded review list supplies exact review identity, camera, start/end and
  `data.audio`; every selected entry is reread through the exact review route
  before durable metadata is emitted.
  <https://docs.frigate.video/integrations/api/review-review-get/>
  <https://docs.frigate.video/integrations/api/get-review-review-review-id-get/>
- Frigate's MQTT audio status reports process-role status and explicitly does not
  mean camera reachability. F45 therefore does not claim listening success or
  silence from event absence or an MQTT `online` value.
  <https://docs.frigate.video/integrations/mqtt/>

## Implemented boundary

- The source is per account and binds an existing F41-authorized Frigate camera
  resource to an actual readable home room, exact resource revisions, explicit
  bark/noise label sets, consent revision and retention.
- Provider credentials stay in the existing encrypted service connection. The
  private F45 store contains references and consent only, is mode `0600`, and
  authenticates every configuration and status envelope.
- Consent revocation is a local exact-revision CAS operation. It does not need
  Frigate availability, advances the persisted consent revision, clears source
  status and immediately hides retained event metadata from history. Re-enabling
  still requires a fresh verified provider read.
- `GET /source` is a local-only metadata read. It returns the persisted camera,
  room, labels and exact CAS revision so an administrator can revoke consent
  after a cold restart while Frigate is offline. `POST /source/discovery` is the
  separate bounded provider read used for initial setup and re-enabling; the
  Flutter form cannot grant consent from the local metadata projection.
- Every status/history read with active consent revalidates the current account,
  F41 source permission and revision, exact camera mapping, room/camera resource
  revisions and current Frigate audio configuration. Revoked access or drift
  therefore cannot expose a previously `ready` status or retained event list.
- Refresh is read-only: authenticated `GET /api/profile`, `GET /api/config`, a
  bounded `GET /api/review`, and exact `GET /api/review/{id}`. No Frigate or HA
  mutation endpoint is called.
- Stored events contain only an opaque local ID, exact room/camera revisions,
  mapped class, categorical upstream-label presence, time/duration and a SHA-256
  digest of the exact review. Raw audio, clips, provider IDs and URLs are absent.
- `ready` requires a verified configured source and at least one actual mapped
  review in the bounded window. A healthy configuration with no review is
  `degraded`; stale refreshes become `stale`; all states keep
  `silenceProven=false` and `clipAvailable=false`.
- Review duration is accepted only from 100 ms through 60 seconds because that is
  the existing F45 event contract. Longer review aggregates are skipped rather
  than truncated or assigned an invented duration.

## Evidence

```text
server/.venv/bin/pytest -q \
  server/tests/test_f45_bark_noise_events.py \
  server/tests/test_f45_sound_events_api.py \
  server/tests/test_f45_frigate_normal_core.py

flutter test test/features/sound_events
flutter analyze lib/features/sound_events test/features/sound_events
server/.venv/bin/python server/tests/support/f45_flutter_acceptance.py
```

The acceptance runner starts normal `create_app`, provisions the existing
authenticated HA/Frigate service and registry path, then runs the production
Flutter client over TCP through source setup, explicit consent, exact review
refresh and verified metadata readback. Its provider assertion permits GET only.
