# F45 verified sound-event review integration

This package extends the existing local classifier foundation without duplicating it. Raw microphone data still stays outside Larenor Core; the integration persists only bounded event metadata and exposes review state to an authenticated Android tablet session.

## Acceptance criteria

1. **Durable, private Core history.** A separate mode-`0600`, HMAC-authenticated repository persists bounded event metadata across Core restarts. Authenticated `GET /sound-events/{core}/{home}` supports bounded room, class and acknowledgement filters. A partial schema, changed row, invalid count or forged receipt fails closed, and the public contract has no raw-audio, path, URL or secret field.
2. **Exact acknowledgement and readback.** `POST /sound-events/{core}/{home}/{event}/acknowledgements` requires the exact repository and event revisions. Its request identity is idempotent only within the original account and session family. The Client accepts success only when the receipt advances both revisions exactly and a subsequent authenticated snapshot reads back the same event as acknowledged; stale revisions, foreign scope/family, malformed replies and late callbacks never produce verified state.
3. **Tablet event review surface.** The System surface opens one route-owned EN/TR event screen with class/status filters, explicit acknowledgement confirmation, live status semantics and 48 dp actions. Widget coverage runs at 600 and 1280 logical pixels with 2x text and verifies TalkBack semantics; account, session, route and foreground retirement clear private event state before a late response can render. A packaged classifier, physical microphone/sensor validation and Android notification delivery remain MANUAL gates.

## TDD evidence

- RED commit: `2abe5e4f` added Server API, Client controller/HTTP and responsive widget tests before the production modules existed.
- GREEN targets: `server/tests/test_f45_bark_noise_events.py`, `server/tests/test_f45_sound_events_api.py` and `test/features/sound_events/`.
- Queue progress remains unchanged; this package does not claim physical sound capture or end-to-end device acceptance.
