/// Every optional external integration the app supports, beyond the core
/// Home Assistant connection — each toggleable independently so a user who
/// only cares about two or three of these doesn't see the rest.
enum AppService {
  jellyfin,
  jellyseerr,
  sonarr,
  radarr,
  lidarr,
  readarr,
  bazarr,
  prowlarr,
  qbittorrent,
  proxmox,
  keenetic,
}
