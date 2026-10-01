# F26/F27 Android local-playback capability boundary — 2026-10-01

## Contract

The adapter obtains a fresh Android snapshot immediately before the F26
provider observation and reads it again after the response. A later F27 lease
caller must revalidate the same profile before consuming the opaque,
single-use observation ID. Revalidation also requires the exact captured
account generation and `ServerSession` identity; signing out or rotating the
session cannot reuse an otherwise identical device profile.

The native snapshot binds three independent, nonzero JavaScript-safe content
revisions:

- the current `Activity` display ID/mode, physical dimensions, refresh bits
  and Android `HdrCapabilities` types;
- the sorted decoder MIME presence list and truncation state; and
- the active Android `Network` handle plus sorted transports, validated,
  metered and link-capability estimate fields.

The active network handle never crosses the MethodChannel. It only prevents a
replacement network with identical public flags from reusing the old opaque
revision. The native owner generation makes Activity replacement a revision
change. Display and network are reread before a snapshot is published; drift,
missing facts, Activity retirement or decoder-list truncation fails closed.

Flutter maps only known decoder MIME presence to codec tokens. This remains
`client_reported`: it does not claim decoder profile/level, hardware
acceleration, successful HDR presentation, measured throughput or physical
playback. The explicit software policy currently advertises only the `mp4`
container, no subtitle formats, and a 20 Mbps request ceiling. Those policy
facts receive their own deterministic revision.

F26 must return a current opaque `observationId` with
`provider_observed_for_client_reported_profile` and
`direct_play_supported`. Remux, transcode, unavailable, unknown, malformed,
expired, cross-authority or locally drifted results never authorize F27. The
server consumes that ID once when creating the exact original-byte lease;
the Client never echoes an outcome as authority.

## Focused evidence

- Native observer tests bind stable facts, owner replacement and active
  network identity to bounded revisions; they also prove display/network drift
  within one observation returns no snapshot and no raw network handle or
  hardware/HDR-success claim is published.
- Flutter tests cover conservative profile construction, exact F26 request and
  authority parsing, post-response native revalidation, direct-play-only
  authorization, session retirement, and fail-closed truncated/malformed
  evidence. The focused Flutter file passes 4 tests and scoped analysis is
  clean.
- The focused Android gate passes 6 tests (4 observer and 2 existing bridge
  regressions), with zero skips, failures, or errors.

Root independently reran the Flutter capability file (4/4) and the real
required-native Android gate (6/6, zero skips/failures/errors), including
`:app:compileDebugAndroidTestKotlin`. The actual changed bridge and observer
compile together with both packaged native engines. This is local source and
compilation evidence, not physical video/audio acceptance or hosted final CI.

This slice does not enable the frozen online Play button by itself. The final
player integration must perform F26 observation, revalidate, pass the opaque
ID to F27 immediately, and retain all existing route/account/session/source
retirement fences.
