# F26 Core playback information observation — 2026-10-01

## Production boundary

Verified Core now sends one bounded, read-only Jellyfin
`POST /Items/{itemId}/PlaybackInfo` request through the existing installation
worker IPC. The request binds the current account and session family, home,
installation, archive snapshot, Jellyfin service, item, and a canonical local
Client profile. The profile is explicitly `client_reported`; Core does not
promote Android display, decoder, network, or policy facts into provider proof.

The public result is advisory and expires after 30 seconds. It includes only
sanitized source and transcoding facts. It never includes the Jellyfin URL,
API key, user id, media source id, play session id, path, or transcoding URL.
Core also returns one opaque `observationId` backed by a bounded, process-memory
record. The Client cannot echo a claimed outcome: F27 consumes that ID only
when the stored outcome is `direct_play_supported` and every bound authority
field still matches.
Pre- and post-read guards reject actor, family, installation, snapshot, service,
item, bootstrap, or endpoint drift before an observation is published.

Only `originalByteOutcome=direct_play_supported` establishes compatibility
between the exact client-reported profile and the original `/Download` bytes.
`requires_remux`, `requires_transcode`, `unavailable`, and `contract_unknown`
must not be used to open the F27 original-byte Core lease. Multiple media
sources and an original-byte length mismatch are reported as unknown rather
than selecting a source or estimating compatibility.

## Upstream contract reviewed

- Jellyfin's generated `PlaybackInfoDto` defines `UserId`, `DeviceProfile`,
  `MaxStreamingBitrate`, and the direct-play/direct-stream/transcode switches:
  <https://typescript-sdk.jellyfin.org/interfaces/generated-client.PlaybackInfoDto.html>
- `DeviceProfile` defines the direct-play, transcoding, codec, subtitle, and
  bitrate capability description used for negotiation:
  <https://typescript-sdk.jellyfin.org/interfaces/generated-client.DeviceProfile.html>
- `PlaybackInfoResponse` defines `MediaSources`, `ErrorCode`, and private
  `PlaySessionId`; Core deliberately discards the latter:
  <https://typescript-sdk.jellyfin.org/interfaces/generated-client.PlaybackInfoResponse.html>
- `MediaSourceInfo` defines `SupportsDirectPlay`, `SupportsDirectStream`,
  `SupportsTranscoding`, `Size`, streams, and private source/URL fields:
  <https://typescript-sdk.jellyfin.org/interfaces/generated-client.MediaSourceInfo.html>

## Focused evidence

The focused Python suite covers the exact authenticated POST body, deterministic
single-source selection, direct-play/remux/transcode outcomes, multiple-source
and byte-length uncertainty, endpoint proof, private Unix IPC roundtrip, normal
Core catalog binding, and post-read authority drift. These tests use an owned
Jellyfin-shaped TCP response and bounded worker fixtures; they do not establish
physical decoder success, visual/audio acceptance, or a real household server.

Run:

```text
PYTHONPATH=server server/.venv/bin/python -m pytest -q \
  server/tests/test_f26_playback_quality_api.py \
  server/tests/test_jellyfin_playback_runtime.py \
  server/tests/test_jellyfin_playback_executor.py \
  server/tests/test_media_playback_installation_ipc.py \
  server/tests/test_media_playback_worker_provider.py
```

The final combined F26/F27 provider, IPC, normal-Core, and legacy playback
scope collected and passed 86 tests. Ruff passed the exact changed Python
allowlist (with only the repository's pre-existing E731/F811 exclusions), and
the changed production modules compiled successfully. No provider or household
mutation is performed by this gate.

Root independently reviewed the final negotiation and observation boundary.
Five new cases first failed, then passed after the following repairs:

- H264/AAC HLS output is advertised only when both decoders are present in
  the exact client-reported profile. A provider transcoding boolean or output
  outside that advertised profile remains `contract_unknown`.
- The observation expiry is checked again under the final consuming lock
  after database and current-authority checks; crossing the inclusive 30-second
  boundary cannot issue a lease.
- Serialized lease creation checks capacity before consuming the observation.
  A 429 can be retried with the same still-current observation after capacity
  is retired, while a consumed ID cannot issue a second lease.

Root's six-file provider/IPC/F26/F27 gate passed 64 tests, with no skips.
The official `DeviceProfile` contract explicitly describes containers and
codecs for direct playback and transcoding output; this software observation
still does not establish physical decoder/profile/level or household playback.
