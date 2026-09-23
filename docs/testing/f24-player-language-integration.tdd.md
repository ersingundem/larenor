# F24 Core language preference player integration

This slice consumes the merged provider-neutral language preference contract
from PR #440.
It leaves F24 pending: queue progress remains **26/125** and selected-feature
progress remains **0/63**.

## Three delivered boundaries

1. **Authority-safe consume and update.** The Jellyfin-facing store now reads
   and updates the shared Core record using the live Core/home/account/session
   authority tuple and CAS revisions. Each edit first reloads the sibling
   language, so an audio update cannot erase a concurrent subtitle choice.
   Provider URL, provider user ID, provider token and device ID never cross the
   Core request boundary. Login/refresh now carries the exact 32-hex session
   family through v3 secure-session persistence. Refresh must retain that
   family, while the password-replacement response must carry a different
   non-null family after the old families are revoked. A possibly committed
   timeout, connection failure or server
   error gets one retry with the exact same 32-hex request ID and body.
2. **Explicit selection with honest fallback.** The existing audio/subtitle
   action sheet explains account persistence before the user confirms a track.
   A missing saved language never invents a track. If native selection succeeds
   but Core persistence fails, playback keeps the local selection and an
   accessible live-region message says it changed only for this video. The
   message is localized in English and Turkish and fits 600/1280 logical-pixel
   tablet surfaces at 2x text scale.
3. **Lifecycle, replay and real-wire evidence.** Every await is followed by the
   exact source, route, account and interaction-generation checks. Retired
   writes cannot update preferred state or publish a stale fallback. A real
   loopback Client-to-Core fixture commits a PUT, loses its response and proves
   the single retry reuses the byte-equivalent body without a second Core
   revision or any direct-provider secret.

## TDD and verification evidence

- RED `309175dcf4a95d0de8cf99cb1d13de38418030bf` captured the removed provider-specific route, missing
  exact-request retry, missing fallback disclosure and stale-result boundary.
- GREEN `02cb0dbd93f9f6af7e23332987ce1a9c2daab969` migrates the store/controller path and player UI while
  preserving the existing native track single-flight behavior.
- The grouped Flutter batch for server account/session plus the four F24
  Jellyfin suites passed **71/71**. This includes the legacy migration's strict
  provider-neutral authority, request-ID and account-revision regression.
- `uv run --frozen pytest -q tests/test_auth.py
  tests/test_media_language_preferences_api.py`: **15/15 passed**.
- Focused `flutter analyze` over the ten changed production/support/test files:
  **no issues found**. Python compilation also passed.

## Remaining F24 acceptance

- Subtitle acquisition/provider consent and bounded provider quota are not
  implemented by this preference slice. The saved value is only a requested
  language and never claims subtitle availability.
- Separate real Jellyfin service plus renderer/subtitle-engine integration
  evidence, exact-head independent review and full commit CI remain required.
- Playback with actual language tracks on target Huawei/DeX hardware stays a
  physical MANUAL gate. F24 must not be marked done from this client contract
  alone.
