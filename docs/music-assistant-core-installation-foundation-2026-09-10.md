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

## Authenticated readiness and automatic peer wiring

Larenor Core now has a private worker handoff for an authenticated Music
Assistant `info` readback. The worker supplies the access token and verified
identity directly to Core; neither value is accepted by the admin HTTP API.
Core encrypts the complete readback with installation and record revisions in
the AEAD associated data. Its public, read-only readiness route returns only the
server/schema versions and revision-bound references to the selected peers.

Peer discovery selects exactly one authenticated Home Assistant record and one
authenticated Jellyfin record from Larenor's encrypted service store. Missing,
unverified, or ambiguous peers block the handoff. Later changes to either
service revision or to the managed Music Assistant installation change the
readiness state to `needs_attention`; the old credential is never copied into a
receipt, log, URL, or response. Users are therefore not asked to copy an
endpoint or token between Larenor-managed components.

## Remaining acceptance boundary

- Provider setup for Spotify, Apple Music, and YouTube Music is not automated.
- Player/provider registration and the worker operation that creates the first
  Music Assistant access token are not implemented. The authenticated handoff
  and automatic Home Assistant/Jellyfin peer selection are ready for that
  operation.
- Active health polling and upgrade reconciliation are not part of the
  container-started receipt.
- HomePod/AirPlay, Chromecast, and lock-screen playback require real-device
  acceptance before `installAvailable` may become true.
- CasaOS and Proxmox packaging still consume the existing deployment path; this
  slice does not publish or install a release.
