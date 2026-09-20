# S07.2 automatic media flow acceptance

Progress remains **17/125 (13.6%) delivery, 0/63 (0.0%) research**. This is a
PR-ready production slice; S07.2 stays open until its S07.1 dependency, exact
head CI, and native managed-stack fixtures are complete.

| Acceptance criterion | Automated evidence | Remaining boundary |
| --- | --- | --- |
| One Core model joins request, download, import, and playable state | The authenticated Core authority/read API binds Seerr, qBittorrent, Sonarr, Radarr, and Jellyfin to one exact flow revision and exposes each stage with its source revision. A configured Core automatically uses its existing UID-private installation worker channel; production callers no longer have to replace `media_flow.provider`. | S07.1 must supply the native amd64/arm64 service collector behind that worker operation. |
| Missing coverage and partial import are explicit without duplicate season requests | Series fixtures expose missing episodes, an entirely missing requested season, partial import, and an already playable unrequested season as `requestable=false`. | Real Sonarr numbering exceptions and live Seerr season identifiers remain native fixture work. |
| Stale, replayed, changed, or unknown provider evidence fails closed | Snapshot age, exact revision vectors, before/after source equality, strict provider identities, current admin sessions, HMAC high-water storage, cancelled worker gates, strict IPC results, and secret-free errors are tested. The same installation worker remains the sole upstream state owner. | Physical service-account and interrupted-network acceptance remains in the final manual gate. |

TDD captured the production regression first: a configured installation worker
still returned `media_flow_provider_unavailable`. The same journey now reaches
the worker four bounded times across authority and read, then returns a playable
projection. The focused worker, supervisor, installation, music, and media-flow
suite passes 130 tests with one existing platform skip. Python compile, security
policy, queue validation, diff validation, and Gitleaks also pass.
