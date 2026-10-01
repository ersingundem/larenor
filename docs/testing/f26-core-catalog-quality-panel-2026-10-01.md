# F26 verified-Core catalog quality advice — 2026-10-01

## Product boundary

The verified-Core catalog now has a non-recording quality assessment through
`assess-item`. The Client sends its current,
client-reported display, decoder-presence, network-identity and bounded policy
profile. It accepts only the closed Core response bound to the same Core, home,
account family, installation, catalog item and profile digest.

Jellyfin distinguishes Direct Play from remux/direct streaming and transcoding;
these outcomes describe server processing, not physical display or network
quality. See [Jellyfin transcoding](https://jellyfin.org/docs/general/post-install/transcoding/)
and the generated
[PlaybackInfoResponse contract](https://typescript-sdk.jellyfin.org/interfaces/generated-client.PlaybackInfoResponse.html).

The panel therefore shows:

- provider-observed source container, codecs, video range and bitrate;
- the actual client-reported display bounds, decoder MIME-derived codec names
  and configured bitrate ceiling;
- Direct Play, remux, transcode, unavailable and contract-unknown advice with
  distinct explanations;
- an explicit statement that bandwidth was not measured and that HDR,
  hardware acceleration and physical playback acceptance remain manual.

It never displays a provider URL, credential, source identifier or playback
session. Advice accepts exactly `schemaVersion`, `requestId`, `authority` and
`observation`, and rejects any `observationId`. The separate explicit Play
action uses `observe-item`, which requires that consumable identifier. Advice
therefore occupies no observation-pool or playback-lease slot. It never authorizes remux,
transcode, unavailable or unknown outcomes as original-byte playback.

## Freshness and failure behavior

The adapter rejects extra response fields, mismatched authority/profile facts,
incoherent source/transcoding combinations, invalid or expired 30-second
observations, native fact drift and account/session retirement. It rereads the
native profile after the Core response.

The Cupertino panel bounds loading and authority revalidation to ten seconds,
owns and cancels both deadline timers on replacement, invalidation, lifecycle
loss and disposal, discards late responses, clears on exact expiry, and
revalidates on account changes. Cancellation cannot retain a timer or bind a
late assessment to a retired panel, and timeout falls back to the same generic
unavailable state without exposing provider detail. The panel
offers an accessible retry action. English and Turkish copy describe the same
evidence boundary.

## Focused evidence

`flutter test --no-pub
test/features/server/server_core_catalog_playback_capability_test.dart` passed
21 tests. The cases cover the existing Direct Play authorization path, all five
advisory outcomes, closed response parsing, authority/native/TTL fail-closed
behavior, late result disposal, visible English and Turkish advice, loading
timeout, retry, parent and lifecycle retirement, and expiry. Separate advice and
authorization response shapes reject cross-use. Four regressions exercise
disposal with a never-completing load or native revalidation, background
cancellation, and adapter replacement with a late predecessor response.

Root ran capability, source, actual player controls, ordinary catalog entry,
Core track preferences, offline inventory, connection navigation and both
encrypted-vault/Core loopback suites together: **110 passed**, zero failures or
skips. Scoped `dart analyze` completed without errors or warnings.

This is software-contract evidence. It does not replace real provider,
receiver, display, network or physical playback acceptance.

## Normal player integration

The normal catalog exposes an explicit localized “Play on this device” action
with a play icon and button semantics. The existing primary row still opens
managed remote playback. The local screen intro explains both online Core
playback and verified encrypted offline copies; it no longer labels online
playback as an offline download.

`CoreCatalogPlayerScreen` embeds this panel only when online playback is
available, using the same exact catalog binding and capability adapter as its
explicit play action. Parent route/account retirement clears the displayed
assessment. The route regression asserts that valid visible Direct Play advice
has not opened a source or native player; those effects occur only after
tapping Play. Root reran the final 110-test combined suite after the entry and
intro correction: all passed, exit 0. Exact-HEAD broad CI remains pending.
