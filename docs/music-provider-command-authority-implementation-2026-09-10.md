# S06.5 — Music Assistant provider command authority

This bounded slice adds the review authority for enabling or disabling an
already verified Spotify, Apple Music or YouTube Music provider inside the
Larenor-managed Music Assistant component.

## Authority flow

The admin Client first posts a secret-free intent to
`/api/v1/admin/media/music-assistant/provider-commands/previews`. Core binds the
preview to the current admin session family and user revision, exact managed
installation ID/revision, exact ready provider setup ID/revision/domain, and a
canonical plan hash. The preview expires after ten minutes.

An explicit second action posts the preview ID, revision and plan hash to
`/api/v1/admin/media/music-assistant/provider-commands`. Core repeats admin,
installation and provider readiness checks. Request IDs make both stages
idempotent; changed actors, revisions, session families, plans, expired
previews and replacement installations fail closed.

The command is intentionally recorded as `blocked/effect_unavailable`.
`effectAvailable=false` and `installAvailable=false` are exact response types.
This slice makes no Music Assistant, Spotify, Apple Music or YouTube Music
network call and cannot change a real provider account.

## Privacy and Client behavior

Provider settings are exactly an empty object in this public contract. Extra
fields and secret-shaped settings are rejected before persistence. No token,
cookie, password, refresh token or provider form value is returned by the API,
rendered by the Client or written to this journal.

The tablet screen is admin-only and reached from the media preparation surface
behind the existing Settings PIN boundary. The current production entry is
explicitly targetless because Core does not yet expose a provider setup list to
the Client; it explains the unavailable boundary and cannot send a request.
Once the caller supplies an exact verified setup target, the screen retires
previews on PIN, account, route or app lifecycle changes and never retries or
confirms automatically. English and Turkish layouts are covered at 600 and
1280 logical pixels with 2× text; actions retain a minimum 48 dp target and
expose live status to TalkBack. Keyboard activation is covered for DeX.

## Open acceptance boundary

Provider effect execution remains unavailable until the retained private
Music Assistant worker has an upstream-version-pinned enable/disable command,
authenticated readback, cancellation/deadline handling and disposable native
acceptance. Real Spotify, Apple Music and YouTube Music account acceptance and
real HomePod playback also remain open. A bounded provider setup list/read
contract must supply the target IDs and revisions before the production entry
can expose enable or disable actions. This slice does not advance S06.5 or the
global progress counters.
