# F60 owned input, OSC gamepad and remote-disconnect Android gate (2026-10-01)

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
3. Android explicitly enables Moonlight's existing scoped on-screen controller
   preference for this fixture. It requires `onlyL3R3=false` and
   `flipFaceButtons=false`, verifies the complete visible source-locked default
   controller class order, and dispatches touchscreen down/up events to the
   first `DigitalButton`, which is the default A button. The host arms first and
   accepts only an exact newly owned libvirtualhid Xbox Series evdev node whose
   `BTN_SOUTH` down/up events and synchronization reports are observed. A
   submitted Moonlight packet alone is not evidence.
4. The first lifetime performs the ordinary causal local stop and receives
   `connectionStopped`.
5. A distinct second session revision launches and again proves
   `connectionStarted`, a rendered frame, and a full PCM write.
6. The host records the paired client as present and then terminates the exact
   owned Sunshine daemon, not merely its launched application child. Android
   accepts only `LarenorMoonlightGame.connectionTerminated` for the exact
   second lease; graceful stop, task destruction, child absence, and timeout do
   not satisfy this step.
7. Android retires the exact second session and performs the already supported
   local retirement readback. Sunshine remote pairing removal remains false;
   the provider was deliberately stopped before that local cleanup.

## Evidence state

The OSC setting is written through the same private `MoonlightScopedContext`
namespace as the bound authority before the first Game launch. The fixture
captures the prior values and restores them in its outer `finally` path. It
does not change Moonlight's production default, which remains disabled.

The process-private terminal witness stores only the exact session/revision,
terminal state, observation kind, and monotonic readback revision. A stale
Game token cannot mutate or satisfy a successor lease. The localhost control
protocol is fixed to port 49362, schema 1, the run nonce, exact phase names, a
512-byte message bound, and finite connect/read deadlines. After the pointer
proof, its gamepad exchange is exactly `gamepad_ready` -> `gamepad_armed` ->
`gamepad_sent` -> `gamepad_observed`; the first stream is not stopped before
that causal host observation.

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

The OSC extension was compiled separately against the same canonical
source-locked AAR (`d327a45c...36c5`) and receipt (`fe08b7d6...9f5`) with
`:app:compileDebugAndroidTestKotlin -x compileFlutterBuildDebug`; the build
completed successfully. This establishes Kotlin/package compatibility only.
It does not replace the required owned UHID/evdev hosted observation.

The resulting receipt scope is `moonlightOnScreenController`: it proves the
shipped OSC view path reached the owned Sunshine virtual controller and
produced the exact host `BTN_SOUTH` effect. It does not prove a Bluetooth or
USB controller, rumble, game consumption, perceived latency, image quality,
or audible sound. This slice also does not claim provider-admin unpair support.

The pinned sources that define this boundary are:

- Moonlight default OSC construction and A-button order:
  <https://github.com/moonlight-stream/moonlight-android/blob/b48494cb96bff23d8886c4775cc4f39a1075495d/app/src/main/java/com/limelight/binding/input/virtual_controller/VirtualControllerConfigurationLoader.java>
- Moonlight scoped preference defaults and keys:
  <https://github.com/moonlight-stream/moonlight-android/blob/b48494cb96bff23d8886c4775cc4f39a1075495d/app/src/main/java/com/limelight/preferences/PreferenceConfiguration.java>
- Sunshine's exact UHID and owned evdev permissions:
  <https://github.com/LizardByte/Sunshine/blob/v2026.914.233613/src_assets/linux/misc/60-sunshine.rules>
- Linux UHID userspace-driver contract:
  <https://docs.kernel.org/hid/uhid.html>
