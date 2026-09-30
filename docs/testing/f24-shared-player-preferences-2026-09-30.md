# F24 shared player preference store — 30 September 2026

The legacy Jellyfin preference endpoint and active player language preference endpoint now read and write the same encrypted per-account record. Compare-and-swap revisions, current account/session authority and home scope stay enforced. Existing authenticated legacy rows migrate atomically at Core startup; explicit writes in the current player store take precedence. Corrupt records or merged capacity overflow stop startup; migration never resets preferences.

Bounded language tags such as `zh-hant-tw` survive migration and the Client contract. Preferences only match available supported audio/subtitle tracks; a preferred language does not create a missing track. Subtitle provider access remains a separate configured provider path.

Executed on this branch:

- `PYTHONPATH=server server/.venv/bin/python -m pytest server/tests/test_f24_preference_store_unification.py server/tests/test_jellyfin_track_preferences_api.py server/tests/test_media_language_preferences_api.py`: 10 passed.
- Focused Flutter language API, player preference and track matching tests: 8 passed.
- `PYTHONPATH=server server/.venv/bin/python server/tests/support/f24_flutter_acceptance.py`: 1 real Flutter Client → normal Core TCP test passed. Legacy PUT is observed through the active player API; player save is observed through legacy GET; the runner verifies no legacy row was written and the canonical revision is 2.
- Scoped analyze: no issues.

Full current HEAD CI, complete cross-feature acceptance and physical provider/device gates remain open. This is implementation evidence, not final feature acceptance.
