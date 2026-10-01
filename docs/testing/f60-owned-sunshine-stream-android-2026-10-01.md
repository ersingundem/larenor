# F60 owned Sunshine Android stream acceptance

Local validation of the retirement boundary: 33/33 Moonlight runtime unit tests
passed with zero skips/failures/errors, and AndroidTest Kotlin compilation
succeeded. This includes fence-first exact mapping removal, successor-authority
protection, legacy journal decoding, and transition/submission failure cleanup.
These checks prepare the owned stream gate; they do not prove a hosted stream.

This gate is the first F60 acceptance that requires the packaged production
Moonlight engine to complete its native provider lifecycle against a private,
pinned Sunshine process owned by the CI job. It does not use a household host,
an injected provider endpoint, a companion handoff, or a synthetic frame/audio
callback.

## Private control boundary

The Android test discovers Sunshine through production `_nvstream._tcp` NSD.
The only private test control is a one-use pairing PIN message sent to fixed
Android loopback port `49361`, which `adb reverse` maps to an ephemeral
host-loopback listener. The canonical message is bounded to 256 bytes and has
exact keys:

```json
{"schemaVersion":1,"nonce":"<64 lowercase hex>","pin":"<4 decimal digits>"}
```

The nonce is the only secret-free value passed as an instrumentation argument.
The PIN is never an argument, environment variable, file, log, test receipt, or
artifact. The host listener accepts one connection from loopback, validates the
exact nonce and schema, waits for the single real Sunshine pending pairing, and
approves only the pinned Moonlight client name `roth`.

## Native causal chain

`MoonlightOwnedSunshineStreamTest` exercises these production classes without
an endpoint fallback:

1. `MoonlightMdnsDiscovery` observes exactly one expected NSD instance on port
   47989. `MoonlightEmbeddedRuntime.discover` independently reads its real
   NvHTTP display, power and pair state.
2. The production `PairingManager` generates the PIN and completes certificate
   pairing. The test commits an in-memory Core-like opaque registration; raw
   host/app IDs, address and certificate remain in native scoped storage.
3. A separately authorized catalog observation reads the real NvHTTP catalog,
   and a second exact registration commit replaces the pairing generation.
4. Actual display, active-network route and Moonlight-selected decoder facts
   are intersected with an explicit PIN-required 2-frame/1-input policy. The
   exact selected quality is bound to one session.
5. An authorized `launch` performs NvHTTP launch and requires a
   `currentGameMatched` readback. An independently authorized `stream` launches
   the real `LarenorMoonlightGame` activity and requires its
   `connectionStarted` callback while the game is genuinely visible.
6. The exact bound session must observe both one real
   `MediaCodec.OnFrameRenderedListener` callback and one positive full
   `AudioTrack.write` result. The process-private accessor returns only bounded
   counters plus session identity; it never exposes the lease token, pixels,
   PCM, endpoint or credential.
7. The test dispatches an A key down/up through the real game activity. The
   owned host profile alone enables keyboard injection and independently
   requires the matching X11 input effect. Mouse and controller remain
   disabled; physical controller behavior remains a manual boundary.
8. Stop succeeds only after the source-locked post-`NvConnection.stop()`
   `connectionStopped` hook. The exact session is retired before local pairing
   cleanup. Native retirement deletes and independently reads back the scoped
   Moonlight computer and registration records before returning a causal
   `local_cleared` revision.

The host starts its owned tone only after Sunshine exposes the active stream
sink. A rendered callback proves compositor submission, and a full positive
PCM write proves Android accepted the complete decoded buffer. Neither proves
human-visible pixels, sound pressure, perceptual quality, latency, HDR quality,
or physical-controller behavior; those remain manual gates.

## Exact-session witness accessor

`MoonlightEmbeddedRuntime.outputWitness(authority, sessionId,
expectedSessionRevision)` captures the current lease token only after checking
the current authority and exact bound session. It releases the runtime lock
before reading `MoonlightForegroundLeaseRegistry`, preventing the registry
observer lock order from being inverted, then rechecks authority, session and
token before returning. A retired, replaced or stale session fails closed with
`authority_changed`.

## Named software gate

```text
com.ersingundem.larenor.game.moonlight.MoonlightOwnedSunshineStreamTest
  #productionNsdPairCatalogLaunchStreamWitnessStopAndLocalRetirement
```

The eventual public acceptance receipt may claim `streamAccepted: true` only
when the exact named Android test has one pass and zero skips/failures/errors,
and the host independently records all of: PIN approved, exact client paired,
stream sink observed, tone injected, A-key X11 effect observed, and exact local
computer/registration records absent. Package/source receipts and same-commit
workflow identity remain separate mandatory fields.

Pinned Sunshine does not expose a paired-client-authorized NvHTTP unpair route.
Its remote client removal API belongs to the separately authenticated web-admin
surface. The product action is explicitly **Remove from this tablet** and its
versioned Core/Dart terminal states are `local_cleared|unknown`; it tells the
user that Sunshine pairing remains. Automatic administrator deletion is an
optional separate capability, not a completion requirement silently added to
F60. Administrative fixture teardown is never product revocation evidence.
F60 remains reworking because named real streaming and the remaining software
input/disconnect acceptance have not passed, with physical controller/latency
and household-host validation tracked separately in MANUAL.

This source slice has not yet produced that hosted receipt. Compilation or a
passing local unit test does not promote F60 to provider acceptance.

## Local structural verification

The production and AndroidTest source sets compile together against the
receipted output-witness Moonlight AAR (`d327a45c...36c5`) and the receipted
FreeRDP AAR required by the combined app (`9fe2d1bc...e725`):

```text
cd android
./gradlew --no-daemon \
  :app:compileDebugKotlin \
  :app:compileDebugAndroidTestKotlin \
  -x :app:compileFlutterBuildDebug
# BUILD SUCCESSFUL in 8s
# /private/tmp/larenor-f60-owned-stream-compile-final2.log
```

Both temporary AAR/receipt mounts were hash-checked and removed after the
compile. This proves only source/package compatibility. The named Android test
has not yet run against the owned Sunshine host, so there is no stream
acceptance receipt in this slice.

## Primary sources

- Android `MediaCodec.OnFrameRenderedListener`: <https://developer.android.com/reference/android/media/MediaCodec.OnFrameRenderedListener>
- Android `AudioTrack.write(short[], int, int, int)`: <https://developer.android.com/reference/android/media/AudioTrack#write(short[],%20int,%20int,%20int)>
- Android emulator networking and NSD support: <https://developer.android.com/studio/run/emulator-networking>
- pinned Moonlight `Game`: <https://github.com/moonlight-stream/moonlight-android/blob/b48494cb96bff23d8886c4775cc4f39a1075495d/app/src/main/java/com/limelight/Game.java>
- pinned Moonlight discovery service: <https://github.com/moonlight-stream/moonlight-android/blob/b48494cb96bff23d8886c4775cc4f39a1075495d/app/src/main/java/com/limelight/discovery/DiscoveryService.java>
- pinned Moonlight video renderer: <https://github.com/moonlight-stream/moonlight-android/blob/b48494cb96bff23d8886c4775cc4f39a1075495d/app/src/main/java/com/limelight/binding/video/MediaCodecDecoderRenderer.java>
- pinned Moonlight audio renderer: <https://github.com/moonlight-stream/moonlight-android/blob/b48494cb96bff23d8886c4775cc4f39a1075495d/app/src/main/java/com/limelight/binding/audio/AndroidAudioRenderer.java>
- pinned Sunshine pairing/client API: <https://github.com/LizardByte/Sunshine/blob/v2026.914.233613/src/confighttp.cpp>
