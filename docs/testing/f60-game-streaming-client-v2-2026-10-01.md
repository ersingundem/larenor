# F60 game streaming Client v2 integration — 2026-10-01

## Result

The Flutter Client now uses the Core-owned F60 v2 authority contract in
`docs/contracts/f60-game-streaming-v2.json`. It creates a short-lived Core
pairing intent before native discovery or pairing I/O, submits only a bounded
native observation, commits the Core registration mapping back to native
storage, reads the current Core catalog, requires an explicit native stream
policy and current capability intersection, and starts or stops only through a
one-use Core dispatch grant.

The public assurance remains exactly `native_observed`. A native
`connectionStarted` or deliberate `connectionStopped` receipt is a causal
transport observation; it is not proof that a frame was decoded, displayed,
or heard. `connectionStopped` is accepted only after the source-locked native
Game hook observes `NvConnection.stop()` return. `connectionTerminated`
remains a distinct remote/native termination observation.
Unknown outcomes are visible and never automatically replayed.

## Upstream boundary

The embedded provider is the repository-pinned Moonlight Android revision
[`b48494cb96bff23d8886c4775cc4f39a1075495d`](https://github.com/moonlight-stream/moonlight-android/tree/b48494cb96bff23d8886c4775cc4f39a1075495d).
Its
[`PairingManager`](https://github.com/moonlight-stream/moonlight-android/blob/b48494cb96bff23d8886c4775cc4f39a1075495d/app/src/main/java/com/limelight/nvstream/http/PairingManager.java)
performs the PIN and certificate exchange; its
[`NvHTTP`](https://github.com/moonlight-stream/moonlight-android/blob/b48494cb96bff23d8886c4775cc4f39a1075495d/app/src/main/java/com/limelight/nvstream/http/NvHTTP.java)
reads pairing, server, application, and current-game facts. Sunshine's official
[`POST /api/pin` documentation](https://docs.lizardbyte.dev/projects/sunshine/master/md_docs_2api.html)
confirms that a PIN applies to an already pending pairing request. The Client
therefore never treats a user-entered host label, PIN, or caller-declared app as
provider evidence.

Sunshine's official
[`serverinfo` implementation](https://github.com/LizardByte/Sunshine/blob/master/src/nvhttp.cpp)
advertises codec-mode flags but does not publish host maximum width, height, or
frame rate. Its official
[`RTSP` implementation](https://github.com/LizardByte/Sunshine/blob/master/src/rtsp.cpp)
instead receives the requested viewport and maximum FPS when a stream session
is negotiated. The Client therefore treats resolution and FPS as explicit local
policy bounded by current Android display and decoder observations, not as an
observed host capability.

The Android MethodChannel receives only Core IDs, one-use grants, exact
revisions, bounded quality facts, and native-private opaque binding IDs. Host
addresses, raw provider host/app IDs, pairing PINs, client certificates,
private keys, and provider credentials do not enter Flutter state, Core JSON,
logs, or this acceptance receipt.

## Authority and recovery behavior

- Settings supplies a current authority only while the same authenticated
  account, family, PIN gate, visible route, resumed lifecycle, idle generation,
  and interaction generation remain current. Each fact has its own monotonic
  revision. Every recreated game settings screen also owns a fresh random
  128-bit Client instance ID that remains stable for that screen lifetime. It
  participates in native authority identity, so an exact retirement replay for
  an old screen cannot permanently block or fence a newly opened screen whose
  revision counters restart at the same values.
- The private native authority carries separate `pinConfigured` and
  `pinUnlocked` facts in addition to the monotonic PIN revision. An absent PIN
  is never treated as unlocked. A policy with `requirePin: true` is rejected as
  `pin_required` before native configuration and before Core session creation
  unless both facts are current. The UI tells the user to set and unlock the
  Settings PIN; it never transports or stores the raw PIN in the F60 contract.
- Pairing uses Core intent -> native observation -> Core registration -> native
  registration mapping. The selected host is replaced with the exact current
  Core readback object before any later effect, so a stale registration response
  cannot authorize revoke or stream. The Client persists the exact authority,
  intent/grant, and a not-yet-dispatched phase before native discovery. Pairing
  dispatch is a separate durable transition, so restart either reconciles the
  one native operation or fences discovery without starting pairing.
- Catalog refresh uses a separate Core observation intent and grant. The Client
  persists the exact authority and intent before resolving the native binding,
  then persists that binding and a separate dispatch phase before NvHTTP I/O.
  A lost callback is reconciled from the native journal after Client restart;
  the catalog read is not sent again. Empty catalogs remain valid and do not
  fabricate an app.
- Policy has no default. Start remains unavailable until native reports an
  attached secure display, current network, supported decoder, explicit policy,
  and a nonempty host/native/policy quality intersection. The selected quality
  and display/network/policy revisions are echoed unchanged into Core and native
  session binding. Sunshine server-info does not advertise a host resolution or
  frame-rate maximum, so neither Core nor the Client presents one as a host
  fact. The explicit policy proposal is derived only from the current secure
  Android display and MediaCodec decoder observations intersected with the
  upstream host codec bitmask. The pinned renderer/input implementation is
  represented truthfully as frame queue depth 2 and input queue depth 1; an
  incompatible saved policy is unavailable as `queuePolicyUnsupported`.
- Command grants are encrypted before native I/O. Restart first reads the Core
  command and the native durable receipt. It never calls execute again. Public
  `unknown` has null readback revision and digest; `rejected` is accepted only
  with a causal monotonic readback and digest. Neither state is promoted to
  success.
- A Core session is written to encrypted recovery storage before native bind.
  Bind failure retires the exact Core session. If that cleanup is unavailable,
  restart may only retire the stored session and clear the record; it never
  binds or dispatches the stream automatically. This prevents failed binds
  from consuming live-session capacity invisibly.
- Stop uses the already bound native authority, binding revision, and Core
  session revision. It does not reread host catalog, display, network, decoder,
  policy, or PIN capability data before safety closure. The native method
  requires the exact `safetyClosure` and one-use stop grant. If Core already
  retired or advanced the session after catalog/host drift, the Client retires
  the stored native lease with its original revision, attempts Core cleanup,
  reports the stop outcome as unknown, and never sends a new stop command.
  After a causal `connectionStopped` completion, the Client durably records
  cleanup by atomically replacing the command-grant record before clearing it,
  exact-retires native ownership and the Core session, and clears the foreground
  lease only after both acknowledge. The exact native-retired phase is persisted
  before Core cleanup, so a Core outage is retried without a second native
  retirement call. Cleanup loss leaves the causal stop command visible while
  reporting `stop_cleanup_unknown`; restart retries retirement only and never
  sends stop again.
- Revoke persists a prepare record before Core retirement, then a ready record
  before native cleanup, and a dispatching record before unpair I/O. Recovery
  replays only the idempotent Core request or reads the native journal. Once
  native dispatch may have happened, it never sends unpair again. A retired
  host need not remain in the public host list for cleanup reconciliation.
- Recovery records are encrypted by the platform secure store, scoped to exact
  Core/home/account/family IDs, and bounded to 8 KiB. A scope mismatch retains
  the record and blocks new effects. If it names an exact session, the Client
  may perform only the local native fence and persist that phase; Core cleanup
  waits for the original authenticated scope. One-use command grants are not
  erased or replayed across logout. Records contain no provider address, PIN,
  certificate, key, or native credential handle.
- Pairing and catalog teardown has its own exact native authority retirement.
  The pending phase is written before `retireAuthorityV2`; callback loss reuses
  the pairing or catalog operation ID and the native durable receipt, with zero
  rediscovery, pairing, or catalog I/O. Logout uses the authority stored by the
  original scope, and catalog teardown also binds the exact stored native
  binding revision. The original grant/evidence remains encrypted after local
  fencing because a different authenticated scope cannot settle its Core
  outcome. A stale retirement receipt cannot fence a successor authority.
- A malformed or unreadable recovery record is retained rather than deleted or
  overwritten. Teardown first captures the in-memory exact session or pairing
  lease; it still attempts the native local fence and Core session retirement
  when secure storage fails, then reports an unconfirmed cleanup outcome. A
  later retry uses the same operation identity. Storage failure therefore
  cannot silently leave streaming, discovery, or a pairing prompt live, and it
  cannot turn an unknown one-use grant into a new dispatch.
- When Core has already advanced or retired a session, command-grant and bind
  recovery first exact-retires the original native session revision. A generic
  MethodChannel failure retains the encrypted record and reports an unknown
  cleanup outcome; Core drift alone never deletes the final native fence. Once
  native retirement is acknowledged, recovery persists that phase before Core
  cleanup and skips the native call on every later retry.
- Route retirement fences native ownership with the exact stored session
  revision, then attempts Core retirement even when the native receipt fails.
  It writes the exact session cleanup record before native I/O and persists the
  native-retired phase before Core cleanup. Route or logout teardown may hide
  the transient UI error, but it cannot erase that record. A later controller
  retries cleanup without replaying a command. A native no-match is surfaced
  and cannot be mistaken for retirement proof; a second Core session whose
  revision restarts at one still sends epoch one, rather than a process-global
  counter. A late response cannot revive the route or authorize another
  dispatch.
- Covering Flutter with the exact owned pairing prompt or embedded Game task is
  admitted only by a read-only native attestation bound to the same authority,
  binding, operation/session ID, and revision. Settings retains the nested route
  during that bounded cover. Returning without the exact attestation, entering
  ordinary background, logout, PIN/idle revision drift, route replacement, or
  an external overlay retires the authority and cannot replay an effect.

## Focused evidence

The normal TCP acceptance starts the production Core composition, signs in a
real Client session, and uses only an owned MethodChannel provider fixture. It
proves the Flutter orchestration and Core HTTP boundary without contacting a
household device:

```text
cd server
uv run python tests/support/f60_flutter_acceptance.py

1 passed
```

That path performs pairing, deliberately loses the catalog-read callback,
disposes the first Client controller, reconciles the stored native catalog
receipt with a second controller, verifies one catalog dispatch, reads two
Core-registered apps, configures policy, streams and stops with two command
dispatches, and revokes with current Core readback. Every private native call
also asserts explicit `pinConfigured: true` and `pinUnlocked: true`; omission or
an inferred unlock cannot satisfy the fixture.

```text
flutter test --no-pub test/features/game_streaming

65 passed, 1 expected skip
```

The expected skip is the normal TCP test when its acceptance runner has not
provided a Core URL. Focused tests cover strict public DTOs, the shared JSON
fixture, zero-app catalogs, JS-safe revisions, late authority responses,
pair/catalog/command/revoke callback loss and restart, exact native terminal
receipt rules, durable failed-bind retirement without rebind, deliberate
`connectionStopped`, stop without a capability reread, exact revision-one
retirement across successive sessions, native no-match with Core cleanup,
actual lifecycle/view-focus chains for exact pairing/Game cover, settings-gate
retention and retirement, truthful local policy derivation, route retirement,
settings presentation, and secret-free payloads.

```text
flutter test --no-pub \
  test/features/game_streaming \
  test/features/settings/settings_gate_screen_test.dart

86 passed, 1 expected normal-Core skip
```

The PIN regression starts from a compile-time RED because the private authority
did not yet accept the two assurance fields. The GREEN gate covers exact
MethodChannel serialization, no-PIN rejection before native policy I/O,
PIN-revision/unlock drift before Core session creation, and Settings gate
expiry. The normal-Core skip remains explicit unless the owned TCP runner
provides its isolated server URL. The route/logout regressions also cover a
failed secure-store read while native session retirement still runs, a lost
authority-retirement acknowledgement replayed after logout, exact catalog
binding retirement, retained pairing/catalog grants, and restart without a
second provider effect. A recreated-screen regression also proves the Client
instance ID is stable within one screen and fresh for the next screen, while
the original ID remains in encrypted recovery for exact cleanup.

```text
flutter analyze --no-pub \
  lib/features/game_streaming \
  lib/features/settings/presentation/settings_split_screen.dart \
  lib/features/settings/presentation/settings_gate_screen.dart \
  test/features/game_streaming \
  server/tests/support/f60_flutter_acceptance.py

No issues found

python3 -m py_compile server/tests/support/f60_flutter_acceptance.py
git diff --check -- <F60 Client allowlist>
```

## Evidence boundary

The MethodChannel fixture is intentionally real-shaped but owned. This evidence
does not claim physical Sunshine pairing, GPU decode, rendered frames, audio,
controller input, HDR, latency, device-specific picture-in-picture, or provider
performance. Those require the separately packaged native engine and an owned
Sunshine/Android hardware gate. Missing or unknown native capability remains
unavailable in the Client instead of becoming a synthetic success.
