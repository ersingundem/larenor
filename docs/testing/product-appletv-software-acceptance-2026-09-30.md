# PRODUCT.APPLETV software acceptance — 2026-09-30

## Production contract

Larenor uses Home Assistant's authenticated WebSocket API and the registered
`media_player` entity. A selectable Apple TV target must have all of the
following in the same fresh inventory read:

- an exact `media_player.*` entity;
- entity-registry identity (`id`, `device_id`, `config_entry_id`) whose
  integration platform is exactly `apple_tv`;
- an enabled, available entity with the `PLAY_MEDIA` feature bit; and
- the `media_player.play_media` service descriptor.

The command targets that exact entity and sends only the selected
`media-source://` identity and MIME type. It does not resolve a private media
URL, forward Home Assistant credentials, use an area-wide target, or silently
retry an uncertain command.

Home Assistant documents that Apple TV entities expose playback controls and
that `media_player.play_media` can open supported media/deep links, with exact
behavior depending on the application and tvOS. Home Assistant also states
that Media Source does **not** transcode media; the receiving player must
support the container and codecs:

- [Apple TV integration](https://www.home-assistant.io/integrations/apple_tv/)
- [`media_player.play_media`](https://www.home-assistant.io/actions/media_player.play_media/)
- [Media Source](https://www.home-assistant.io/integrations/media_source/)
- [Media player entity developer contract](https://developers.home-assistant.io/docs/core/entity/media-player/)

Larenor therefore treats an HA item described as `video/mp4` and classified as
video, movie, or episode as an **MP4 candidate**, not proof of compatible video.
The confirmation names that codec, DRM, and physical playback remain
unverified. Other video descriptions stay disabled for Apple TV. This flow
does not expose arbitrary URL/deep-link input and does not claim transcoding.

## Authority, lifecycle, and receipt semantics

Selection creates a memory-only, account/session-scoped intent with a 30-second
expiry. Source browsing, target inventory, registry identity, capability, and
service availability are read again before dispatch. Account replacement,
route hiding, application backgrounding, disconnect, cancellation, source
change, or identity change retires the intent and prevents a send.

After an accepted service response, authority loss cannot be reported as a
known cancellation: playback may already have started, so the result is
explicitly unknown and is never replayed. An `observed` receipt requires a
later inventory read showing the exact target in `playing`, the exact
`media-source://` ID, and a newer `last_updated` value. The UI describes this
only as a Home Assistant report; it is not physical output or decoder proof.

## Automated evidence

Run:

```sh
flutter test test/features/media/ha_playback
flutter analyze \
  lib/features/media/ha_playback \
  test/features/media/ha_playback
```

Root independently ran the focused suite: **67 passed, zero skipped**.
Targeted analysis completed with no issues.

The focused suite covers bounded response parsing, exact registry identity,
service/capability loss, MP4 candidate restriction, explicit Apple TV warning,
single-use confirmation, pre-send cancellation, post-accept authority drift,
lost-response no-replay, causal readback, background/disconnect timer cleanup,
and EN/TR route behavior.

`ha_playback_live_tcp_test.dart` uses an owned loopback Home Assistant WebSocket
fixture and the production `HaWebSocketClient` → `WsHaPlaybackApi` →
`HaPlaybackController` path. It accepts exactly one Apple TV `play_media`
command, changes the owned entity state, and proves the later causal receipt.
It rejects extra commands and verifies that no token or resolved media URL is
sent to the receiver command.

## Manual evidence still required

The loopback fixture proves Client protocol composition, authority boundaries,
and receipt logic. It does not contain an Apple TV, a decoder, an HDMI display,
or DRM entitlement. Physical receiver acceptance remains under `MANUAL.MEDIA`
and must cover the intended Apple TV/tvOS/app combination, representative
codecs and DRM/non-DRM items, network reachability, and disconnect behavior.
