# B5.1 media discovery and playback tablet actions

This package closes three previously uncovered Client surfaces without changing
their provider or command contracts.

## Acceptance

1. **Media Hub destinations remain real actions.** Search, music, Home
   Assistant playback, library and media filter controls keep their production
   navigation/filter behavior. A callback retained across account, interaction,
   lifecycle, route or catalogue-revision retirement cannot open an old route
   or reuse stale media identity.
2. **Music output selection remains truthful.** Refresh and receiver actions
   expose 48 dp keyboard and TalkBack targets. Confirmation still executes the
   existing exact account-generation, provider, controller and command-intent
   contract; accepted, observed and unknown receipts stay distinct and errors
   are announced without upstream detail.
3. **Series browsing remains operable on tablets.** Refresh, season selection,
   service navigation and episode actions expose the same minimum target and
   keyboard behavior while delayed reads remain bound to the exact Jellyfin
   account and session generation. English and Turkish layouts are exercised at
   600 and 1200 logical pixels with 2x text scaling.

The focused widget suites cover the real production actions and authority
retirement. Queue progress remains **18/125** and selected feature progress
remains **0/63** until the full B5 software and physical acceptance gates close.
