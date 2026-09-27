# F24 — Jellyfin language preference software slice

This document records the original Client foundation for F24. The preference
has since moved to the provider-neutral Core contract and the explicit Bazarr
acquisition boundary described in
`docs/testing/f24-player-language-integration.tdd.md`. The historical queue
counts below are evidence for that original slice, not the current project
totals.

## Three acceptance criteria

1. **Account-scoped local preference.** A manual audio or subtitle choice with
   a valid language label saves a bounded, versioned record under a hash of
   the Jellyfin endpoint and user ID. Subtitle Off is explicit. Tokens are not
   stored with the preference; another user or a retired route cannot read or
   write that record. Corrupt records are ignored, never interpreted as a
   verified track or used to block video playback.
2. **Only actual tracks.** A new media source applies the preferred language
   only when the native player reports that track. Common ISO 639-1/2 forms
   normalize together; exact regional matches win before primary-language
   fallback. An unavailable language leaves the
   source's current selection intact. A source change invalidates old track
   IDs, and the selector does not replay an uncertain native command.
3. **Tablet and lifecycle boundary.** EN/TR selection sheets explain local
   preference behavior and fit 600/1200 logical pixels at 2× text. Existing
   48 dp, keyboard and semantics controls remain covered. Account, route,
   foreground, item and idle-generation changes retire delayed selection and
   preference callbacks, including an idle→wake sequence.

RED `ac049d88` captured the missing bounded preference contract; the
additional exact-region and idle→wake regressions were observed failing
before the matching/epoch fixes. Focused unit, player interaction and player
lifecycle tests, scoped `flutter analyze`, queue/security checks, progress
trailers, gitleaks and merge-tree are the software gates for this PR.

## Current boundary

Preferences are Core-owned and per-person. Optional subtitle acquisition now
requires exact-row consent, consumes a bounded provider-account session budget
and performs a read-only Bazarr observation without retrying an uncertain
mutation. Real-service/renderer tests, exact-head CI and physical Huawei/DeX
playback remain pending final verification. An actual missing voice track
continues to be reported as missing.
