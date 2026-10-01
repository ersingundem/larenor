# F60 owned input and remote-disconnect Android gate (2026-10-01)

## Scope

This slice extends the opt-in, owned-Sunshine Android instrumentation gate. It
does not turn a connection-start callback, submitted decoder buffer, child
process exit, or Activity destruction into playback or disconnect evidence.

The exact named case is
`MoonlightOwnedSunshineStreamTest.productionNsdPairCatalogTwoStreamLifetimesTouchStopDisconnectAndLocalRetirement`.
It uses production NSD, pairing, catalog, launch, `LarenorMoonlightGame`, and
Moonlight transport paths. The private host orchestrator and Android test share
only a one-use nonce over a bounded localhost channel; coordinates, provider
identifiers, pixels, PCM, PIN, and credentials are not public receipt fields.

## Required causal sequence

1. The first lifetime must report `connectionStarted`, one real
   `MediaCodec.OnFrameRendered` witness, and one full positive `AudioTrack`
   write. It sends the existing A-key event through `Game.dispatchKeyEvent`.
2. The host arms its owned XI2 pointer/button observer before Android sends a
   touch sequence and relative mouse motion/button events through the real Game
   dispatch methods. Android cannot continue until the host reports the exact
   pointer/button effect.
3. The first lifetime performs the ordinary causal local stop and receives
   `connectionStopped`.
4. A distinct second session revision launches and again proves
   `connectionStarted`, a rendered frame, and a full PCM write.
5. The host records the paired client as present and then terminates the exact
   owned Sunshine daemon, not merely its launched application child. Android
   accepts only `LarenorMoonlightGame.connectionTerminated` for the exact
   second lease; graceful stop, task destruction, child absence, and timeout do
   not satisfy this step.
6. Android retires the exact second session and performs the already supported
   local retirement readback. Sunshine remote pairing removal remains false;
   the provider was deliberately stopped before that local cleanup.

## Evidence state

The process-private terminal witness stores only the exact session/revision,
terminal state, observation kind, and monotonic readback revision. A stale
Game token cannot mutate or satisfy a successor lease. The localhost control
protocol is fixed to port 49362, schema 1, the run nonce, exact phase names, a
512-byte message bound, and finite connect/read deadlines.

The focused local native regression verifies that a terminal witness is absent
before a real terminal callback, records `connectionTerminated` for the exact
lease, and remains absent on its successor after late callbacks from the old
token. The owned hosted gate is still required before this feature can claim
the input or remote-disconnect acceptance evidence.

Root independently verified the canonical AAR/receipt compilation result:
production Kotlin and AndroidTest Kotlin compiled, and the exact
`MoonlightEmbeddedRuntimeTest` XML reports 33 tests with zero failures, errors,
or skips. This local result proves the terminal-witness regression and package
linkage; the new two-lifetime hosted method has not yet passed.

Physical controller behavior, perceived latency, image quality, and audible
sound remain manual device checks. This slice does not claim provider-admin
unpair support.
