# B5.1 dashboard, playback and integration tablet surfaces

This package applies the shared tablet hierarchy to three independent Client
surfaces without changing their provider or command contracts.

## Acceptance

1. Today widget settings use the shared service root and grouped sections; kind
   selection, bounded search input, save, cancel, keyboard submission and the
   expired-session state retain their real actions.
2. Home Assistant playback uses the same hierarchy for connection state,
   source and target browsing, receipts and playback controls. Disabled,
   loading, failure and unknown-outcome states cannot appear successful.
3. Integration management keeps provider-backed enable/open actions while each
   row exposes separate 48dp keyboard and TalkBack targets. English and Turkish
   layouts are exercised at 600 and 1200 pixel tablet widths with 2x text.

The focused widget suites, targeted analysis, progress gate, diff check and
merge-tree check pass on the accepted `67261f69` baseline. This is a B5.1
implementation package; the queue remains **17/125** and selected features
remain **0/63** until the full B5 tablet acceptance closes.
