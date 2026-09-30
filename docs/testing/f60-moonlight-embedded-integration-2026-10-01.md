# F60 embedded Moonlight production integration — 2026-10-01

## Scope and availability rule

This slice consumes the pinned, reproducible Moonlight Android AAR described by
`f60-moonlight-android-package-2026-09-30.md`. The Android application includes
the engine source set only when both `android/app/moonlight/moonlight-engine.aar`
and its exact `receipt.json` are installed. A missing pair keeps the embedded
engine absent, a partial pair fails configuration, and `preBuild` verifies the
AAR against the source lock before Kotlin or native packaging.

The capability reports available only when the same APK contains the verified
native library, the private Game activity, the v2 MethodChannel host, and every
v2 method. A current Core/home/account/family authority, a provider binding, an
explicit policy, and a fresh display/network/decoder intersection are still
required before a session can start. Conditional source inclusion alone never
makes F60 available.

## Private upstream boundary

`MoonlightEmbeddedRuntime` uses the actual pinned Moonlight classes:

- `_nvstream._tcp` discovery through `DiscoveryService`;
- `NvHTTP`, `PairingManager`, `AndroidCryptoProvider`, `IdentityManager` and
  `ComputerDatabaseManager` for probe, pairing, catalog and unpair readback;
- `Game`, `NvConnection`, `MediaCodecDecoderRenderer`,
  `AndroidAudioRenderer` and `ControllerHandler` for playback and input; and
- upstream `Game` connection callbacks as causal connection-started and
  connection-terminated observations.

The pairing PIN is generated and displayed by native Android UI. Host
addresses, the PIN, raw Sunshine UUID/application IDs, client key/certificate,
server certificate and native credential handles never cross MethodChannel or
Core. Moonlight's fixed key, identity, database and preference names are
redirected to a directory derived from the exact Core/home/account/family
scope.

Discovery accepts the Client's real 15-second request and has an overall
bind/callback timeout. It caps candidates while collecting them. Numeric target
parsing works on API 26 without `InetAddresses` and never resolves a caller
hostname.

## Durable authority and effects

Pair, catalog refresh, wake, launch, stream, stop and revoke reserve a durable
record before provider I/O. Journal schema v2 persists the exact Core operation,
authority fingerprint and authorization/session expiry. An exact request replay
returns the stored receipt. A different request ID for an already-recorded
`(kind, operationId)` is rejected before I/O, preserving one-use grants.

`dispatching` and `unknown` are permanent quarantine evidence. Known terminal
records can be removed only after their authorization has expired plus a
five-minute retention period; old schema-v1 records have no trusted expiry and
are never pruned. A removed request cannot be reserved with its expired
authorization. Capacity is bounded at 2,048 full records, while normal completed
traffic ages out rather than permanently filling the former 128-record store.

The strict native authority includes `pinConfigured` and `pinUnlocked` as well
as `pinRevision`; both booleans participate in its fingerprint. A policy with
`requirePin` cannot be configured, bound or dispatched unless a configured PIN
has a fresh unlock. Capability observation reports `pinRequired` and mutation
methods return `pin_required` when that proof is absent.

Current authority is rechecked immediately before WOL, quit, launch, pair and
unpair provider mutations and again before accepting causal readback or local
credential/registration state. Catalogs above 256 entries fail closed; they are
never silently truncated into false Core retirements. Wake and launch receipts
use the contract's real `serverInfoOnline/hostAwake` and
`currentGameMatched/appRunning` pairs. Unknown provider timing never becomes a
success receipt or an automatic redispatch.

## Foreground, display and lifetime ownership

The embedded activity receives only a random process-private launch token.
Provider address, certificate and application ID are resolved inside the
process immediately before upstream `Game.onCreate()`.

A stop uses the exact binding and session captured when the foreground lease
was created. It deliberately remains available after PIN relock and route,
lifecycle, idle or interaction revision drift, but Core, home, account, family,
account revision, binding and session identity must still match byte for byte.
The stop is never reported as successful until the source-locked Game hook
observes that its actual `NvConnection.stop()` call returned. This produces the
distinct `connectionStopped` observation. A remote termination still produces
`connectionTerminated`; timeout or destruction remains `unknown`, and a late
callback from an old lease cannot affect its successor.

Capability observation uses scoped provider storage and the Flutter Activity's
actual display, including display-specific metrics. Stream launch uses
`ActivityOptions.setLaunchDisplayId()` for the selected display, and the Game
activity checks the actual display ID before upstream provider setup. A
secondary-display selection is therefore not silently replaced by
`Display.DEFAULT_DISPLAY`.

