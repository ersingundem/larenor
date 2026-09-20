# S07.3 Music Core API software acceptance

This slice extends the existing encrypted Music Assistant Core, provider setup,
and playback journal. It does not add a second music service or accept a Music
Assistant address/token from Client. The unified API is rooted at
`/api/v1/admin/media/music-assistant/manager` and reuses the existing private,
UID-authenticated worker channel.

## Three acceptance criteria

| Criterion | Accepted software behavior | Evidence |
| --- | --- | --- |
| One manager surface | `refresh` returns the exact ready provider bindings, bounded queue summaries, and verified receivers together. `catalog/search` searches one revision-bound provider, while `commands` uses the same manager revision and receiver identity. The older playback endpoints remain compatible but no second service or state owner is introduced. | `test_one_manager_surface_aggregates_provider_catalog_queue_and_receivers`; manager API/OpenAPI models; runtime and IPC tests |
| Secret and revision boundary | Public models contain provider instance IDs and revisions, never the Music Assistant token, setup values, cookies, or OAuth data. Private token/action fields have redacted representations. Installation, Core, manager, provider setup, provider instance, session, and worker gates are rechecked around reads/effects. Provider drift before or during catalog readback fails closed and discards the result. | `test_provider_revision_drift_fails_closed_before_catalog_worker`; `test_provider_revision_drift_during_catalog_readback_discards_result`; wrong-provider and IPC secret tests |
| Receiver and effect proof | HomePod/AirPlay and Chromecast receivers retain distinct target kinds and advertised seek/queue capabilities. Play and pause require a matching player-state readback; seek requires queue-position readback; add/replace/clear require the expected queue change. A successful HTTP effect without that readback is never a successful receipt. | `test_authenticated_discovery_exposes_cast_and_seek_capabilities`; transport post-effect success/failure matrix; API idempotency and uncertain-effect tests |

The catalog adapter follows Music Assistant server source revision
`5743a51a3ee829d3e173142a7b251f106d8c83ac`: `music/search` receives the exact
provider instance allowlist, while the serialized `SearchResults` field for
radio stations is the singular `radio`. Results that identify the selected
provider by its documented domain form are normalized back to the verified
instance ID before Core returns them. A second provider is never queried or
accepted by the Client-facing result.

## Verification boundary

The focused Server suite exercises the real FastAPI routes, encrypted SQLite
journals, strict Pydantic contracts, private Unix IPC, and fixed Music Assistant
HTTP command adapter with local deterministic fakes. It does not claim real
Spotify, Apple Music, YouTube Music, HomePod, Chromecast, CasaOS, or Proxmox
acceptance. Those remain manual gates.

`uv run --locked --no-sync python -m pytest -q tests/test_music_*.py
tests/test_api_boundary.py` passed **125/125** tests. Python compilation,
`git diff --check`, the 125-task/63-feature execution-queue validator, and the
repository gitleaks policy also passed.

S07.3 remains **pending** because its declared dependency S07.1 has not merged.
This branch therefore keeps execution progress at **17/125** and records no
feature completion. After S07.1 merges, this exact software evidence must be
rebased and CI must pass before S07.3 can close.
