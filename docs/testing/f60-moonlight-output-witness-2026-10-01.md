# F60 Moonlight rendered-frame and accepted-PCM witness — 2026-10-01

## Evidence boundary

The pinned Moonlight renderer now installs Android's
`MediaCodec.OnFrameRenderedListener` on API 23 and newer independently of the
upstream latency-statistics flag. A witness is produced only from that Android
callback. Releasing an output buffer, incrementing Moonlight's submitted-frame
statistics, `connectionStarted`, or Activity visibility is not a rendered-frame
witness. Android documents the callback as notification that an output frame
rendered on the configured surface, and also warns that callbacks can be
delayed, batched, or omitted:
<https://developer.android.com/reference/android/media/MediaCodec#setOnFrameRenderedListener(android.media.MediaCodec.OnFrameRenderedListener,%20android.os.Handler)>.

The pinned audio renderer now checks the return from its existing blocking
PCM `AudioTrack.write(short[], ...)` call. It produces an accepted-PCM witness
only when the return is positive and equals the full requested sample count.
Zero, negative error results, short writes, and audio dropped by Moonlight's
pending-duration guard produce no witness. Android defines the return as the
amount actually written and explicitly permits short or error results:
<https://developer.android.com/reference/android/media/AudioTrack#write(short[],%20int,%20int,%20int)>.

These are software output observations. A frame callback does not prove image
quality, latency, HDR correctness, or sustained playback. A successful PCM
write does not prove physical audibility, speaker routing, volume, or fidelity.
Those remain physical/manual evidence.

## Lease and privacy rules

`LarenorMoonlightGame` forwards the callbacks with its process-private launch
token. `MoonlightForegroundLeaseRegistry` accepts them only when that exact
lease is `GAME_VISIBLE`, has an Activity, has observed `connectionStarted`, and
has not begun local stop. Retiring, destroyed, stopped, stale-token, and
successor-lease callbacks are ignored.

The registry retains at most one rendered-frame witness and one full PCM-write
witness for the current exact session/epoch. Repeated callbacks do not grow
state or enqueue observer events. No pixel, PCM, presentation timestamp,
address, credential, or certificate is retained, logged, or sent to Core.
The private snapshot exists only as foundation for the future owned-Sunshine
instrumentation gate.

## Focused verification

The package verifier requires all four source facts before it will build:

- the listener is installed even though upstream `USE_FRAME_RENDER_TIME` is
  false;
- the listener calls the Game frame hook;
- the PCM write return is captured; and
- only a positive full write calls the Game audio hook.

The native lease regression proves pre-connection callbacks are rejected,
positive witnesses saturate at one, zero/short PCM writes are rejected, no
public lease observer event is emitted, retirement rejects late callbacks, and
an old lease cannot affect its successor.

The source package was rebuilt from pinned Moonlight commit
`b48494cb96bff23d8886c4775cc4f39a1075495d` and source-lock patch SHA-256
`fecdb1c3f37b9f52eedb8186c59029a54e8d2b241d4291a762ccb34a5ec18bed`.
`verify-install` accepted the fresh arm64-v8a/x86_64 AAR with SHA-256
`d327a45cb669afc4a9b6bfe9ee70406471c29ab6cab546cef6554500531336c5`.
The package unit suite passed 7/7.

With that exact AAR installed, production Kotlin and AndroidTest Kotlin
compiled. `MoonlightEmbeddedRuntimeTest` passed 29/29 with zero skips,
failures, or errors. A combined native run also passed the three current RDP
classes (17/17); that count is integration evidence only and does not claim an
RDP host session. The resulting debug APK passed both package verifiers and had
SHA-256 `4aca312dcec9f6f05e87cbfd40945dc1b7749d630a2b188a3aa5055849760973`.

These package and JVM gates prove the transformed hooks, exact lease fencing,
and APK linkage. They do not prove that an owned Sunshine stream produced a
frame or PCM write; that provider-facing instrumentation gate remains pending.