`MoonlightForegroundLeaseRegistry` transfers ownership through
`transferPending -> gameVisible -> retiring -> retired|uncertain`. Only the
exact Game or pairing-prompt token may cover Flutter focus loss. Stale callbacks
cannot mutate or crash a successor. The Game claims visibility only after
resume and window focus; `FLAG_SECURE` and secure `SurfaceView`s are installed
before content attachment. The patched source marks local stop start before its
worker is launched, so Activity destruction cannot erase a still-running exact
stop. Only worker completion produces `connectionStopped`. An `onCreate`
failure and ordinary `onDestroy` remain unknown and never fabricate stop proof.

Core expiry, policy maximum-session time and native input-idle time all retire
the exact lease. Input activity maintains one rescheduled idle runnable rather
than accumulating callbacks. Android framework key, touch, motion and controller
events count as activity. The upstream custom USB-driver binder bypasses these
Activity callbacks and has no safe listener tap, so the scoped policy explicitly
disables `checkbox_usb_driver` and USB bind-all. Custom USB-driver input is
unsupported in this slice; ordinary Android framework controllers remain
supported.

The explicit `retire` boundary is also exact: it requires the currently bound
session ID and revision, fences native authority and returns a strict local
`retired` receipt. Missing or stale sessions return `authority_changed` instead
of silent success. That receipt proves only local authority retirement and is
not provider-stop evidence.

Pairing and catalog work also has an authority-level retirement boundary.
`retireAuthorityV2` accepts the full cached authority and either an exact native
binding pair or two null binding fields for the callback-loss window before
`beginPairingV2` disclosed its synchronously-created binding. The null form can
resolve only that exact current authority fingerprint; its durable receipt
returns the actual binding. Exact request replay returns the same receipt with
no effect, while a different request or stale binding cannot retire a successor.
Retirement increments the runtime generation, cancels the exact PIN prompt and
prevents late discovery/pair/catalog callbacks from publishing success. Local
credential/registration commits recheck the same generation while serialized
with retirement. A retired authority fingerprint cannot be rebound, including
after process restart; uncertain provider work remains quarantined evidence.
The fingerprint includes a fresh 32-hex `clientInstanceId` generated once per
settings-screen instance. An exact retired instance therefore remains fenced,
while a newly created screen with otherwise identical revision counters can
bind under its distinct instance ID. A replay from the old instance cannot
retire the successor.

## Truthful capability observation

Sunshine `serverinfo` reports codec support, pairing state and current game, but
not host maximum dimensions or FPS. The native host observation therefore
contains only upstream-reported codecs. Width, height and FPS are local request
ceilings derived from the attached display, selected Android decoder and
explicit policy. See the official Sunshine implementation:
<https://github.com/LizardByte/Sunshine/blob/master/src/nvhttp.cpp#L1128-L1167>.

Decoder identity uses the same pinned `MediaCodecHelper` selection followed by
`MediaCodecDecoderRenderer` for each forced codec, rather than choosing an
unrelated largest Android decoder. The public codec ID binds that actual decoder
name and an aligned `(width, height, fps)` tuple accepted by
`VideoCapabilities.areSizeAndRateSupported()`. This is a request-support fact,
not a real-time performance guarantee; Android documents that distinction at
<https://developer.android.com/reference/android/media/MediaCodecInfo.VideoCapabilities>.
Native re-observes the exact option immediately before stream launch.

Network identity includes the active Android network handle, transports,
metering, destination digest and destination-specific route match. A local-link
route can be used without Internet validation; generic validated Wi-Fi is not
presented as proof that the Sunshine destination is local.

There is no default stream policy. Explicit CAS policy stores codec, metering,
PIN, quality, lifetime and queue bounds. The pinned renderer/input paths support
exact queue depths `2/1`; other values are unavailable. Stream success means the
actual upstream `connectionStarted` callback was observed. It does not claim a
decoded frame, GPU performance, HDR quality or latency.

## Production composition and package proof

`MainActivity` owns one existing MethodChannel bridge and loads the embedded v2
host only when the verified source set exists. A no-AAR build keeps the activity
disabled and contains neither Moonlight bytecode nor `libmoonlight-core.so`.
The embedded manifest removes upstream standalone providers/UI while retaining
only the private Larenor Game activity and upstream services actually used by
the engine.

