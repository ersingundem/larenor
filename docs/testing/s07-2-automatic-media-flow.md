# S07.2 automatic media flow acceptance

Progress remains **17/125 (13.6%) delivery, 0/63 (0.0%) research**. This is a
PR-ready production slice; S07.2 stays open until its S07.1 dependency, exact
head CI, and native managed-stack fixtures are complete.

| Acceptance criterion | Automated evidence | Remaining boundary |
| --- | --- | --- |
| One Core model joins request, download, import, and playable state | The authenticated Core authority/read API binds Seerr, qBittorrent, Sonarr, Radarr, and Jellyfin to one exact flow revision and exposes each stage with its source revision. | The packaged S07.1 processes must supply the private provider in native amd64/arm64 CI. |
| Missing coverage and partial import are explicit without duplicate season requests | Series fixtures expose missing episodes, an entirely missing requested season, partial import, and an already playable unrequested season as `requestable=false`. | Real Sonarr numbering exceptions and live Seerr season identifiers remain native fixture work. |
| Stale, replayed, changed, or unknown provider evidence fails closed | Snapshot age, exact revision vectors, before/after source equality, strict provider identities, current admin sessions, and secret-free errors are tested. | Physical service-account and interrupted-network acceptance remains in the final manual gate. |
