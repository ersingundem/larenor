# F60 Core native-observation authority v2 — 2026-10-01

## Result

Core now creates a short-lived pairing intent before native pairing begins. A
successful native Moonlight pairing can then commit one bounded observation and
receive Core-owned host and application IDs. The public assurance is exactly
`native_observed`; caller metadata is never promoted to provider verification.

The contract is published in
`docs/contracts/f60-game-streaming-v2.json`. It contains no address, PIN, raw
Sunshine host/application ID, client certificate, private key, server
certificate, or native credential handle. Core persists keyed digests for the
native binding and source observations. The Android runtime keeps those native
values and credential material private.

## Upstream behavior used by the boundary

The packaged Moonlight source is pinned to
[`b48494cb96bff23d8886c4775cc4f39a1075495d`](https://github.com/moonlight-stream/moonlight-android/tree/b48494cb96bff23d8886c4775cc4f39a1075495d).
Its
[`PairingManager`](https://github.com/moonlight-stream/moonlight-android/blob/b48494cb96bff23d8886c4775cc4f39a1075495d/app/src/main/java/com/limelight/nvstream/http/PairingManager.java)
does the PIN-derived challenge and certificate validation. Its
[`NvHTTP`](https://github.com/moonlight-stream/moonlight-android/blob/b48494cb96bff23d8886c4775cc4f39a1075495d/app/src/main/java/com/limelight/nvstream/http/NvHTTP.java)
reads pair state, server information, application IDs, and current-game state
through the pinned host certificate. Its
[`NvConnection`](https://github.com/moonlight-stream/moonlight-android/blob/b48494cb96bff23d8886c4775cc4f39a1075495d/app/src/main/java/com/limelight/nvstream/NvConnection.java)
checks the selected application/current game before launch or resume and then
starts the actual stream connection. Sunshine's official
[`/api/pin` documentation](https://docs.lizardbyte.dev/projects/sunshine/master/md_docs_2api.html)
describes approval of an already pending pairing operation; it is not evidence
that an arbitrary Core registration is paired.

These facts are why Core accepts only a native observation after an already
authorized pairing intent. Core does not accept a public caller-supplied host,
application ID, capability, or credential handle as source authority.

## Durable behavior

- Pairing and dispatch grants are one-use, short-lived values. Only keyed
  digests are stored. An idempotent replay never returns a grant.
- A repeated command authorization is treated as a lost acknowledgement and
  becomes terminal `unknown`; it is not dispatched again.
- On Core restart, every still-`authorized` dispatch is durably changed to
  `unknown` before the API becomes available.
- Session authority binds the current account, family, host, pairing, catalog,
  application, Client route/lifecycle/display/network/policy revisions, and the
  exact selected codec/size/rate/queue quality option. Every JSON revision is
  limited to JavaScript's safe integer range.
- Native completion has one of the explicit observation kinds
  `serverInfoOnline`, `currentGameMatched`, `connectionStarted`,
  `connectionTerminated`, `nativeRejected`, or `unknown`. Readback revisions
  increase per host. The public state remains `native_observed`.
- Catalog refresh is also two-phase: Core issues a one-use catalog observation
  grant before NvHTTP reads the application list. Completion preserves Core
  application IDs by keyed native observation digest, assigns IDs to new
  applications, retires missing applications, increments the catalog revision,
  and retires every session bound to the previous catalog.
  An empty observed catalog is valid: successful pairing may have no
  applications, and a later empty refresh retires the final application.
- Core revocation retires the host and all open sessions before the native
  credential cleanup result is recorded as `local_cleared` or `unknown`.
- The v1 caller-declared registry is retired during migration. No old row is
  silently upgraded to v2 native authority.

The encrypted Core database backup contains the v2 pairing, host, catalog,
session, command, and revocation journals. Backup admission remains blocked
while a current command is `authorized`. A restored process applies the same
startup recovery and cannot replay the stored grant digest.

## Focused software evidence

```text
cd server
uv run pytest -q \
  tests/test_f60_game_stream_authority.py \
  tests/test_core_backup_active_effect_cut_next.py

28 passed

python3 -m py_compile \
  larenor_server/game_streaming/models.py \
  larenor_server/game_streaming/schema.py \
  larenor_server/game_streaming/service.py \
  larenor_server/game_streaming/api.py
```

The focused tests cover intent-before-observation, strict catalog digest and
selected-quality binding, account/family isolation, one-use grants, lost
acknowledgement, empty native catalogs and reorder/add/remove reconciliation, monotonic
native readback, restart recovery, revocation,
tamper refusal, v1 retirement, and the backup active-effect cut.

## Acceptance boundary

This is Core authority and software receipt evidence. It does not prove that a
physical Sunshine host rendered video, produced audio, accepted input, or met
the selected codec and performance limits. Those remain separate native and
owned-host acceptance gates. A native `connectionStarted` callback strengthens
only the causal software transport wording; it does not by itself prove visual
or audio output.

## Root independent verification

Root ran the frozen Core slice together with backup active-effect, Core context
and admin migration checks: **59 passed** (two upstream deprecation warnings),
log `/tmp/larenor-root-f60-core-v2-final.log`. The zero-application catalog is a
valid observation: it retires every old app/session instead of preserving stale
launch targets. Repeated catalog replacement keeps SQLite sequence uniqueness.

This Core slice does not close F60. The Client/native MethodChannel, durable
pair/catalog/revoke recovery, normal MainActivity composition and actual owned
Sunshine playback/stop/revoke acceptance remain in progress. Cross-stack review
found a canonical digest mismatch; native now matches the Core algorithm, but
that correction still needs the composed contract and runtime gates.
