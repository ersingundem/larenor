# F24 — Jellyfin language preference software slice

This is an independent Client foundation for F24. The queue stays **22/125**
and selected features stay **0/63** until F24's full Client-to-Core/service
contract and CI acceptance are complete. This slice does not download or
generate subtitles, or claim that a missing audio language exists.

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

## Remaining F24 work

Preferences are currently device-local. Core-managed per-person sync,
provider quota/consent for optional subtitle acquisition, a real isolated
Jellyfin/renderer integration test, and playback on Huawei/DeX with actual
audio/subtitle tracks remain **PENDING/MANUAL**. An actual missing voice track
must continue to be reported as missing.