The final receipted build produced a debug APK and `verify-apk` accepted its AAR
identity. Merged-manifest and APK inspection confirmed:

- `LarenorMoonlightGame`: enabled, non-exported, `StreamTheme`;
- `MainActivity` and `MoonlightMethodChannelHost` bytecode;
- `libmoonlight-core.so` for arm64-v8a and x86_64; and
- no upstream `PcView`, `AppView`, shortcut, settings or add-computer entry.

## Focused verification

```text
python3 tool/moonlight_android_package.py verify-install \
  android/app/moonlight/moonlight-engine.aar \
  android/app/moonlight/receipt.json
# passed

cd android && ./gradlew --no-daemon :app:testDebugUnitTest \
  --tests com.ersingundem.larenor.game.moonlight.MoonlightEmbeddedRuntimeTest \
  --tests com.ersingundem.larenor.game.GameStreamNativeBridgeTest \
  --tests com.ersingundem.larenor.game.GameStreamNativeAdapterTest \
  --tests com.ersingundem.larenor.vnc.VncProductionLoopbackTest \
  -x :app:compileFlutterBuildDebug
# 28 + 4 + 8 + 5 tests; zero failures/errors/skips
# /tmp/f60-native-client-instance-final.log

flutter build apk --debug --target-platform android-arm64,android-x64
python3 tool/moonlight_android_package.py verify-apk \
  /tmp/larenor-f60-embedded-client-instance-final.apk \
  android/app/moonlight/receipt.json
# passed
# /tmp/f60-embedded-client-instance-final-build.log
# /tmp/f60-embedded-client-instance-final-verify.log
```

The embedded APK SHA-256 is
`16be9b882f25ef42691ee27bb2bc09b6f1a6d348c0f8fb712ef4781e28b1d3ca`.
`/tmp/f60-embedded-client-instance-final-manifest.xml` and direct APK ZIP/DEX
inspection confirm the private enabled/non-exported Game activity, both ABIs,
the embedded host and the real Moonlight engine classes.

The AAR and receipt were then removed from the application tree and a second
debug APK was built. Its SHA-256 is
`13b315c85b9770ada869eea3d95973d2cc8b86c37a5d948c812fd70f3e7a916b`.
`/tmp/f60-default-client-instance-final-manifest.xml` plus direct ZIP/DEX
inspection prove that the private Game activity is disabled, the Moonlight
runtime and native library are absent, and the common fail-closed loader remains.

Client gates after the PIN authority, safety-stop and durable cleanup changes
passed 86 focused Flutter tests plus one expected normal-runner-only skip, and
scoped analysis reported no issues. The normal
Client-to-Core runner passed 1/1, including pairing, catalog lost-ack recovery,
stream, causal `connectionStopped` safety stop, strict retirement and revoke.
Core separately passed its focused v2 authority suite.

The separate discovery-only hosted gate uses Emulator 36.5 or newer and
Moonlight's production `DiscoveryService`; Android documents NSD support in
shared-networking mode at
<https://developer.android.com/studio/run/emulator-networking-interconnect> and
the 36.5.10 emulator release at
<https://developer.android.com/studio/releases/emulator#36-5-10>. The private
orchestrator derives Sunshine's real runner-hostname mDNS instance and supplies
only that bounded identity to instrumentation. The uploaded receipt also binds
the verified AAR SHA-256, engine revision, classes digest and pinned upstream
source commit/tree. The test first matches the raw
NSD instance, then performs two fresh production discovery lifetimes and checks
the real NvHTTP display name `Larenor-F60-Owned`; it injects no endpoint, PIN or
credential. The instrumentation source compiles successfully
(`/tmp/f60-owned-discovery-compile-final-2.log`), its strict receipt/parser and
workflow checks pass 6/6, and actionlint is clean. No hosted discovery receipt
exists yet, so this is a prepared named gate rather than evidence that the
emulator discovered Sunshine.

The software and packaging gates above do not include an actual owned Sunshine
server speaking the protocol to this APK. F60 therefore remains test-pending;
it is not awaiting CI. An owned Sunshine pairing/catalog/stream/stop acceptance
run is still required before the normal provider boundary is accepted. Physical
household Sunshine pairing, WOL, launch, GPU decode, Android controller
behavior, HDR, network latency, secondary-display hardware behavior and
picture-in-picture remain separate manual device/provider evidence. None of the
owned fixtures or APK inspection is described as proof of those physical facts.
