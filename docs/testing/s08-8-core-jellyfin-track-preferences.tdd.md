# S08.8 Core Jellyfin track preference slice

This slice moves the existing audio and subtitle language preference from
device-local, direct-Jellyfin-scoped storage to a bounded Larenor Core record.
It does not close `S08.8`: queue progress remains **25/125** and selected-feature
progress remains **0/63**.

## Accepted behavior in this slice

- The preference is owned by the exact current Core/home/account tuple. Reads
  and optimistic writes carry schema and record revisions, reject a mismatched
  Core authority, and survive a Core restart.
- The client sends no direct Jellyfin URL, user, access token, or device ID.
  The authenticated record stores only normalized audio and subtitle language
  tags. Server storage is bounded to 256 account rows and authenticated so
  malformed or tampered state fails closed.
- A retired player route cannot issue a preference read or write. Retirement
  while the initial Core read is pending is checked again before the PUT, so a
  stale player cannot publish a preference.
- The player discloses in English and Turkish that the language preference is
  saved for the Larenor account. The disclosure fits 600 px and 1200 px tablet
  widths at 2x text scale.

## TDD and validation evidence

RED commit `62220d029ac846e8e2a73ea0b49e29f5ff92e3ab` specified the server and
client contract. The server tests failed with three expected 404 responses and
the Flutter contract did not compile because the Core account dependency did
not exist. GREEN commit `00fc7a8fe2a0992c9b06a0343c7f5312f54e0c33`
implemented the Core API, persistent authenticated record, and account-scoped
client adapter.

The focused Flutter contract run passed **5/5** tests with **94/100 executable
store lines (94.0%)** covered. The EN/TR disclosure and player interaction run
passed at both tablet widths. The focused server API run passed **3/3** tests;
the `media_preferences` package covered **144/162 statements (89%)**. Targeted
Flutter analysis and Python bytecode compilation passed. The wider focused
regression runs cover player lifecycle, playback security, playback reporting,
Core runtime, and Core backup contracts.

## Remaining S08.8 acceptance

- Jellyfin catalog, search, provider onboarding, and playback transport still
  use the direct Jellyfin client rather than the central Larenor media API.
- The legacy device-local preference remains untouched. Import or deletion
  requires an explicit preview and user confirmation; this slice performs no
  silent migration.
- The wider media records, caches, provider/player mappings, and movie-night
  preferences still need the exact tuple/resource/schema/revision/TTL/quota
  contract.
- Authorization loss, same-URL Core replacement, and approved legacy migration
  still need integrated Client-to-local-Core E2E, independent review, and CI.
