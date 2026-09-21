# S07.2 automatic media flow acceptance

This production slice is accepted with the continuity work and unified package
dependency in `docs/s07-2-s07-3-software-closure-2026-09-21.md`.

| Acceptance criterion | Automated evidence | Remaining boundary |
| --- | --- | --- |
| One Core model joins request, download, import, and playable state | The authenticated Core authority/read API binds Seerr, qBittorrent, Sonarr, Radarr, and Jellyfin to one exact flow revision and exposes each stage with its source revision. A configured Core automatically uses its existing UID-private installation worker channel; production callers no longer have to replace `media_flow.provider`. | S07.1 supplies the accepted amd64/arm64 unified package and private worker path. |
| Missing coverage and partial import are explicit without duplicate season requests | Series fixtures expose missing episodes, an entirely missing requested season, partial import, and an already playable unrequested season as `requestable=false`. | Real Sonarr numbering exceptions and live Seerr season identifiers remain native fixture work. |
| Stale, replayed, changed, or unknown provider evidence fails closed | Snapshot age, exact revision vectors, before/after source equality, strict provider identities, current admin sessions, HMAC high-water storage, cancelled worker gates, strict IPC results, and secret-free errors are tested. The same installation worker remains the sole upstream state owner. | Physical service-account and interrupted-network acceptance remains in the final manual gate. |

TDD captured the production regression first: a configured installation worker
still returned `media_flow_provider_unavailable`. The same journey now reaches
the worker four bounded times across authority and read, then returns a playable
projection. The focused worker, supervisor, installation, music, and media-flow
suite passes 130 tests with one existing platform skip. Python compile, security
policy, queue validation, diff validation, and Gitleaks also pass.
