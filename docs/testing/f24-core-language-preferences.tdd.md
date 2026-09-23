# F24 Core media language preference contract

This slice adds a provider-neutral Core contract for one account's preferred
audio and subtitle languages. It does not claim that a media source contains a
requested track and does not fetch or generate subtitles. F24 remains open;
queue progress stays **26/125** and selected-feature progress stays **0/63**.

## Three accepted boundaries

1. **Versioned Core API.** Authenticated GET and PUT are bound to the exact
   Core, home, account and session family. PUT carries the displayed account
   revision and preference revision, and rejects either stale CAS value.
2. **Private replay-safe persistence.** Preferences and exact replay receipts
   are AES-GCM encrypted and bounded. A 32-hex request ID replays one exact
   accepted PUT without another revision; changed payload reuse, malformed
   schemas, non-integer revisions, account drift and storage tamper fail
   closed. No provider URL, user ID, access token or other credential is part
   of the contract or stored record.
3. **Shared Client/Core fixture.** Protected OpenAPI exposes the exact typed
   request and response. A separate Dart model/API validates closed response
   shapes and authority tuples, and a real loopback HTTP test proves the same
   CAS body crosses the wire without putting the access token in the URL or
   JSON body.

## TDD evidence

- RED `2e1dda27d74ebbe19cf580c88d00233c313f1cc4` captured three 404 failures for
  the missing provider-neutral Core route.
- GREEN `fec0c2f25cc0e84b6ca46188767d8289176fccc8` adds the strict models,
  migrations, encrypted service, Core/app wiring and adversarial server tests.
- `uv run --frozen pytest -q tests/test_media_language_preferences_api.py
  tests/test_jellyfin_track_preferences_api.py`: **6/6 passed**.
- `flutter test
  test/features/media/language_preferences/core_media_language_preferences_api_test.dart`:
  **2/2 passed**, including the real loopback wire fixture.
- Targeted Flutter analysis, security policy, queue validation, progress
  trailers and diff checks are required before review.

## Remaining F24 acceptance

- The provider-neutral contract is not yet selected by the existing Jellyfin
  player preference UI, which still uses its earlier provider-specific Core
  adapter. Migration must preserve fresh same-account sibling fields and the
  existing lifecycle barriers.
- Subtitle acquisition/provider consent and quota remain outside this slice.
  Jellyfin player selection and a subtitle engine still need separate real
  service/renderer integration evidence, followed by exact-head review and CI.
- Playback with actual audio/subtitle tracks on target Huawei/DeX hardware is
  a physical MANUAL gate. Missing audio must continue to remain visibly
  unavailable rather than being inferred from the saved preference.
