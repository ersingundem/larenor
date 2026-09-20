# B5.1 kiosk, library and legal tablet acceptance

20 September 2026. This slice covers three independent tablet surfaces without
claiming physical Android device-policy or live Jellyfin acceptance.

## Acceptance criteria

1. **Kiosk controls:** every policy action has a 48 dp keyboard/TalkBack target,
   stays PIN-gated, and callbacks from a replaced controller, hidden window,
   background session or retired dialog cannot reach the native write boundary.
2. **Jellyfin library:** the shared service hierarchy works in English and
   Turkish at 600 and 1200 logical pixels with 2x text; loading/error/account
   transitions hide retained media and expire callbacks from the prior source.
3. **Legal:** local source and bundled notices use the shared tablet hierarchy,
   remain keyboard-readable, and callbacks rendered before a lifecycle or route
   transition cannot open a stale document or publish stale clipboard feedback.

The focused Flutter run passes **35 tests**. Targeted analysis, queue validation,
security policy, diff checks, secret scanning and open-PR merge-tree checks are
required before integration. This slice keeps the accepted baseline at
**17/125** queue items and **0/63** selected features.
