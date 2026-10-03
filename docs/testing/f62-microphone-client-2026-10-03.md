# F62 microphone client contract — 2026-10-03

Status: the schema-4 Dart consumer and focused software regressions are
implemented locally. Root independently passed all 105 RDP Flutter tests and
scoped analysis, then mounted the verified schema-4 native package and passed
the 125-test composed JVM gate and actual AndroidTest Kotlin compilation.
The owned provider effect receipt remains required before the microphone path
is accepted. See the [composed root evidence](f62-owned-microphone-composed-2026-10-03.md).

## Product boundary

- Microphone capture defaults off. A user must explicitly enable it in the RDP
  profile settings before connecting; version-1 stored settings migrate with
  microphone still off.
- An enabled connection requests Android `RECORD_AUDIO` through the dedicated
  native permission broker before certificate inspection, credential entry,
  activation, or RDP open. A denied, cancelled, stale, or mismatched receipt
  never opens a native session.
- The Android permission dialog may temporarily remove window focus. Only the
  exact pending permission request may hold the standalone or Core-managed RDP
  route during that focus transition. The controller waits for focus to return
  before continuing. Background lifecycle, route, account, PIN/interaction,
  settings, provider-container, and session-authority changes still retire the
  request and issue exact cancellation.
- Native permission is not capture evidence. The UI distinguishes permission
  pending, device open, locally captured buffers, buffers submitted to the RDP
  channel, closed, and failed. Even a submitted buffer does not prove a remote
  microphone effect.
- Microphone observations are read-only, single-flight, bounded, tied to the
  exact request/session, and stop on close or failure. Late results cannot
  revive a retired or successor session. No audio bytes, credentials, host
  values, or native error strings enter the public DTO.

## Schema and settings

`contracts/rdp-client.v4.json` is the new immutable example surface. Existing
schema-bearing RDP MethodChannel messages use schema 4, while the historical
certificate-only `inspect` and existing `activate`/`cancel` shapes remain
unchanged. Capabilities have the exact five channel keys `clipboard`,
`clipboardModes`, `audio`, `microphone`, and `files`. Permission request and
receipt use the same UUID request id. Microphone observations retain only
finite state, device-open status, and JS-safe monotonic captured/accepted
counters.

## Focused proof

The focused tests cover strict schema/key validation, version-1 settings
migration, default-off/no-permission behavior, exact permission/open request-id
binding, denial and cancellation, focus loss and resume, standalone and
Core-managed route ownership, real background retirement, unsupported native
capability, microphone observation monotonicity and terminal fencing, stuck
read cancellation, and late-result/successor isolation.

These tests do not prove Android permission UI behavior, physical microphone
capture, RDP audio-input negotiation, remote application consumption, audio
quality, latency, Huawei/DeX routing, or a Windows microphone effect. Those
remain native/package and owned-host acceptance boundaries.
