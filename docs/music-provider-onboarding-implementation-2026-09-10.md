# Managed Music Assistant provider onboarding

This slice gives Larenor Core a durable, encrypted setup-intent journal for the
packaged Music Assistant engine. An administrator selects Spotify, Apple Music,
or YouTube Music in Larenor Client. The public request contains only the managed
Music Assistant installation identity, its expected revision, the provider
domain, and an idempotency key. It never accepts an account password, Music
Assistant flow ID, callback URL, or arbitrary Music Assistant endpoint.
Provider setup fields are accepted only for the exact encrypted flow and schema
returned by Music Assistant.

A packaged worker starts and advances Music Assistant's own provider setup flow
through a UID-authenticated Unix socket. Core verifies each observed step
against the reviewed provider domain and initial-flow shape, encrypts the flow
ID, external URL, and field metadata, then exposes a secret-free receipt. The
Client sees only `open_external` or `submit_form` plus the names and secure/plain
types of fields it must render. No OAuth URL, state parameter, cookie, token, or
submitted value is persisted in the public record or returned by the API. Form
values remain inside the encrypted setup journal and private IPC request.

Form submission uses `config/flows/submit`; returning from Music Assistant's own
OAuth callback resumes with `config/flows/get`; explicit cancellation calls
`config/flows/abort`. Each Worker invocation has one deadline and makes no
retry. A `finish` result is provisional: the Worker must complete authenticated
`config/providers/get` readback whose `instance_id`, `domain`, and `loaded`
status exactly match the finished flow before Core records `ready`. Revision
and Music Assistant readiness are checked before
and after IPC, so a changed flow, installation, dependency, or concurrent
action fails closed. `installAvailable=false` remains unchanged.

Setup is allowed only while the revision-bound Music Assistant installation,
Home Assistant peer, and Jellyfin peer remain verified. A missing or stale
dependency blocks both new intents and worker discovery. Unexpected provider
domains, steps, URL origins, field names, field types, or required flags are
rejected as an upstream capability change. Product installation remains
`installAvailable=false`.

## Reviewed upstream contracts

The contract was reviewed on 2026-09-10 against Music Assistant 2.10.2 docs and
the current `dev` provider sources:

- [Provider setup-flow API](https://developers.music-assistant.io/setup-flows/):
  credentials and OAuth/pairing belong to server-driven setup sessions;
  `config/providers/setup {provider_domain}` starts a flow, flow steps expire,
  and collected `setup_data` is encrypted and never serialized over the API.
- [Spotify provider](https://www.music-assistant.io/music-providers/spotify/)
  and its [manifest](https://github.com/music-assistant/server/blob/dev/music_assistant/providers/spotify/manifest.json):
  domain `spotify`, stable, multi-instance. Setup begins with OAuth and then
  requires a separate playback backend choice and approval. Soloist additionally
  requires explicit terms, an API key, and in-app pairing.
- [Spotify setup source](https://github.com/music-assistant/server/blob/dev/music_assistant/providers/spotify/setup_flow.py):
  the initial step is `authenticate` at `accounts.spotify.com`; refresh tokens,
  playback credentials, and Soloist data remain Music Assistant setup data.
- [Apple Music provider](https://www.music-assistant.io/music-providers/apple-music/)
  and its [manifest](https://github.com/music-assistant/server/blob/dev/music_assistant/providers/apple_music/manifest.json):
  domain `apple_music`, stable, multi-instance. Normal authentication is a
  MusicKit browser step served from Music Assistant's own origin; an optional
  secure manual user token exists and reauthentication is expected.
- [Apple Music setup source](https://github.com/music-assistant/server/blob/dev/music_assistant/providers/apple_music/setup_flow.py):
  the first form is `app_token` only if the bundled app token is rejected;
  otherwise it is `user` with an optional secure `music_user_manual_token`.
- [YouTube Music provider](https://www.music-assistant.io/music-providers/youtube-music/)
  and its [manifest](https://github.com/music-assistant/server/blob/dev/music_assistant/providers/ytmusic/manifest.json):
  domain `ytmusic`, beta, multi-instance. It has no official third-party login
  API and requires a login cookie plus a compatible PO Token service.
- [YouTube Music setup source](https://github.com/music-assistant/server/blob/dev/music_assistant/providers/ytmusic/setup_flow.py):
  the initial `user` form contains `username`, secure `cookie`, and
  `po_token_server_url` exactly.

## Remaining boundary

Music Assistant still owns the external callback page and provider-specific
interactive steps; Larenor does not emulate upstream OAuth. Spotify, Apple
Music, and YouTube Music account access has not been tested with real accounts,
so this slice makes no real-account success claim. AirPlay/HomePod discovery and
playback are separate acceptance work and are not claimed here.
