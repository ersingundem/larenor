# F42 private event sharing production evidence

Date: 2026-09-30

## Supported production boundary

F42 uses the configured Frigate camera source through the normal Core camera-search
runtime. Core seals the exact camera/event evidence into its private F41 binding,
stores that opaque binding encrypted, and rechecks the current Core account, home,
camera source, registry and profile authority before reading a clip. The native
Frigate event identifier and credentials are never returned by the F42 API.

Frigate documents `GET /api/events/{event_id}/clip.mp4` as an authenticated request
whose caller must have access to the referenced camera:

- https://docs.frigate.video/integrations/api/event-clip-events-event-id-clip-mp-4-get/
- https://docs.frigate.video/configuration/authentication/

The only supported privacy transform is a fixed full-frame blur. It does not detect,
locate or identify faces or license plates. The API reports
`targetedRecognition: false` and `coversEntireFrame: true`; configured mask names are
consent requirements for the whole-frame transform, not detector claims. If the
paired FFmpeg and ffprobe paths are absent, source authorization is unavailable, or
the transform cannot be proven, preview and share creation fail closed.

The production container must install FFmpeg and configure both
`LARENOR_PRIVATE_EVENT_FFMPEG=/usr/bin/ffmpeg` and
`LARENOR_PRIVATE_EVENT_FFPROBE=/usr/bin/ffprobe`. The committed `server/Dockerfile` packages the binary/library pair and sets
both variables; exact image-build validation remains part of the final CI gate. Non-container deployments may configure other absolute executable
paths. Supplying only one binary is rejected during Settings construction; supplying
neither keeps sharing policy and historical redemption available while new
transformations report unavailable.

FFmpeg documents `boxblur` as an image-plane blur and documents negative metadata
and chapter mappings as the way to disable automatic copying. ffprobe documents
stream, format and chapter inspection and `-count_frames`:

- https://ffmpeg.org/ffmpeg-filters.html#boxblur
- https://ffmpeg.org/ffmpeg.html
- https://ffmpeg.org/ffprobe.html

The worker writes the source into an owner-only temporary directory, maps one video
stream and optional audio, drops subtitles/data/attachments, removes global metadata
and chapters, and produces a new MP4. It then requires one bounded video stream,
matching dimensions, matching decoded frame count, bounded duration drift, no
chapters, no disallowed output stream, a changed digest, and a successful full
FFmpeg decode. The encrypted artifact store uses a separate AES-GCM key domain plus
authenticated row metadata; plaintext media is not persisted in SQLite.

Before frame counting or decoding, a header-only probe rejects dimensions above
4,096 pixels on either axis, pixel area above 4,096 by 2,160, duration above 60
seconds, rates above 60 frames per second, and more than four streams. Counted input
is then limited to 3,602 frames, and only the first optional audio stream is mapped.
Every FFmpeg/ffprobe invocation uses the local `file,pipe` protocol whitelist and a
64 MiB single-allocation ceiling. One nonblocking admission slot serializes redaction.
Subprocess stdout and stderr are drained concurrently into fixed 1 MiB and 256 KiB
buffers; overflow, timeout, or durable authority drift kills the whole process group.
The in-process guard rechecks account, family, home, member, binding, share and policy
facts while the process runs. Exact token and live camera authority are checked again
by the request integration after media I/O because the worker authority intentionally
contains no bearer token or native camera identity.

Output verification also rejects every format or stream metadata tag outside a narrow
set of technical MP4 muxer tags. This makes the metadata-removal receipt depend on the
probed artifact rather than only on the requested `removedMetadata` labels.

## Authority, consent and lifecycle

- An administrator explicitly configures grantors, recipients, purposes, access
  modes, maximum TTL, required masks and removed metadata through the bounded F42
  policy endpoint.
- The Flutter flow reads the current bounded Core user list. It selects an exact
  recipient, writes the policy with the current administrator as grantor, and shows
  the full-frame capability statement before enabling consent. There are no manual
  consent or recipient identifiers.
- Preview remains disabled until the user enables the explicit consent switch and
  Core returns a consent receipt for the exact recipient, purpose, duration,
  access mode, whole-frame coverage labels and metadata removal set.
