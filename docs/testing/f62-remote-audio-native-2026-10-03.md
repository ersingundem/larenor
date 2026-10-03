# F62 remote-audio native contract — 2026-10-03

Status: schema 3 source, real dual-ABI package, and native/AndroidTest
compilation passed locally. The owned-host PCM effect receipt remains required
before actual remote-audio acceptance.

## Production boundary

- The receipted package identity is
  `freerdp-3.31.1-63b948ca-display-pointer-audio-v3` with JNI schema 3.
- A connection with `audio: true` supplies `/audio-mode:0` and
  `/sound:sys:opensles`. A connection with `audio: false` supplies
  `/audio-mode:2` and does not load a sound device.
- The source-locked OpenSL observer reports only an exact FreeRDP instance,
  `deviceOpen`, JS-safe cumulative accepted/completed counters, and one of five
  fixed lifecycle states. No PCM bytes, provider identifiers, credentials, or
  raw native errors cross JNI.
- OpenSL is opened by the first server Wave/Wave2 payload. Therefore an
  authenticated audio-enabled session legitimately begins at
  `pending`, `deviceOpen: false`, counters `0/0`.
- Buffer acceptance means the exact owned buffer was queued successfully.
  Playback is observed only after `completedCount` increases from the OpenSL
  buffer-completion callback. WaveConfirm and accepted-only states are not
  playback evidence.
- `closed` is a nonterminal device/format lifecycle and can reopen with the
  same monotonic per-instance counters. `failed` is terminal. Teardown STOP,
  Clear, and callback quiescing do not increment completion.
- Counters retain the JS-safe maximum. The next real accepted/completed effect
  after that bound emits `failed` with the retained counters and retires the
  current operation; it is never represented as an identical new receipt.

Kotlin stages callbacks privately before authentication and publishes them
only through the exact current, foreground, audio-enabled session. Duplicate,
stale-instance, retired, regressing, malformed, or successor callbacks cannot
create a public effect. The read-only `audioObservation` query performs no JNI
I/O and never retries or replays audio.

Generic `RdpJniChannel.AUDIO` payload submission remains rejected. rdpsnd is a
connection-time channel, not an arbitrary byte-injection API.

## Focused source proof

Focused tests cover:

- schema 3 package identity and exact callback constants;
- explicit enabled/disabled URI arguments;
- authenticated pending `0/0`, accepted-only waiting, and completed playback;
- close/reopen with cumulative counters, duplicates, counter regression,
  native failure, exact-instance retirement, and disabled audio;
- foreground/current request binding and non-retiring `channelUnavailable`
  for an audio-disabled observation query;
- zero generic-audio payload dispatch.

The package patch binds the callbacks to the pinned FreeRDP 3.31.1 source at
commit `63b948ca5cb94307fd5444ee6e73927a41ccdab4`. Its OpenSL queue increments
accepted only after successful `Enqueue`, increments completed only when the
registered callback removes an accepted buffer while not closing, and emits a
closed snapshot only after the close sequence.

## Remaining acceptance

The source tests do not prove speaker output, human-audible sound, Windows
audio policy, volume, latency, or physical-device routing. The owned-host gate
must establish one authenticated pending baseline, arm one nonce-bound PCM
effect, observe a completion delta of at least one, and prove the disabled
second lifetime has no audio effect. Physical Windows and Huawei/DeX routing
remain separate device acceptance boundaries.

## Root integration gate

Root mounted the independently verified schema-3 pair into the required-mode
product. All **56 RDP JVM tests** passed with zero failures/errors/skips,
including the exact compiled callback constants, explicit OpenSL URI, audio
observation and lifecycle gates, keyboard, pointer, display and bridge tests.
The shared integration invocation also passed 47 Moonlight JVM tests (103 total)
and `compileDebugAndroidTestKotlin`. These are local source/package gates, not
NLA-host or physical sound evidence.

The first new URI test incorrectly used the plain Android JVM stub and failed
with `Uri.Builder not mocked`; root configured it with the existing Robolectric
SDK-35/Application fixture and reran the affected combined gate successfully.
Production URI behavior and acceptance conditions were unchanged.

Private gate log SHA-256:
`82d93a60fe816629fcbd04a64c0b8c34d7990cfbc57993e36d1031b1318098c4`.
The 18-source integration manifest SHA-256 is
`5ff6866f70f6f6503b04326237e70cbfd86e6e7d884270d74cfcb6d563211fa2`.
