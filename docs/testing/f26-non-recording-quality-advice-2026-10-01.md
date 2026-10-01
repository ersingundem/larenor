# F26 non-recording quality advice — 2026-10-01

## Problem and contract

The catalog quality panel previously called the consumable
`observe-item` endpoint. Every advisory refresh therefore occupied one of the
32 short-lived playback-observation slots for that account. A burst of panel
mounts, retries, lifecycle resumes, or HTTP responses arriving after a Client
timeout could temporarily prevent the user's explicit Play action from
obtaining its own observation.

`POST /api/v1/media/playback-quality/{coreId}/{homeId}/assess-item` now accepts
the same closed request and client-reported local profile as `observe-item`.
It performs the same current actor, Core/home, installation, snapshot,
Jellyfin service, item, media key, provider readback, profile digest, and
post-read authority checks. Its closed response is exactly:

```text
schemaVersion, requestId, authority, observation
```

There is deliberately no `observationId`. The route does not retain or
consume a playback observation, lease, grant, download, or durable record.
`observe-item` remains unchanged and is used only when an explicit Play action
needs a one-use observation for lease creation.

## Focused evidence

The initial route test was RED with HTTP 404 before implementation. The final
focused command was:

```text
cd server
PYTHONPATH=. .venv/bin/pytest -q \
  tests/test_f26_non_recording_quality_assessment.py \
  tests/test_f26_playback_quality_api.py
```

The gate covers the closed response, absence of private provider fields,
extra-field rejection, expired and retired sessions, stale binding rejection,
post-provider authority drift, and preservation of the existing consumable
route.

The focused agent gate passed 12 tests. Root independently ran the new
assessment module, existing F26 API, online lease, offline API, Jellyfin
offline worker, playback executor and unified preference-store modules
together with explicit process-exit checking: **46 passed**, exit 0. Pinned
Ruff 0.14.1 passed on the three production modules and new test file. These
software checks do not establish exact-HEAD broad CI acceptance.

One normal-Core test sends 33 assessments through an actual owned loopback TCP
Jellyfin-shaped endpoint and the production `JellyfinPlaybackProtocol`. It
verifies that the server observation pool stays empty, then obtains one
explicit consumable observation and creates a Core-bound playback lease. The
test confirms the explicit observation is removed by the lease CAS and that
all 34 provider reads crossed the loopback endpoint.

## Limits

This is API, authority, provider-protocol, and capacity evidence. The loopback
test uses an owned in-process worker seam around the production Jellyfin wire
parser; it does not prove an installed host worker, a household Jellyfin
server, native playback, receiver compatibility, or physical audio/video.
Those acceptance boundaries remain separate.