- Consent binds the current Core/home/account/member/camera/event/session/share and
  policy revisions. Share creation rechecks both authority and consent after media
  I/O before journal mutation.
- Preview and new share creation require the live F41 source binding and exact event
  clip. Existing shares remain redeemable after the Frigate event is removed because
  their encrypted artifact and audit receipt are already durable.
- Redemption still requires current Core membership and recipient scope. Revocation
  advances the authenticated F42 journal and subsequent redemption returns not found.
- Policy, opaque evidence bindings, consent and encrypted artifact rows are bounded,
  HMAC/AEAD authenticated at startup, and use strict paired schema ownership. Unknown
  `private_event_share*` objects still fail startup.

## TDD evidence

The regression tests were written to expose two failures before the fixes:

| Guarantee | RED evidence | GREEN evidence |
|---|---|---|
| A transform with a mismatched output duration is rejected | `test_encrypted_policy_artifact_and_real_full_frame_redaction` completed without raising | The same test rejects the modified ffprobe duration with `transformation_unverified` |
| Expired encrypted artifact rows remain authenticated during startup validation | Corrupt expired ciphertext was treated only as unavailable and skipped | `validate_storage()` now raises `private_event_share_provider_storage_invalid` |
| A small container cannot declare an allocation-heavy frame before bounds apply | Frame counting preceded dimension validation and allowed independent 8,192 axes | Header-only probing rejects excessive pixel area before the counted probe runs |
| Child output and revocation cannot leave an unbounded FFmpeg process | `subprocess.run` buffered both pipes until exit and had no mid-process authority guard | Selector-capped pipes and the durable authority guard terminate the process group |
| A receipt cannot claim metadata removal while sensitive tags remain | Only requested labels were copied into the receipt | The probed artifact rejects non-technical format and stream tags |

Final focused command:

```text
server/.venv/bin/pytest -q \
  server/tests/test_f42_private_event_provider.py \
  server/tests/test_f42_private_event_sharing.py \
  server/tests/test_f42_private_event_normal_core.py \
  server/tests/test_f41_private_event_binding.py
```

Result: `18 passed`. Coverage includes a real local Frigate HTTP/WebSocket fixture, real
FFmpeg/ffprobe execution against `f41_clip.mp4`, pixel-level whole-frame change on all
10 frames, encrypted-at-rest inspection, Core restart after source deletion,
download, revoke, strict schema coexistence, and F41 binding restart regressions.

Additional checks:

```text
server/.venv/bin/python -m compileall -q \
  server/larenor_server/private_event_sharing \
  server/larenor_server/config.py server/larenor_server/core.py \
  server/tests/test_f42_private_event_provider.py \
  server/tests/test_f42_private_event_normal_core.py
git diff --check -- <F42 allowlist>
```

Result: both passed. The server dependency set has no configured Python coverage
plugin, so no percentage is claimed; the named unit, integration, real-process and
restart guarantees above are the acceptance evidence.

Flutter focused command:

```text
flutter analyze \
  lib/features/private_event_sharing \
  test/features/private_event_sharing/private_event_share_core_loopback_test.dart \
  test/features/private_event_sharing/private_event_share_screen_test.dart \
  test/features/private_event_sharing/private_event_share_normal_core_test.dart
flutter test \
  test/features/private_event_sharing/private_event_share_core_loopback_test.dart \
  test/features/private_event_sharing/private_event_share_screen_test.dart
```

Result: analysis reported no issues and all 4 tests passed. The widget test proves
that a preview cannot start before explicit consent. The client loopback test proves
the bounded policy, user, consent, preview, create, download and revoke wire formats.

Actual client acceptance command:

```text
server/.venv/bin/python server/tests/support/f42_flutter_acceptance.py
```

Result: passed. The runner starts normal Core with the production F42 provider,
connects it to the real TCP Frigate fixture, executes the real Flutter account client,
configures policy and consent, reads the fixture MP4, transforms and fully verifies it
with local FFmpeg/ffprobe, creates the encrypted share, and downloads the transformed
MP4. No Core F42 callback is replaced. `flutter gen-l10n` was run once; generated
localization sources remain intentionally ignored by the repository.
