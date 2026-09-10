# Music Assistant Core installation foundation

This slice makes the packaged Music Assistant component a durable, plan-derived
Larenor Core installation target. The admin installation API can queue it, the
encrypted installation journal survives a Core restart, and the private worker
IPC accepts only the component and step IDs regenerated from the signed catalog
plan. Product installation remains deliberately unavailable until service
bootstrap and real-device acceptance are complete.

The worker creates the container from the catalog's platform-specific immutable
digest. Its only persistent mount is the Core-owned application-data volume at
`/data`; callers cannot supply image names, Docker JSON, host paths, ports,
networks, capabilities, or environment variables. The generated binding keeps
all capabilities dropped except `NET_BIND_SERVICE`, enables
`no-new-privileges`, uses a read-only root filesystem, and exposes no Docker port
bindings.

Music Assistant is the catalog-approved host-network exception because local
player discovery and HomePod/AirPlay traffic require multicast and dynamic
receiver ports. The managed-container verifier therefore requires exactly the
Docker `host` network and rejects bridge changes, extra networks, security drift,
unexpected environment values, and foreign mounts. The worker still proves the
Core control-network journal in the same transaction so the common stack plan
and resource journals remain one authority; Music Assistant is not attached to
that network by this slice.

## Remaining acceptance boundary

- Provider setup for Spotify, Apple Music, and YouTube Music is not automated.
- Home Assistant, Jellyfin, and player-provider auto-wiring is not implemented.
- Music Assistant health/readiness, authenticated API readback, and upgrade
  reconciliation are not part of the container-started receipt.
- HomePod/AirPlay, Chromecast, and lock-screen playback require real-device
  acceptance before `installAvailable` may become true.
- CasaOS and Proxmox packaging still consume the existing deployment path; this
  slice does not publish or install a release.
