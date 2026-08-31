# Oikos

A private, custom Home Assistant companion app built with Flutter. Oikos connects to
an existing self-hosted Home Assistant server over its REST and WebSocket APIs and
turns an Android tablet into a modern, drag-and-drop wall panel — plus an in-app admin
panel and a built-in media center for a self-hosted Jellyfin/*arr/qBittorrent stack.

This is not a fork of Home Assistant. It is a standalone client; you still need a
running Home Assistant instance on your network.

This repository and its contents are proprietary — see [LICENSE](LICENSE).

## Features

### Dashboard

- Drag-to-move, corner-drag-to-resize tile grid — build a dashboard visually instead
  of hand-editing Lovelace YAML. Layout persists locally.
- Tile types: entity card (state + toggle), fullscreen WebView (any URL, including the
  raw HA frontend), history/statistics graph, media player (play/pause/skip/volume,
  album art), climate/thermostat (radial dial), weather with forecast, scene
  (one-tap `scene.turn_on`), and camera (live snapshot polling).
- Tap-through "more info" popup on every entity tile — full state, attributes, and
  controls, not just the inline toggle.
- Favorites section — pin frequently used entities to the top of the dashboard.
- Connection-status banner ("Home Assistant unreachable, retrying…") instead of a
  small status dot, with WebSocket reconnect-with-backoff underneath it.
- Broad brand/device coverage: icons and controls for lights, switches, locks (state-
  aware), vacuums, humidifiers, valves, sirens, alarm panels, covers, fans, climate,
  media players, cameras, device trackers (e.g. Keenetic presence), water heaters,
  scenes, persons, timers, scripts, updates, numbers, selects, and buttons, plus
  device-class-aware sensor/binary_sensor icons (battery, power/energy, temperature,
  motion, connectivity, etc. — covers what integrations like Anker Solix, Xiaomi,
  Sonoff, Philips Hue, Apple HomeKit, and eWeLink commonly expose). Home Assistant's
  domain/device_class model is brand-agnostic, so rendering every domain and device
  class well is what makes the app work with virtually any HA-supported brand,
  including ones only available through a HACS custom integration installed on the
  server itself.

### Home Assistant admin panel

Reachable from Settings, styled with the same Cupertino/iOS design language as the
rest of the app:

- **Integrations** — list, reload, delete existing config entries; add a new
  integration through HA's real config-flow protocol with a generic dynamic form
  engine (text/number/boolean/select fields, with a JSON-editor fallback for rarer
  selector kinds).
- **Devices**, **Areas**, **Entities** — browse the device/entity/area registries;
  enable or disable entities.
- **Automations** — list with enable/disable/trigger/delete, last-triggered
  timestamps, and a raw JSON config editor for viewing, hand-editing, and creating
  automations.
- **Cameras** — a dedicated grid of live camera snapshots, tap to expand.

### Kiosk / wall-panel mode

- Android `HOME` intent-filter so the app can be set as the tablet's default launcher.
- Keep-screen-on toggle (wakelock).
- Scheduled day/night screen brightness dimming and screen-off/do-not-disturb hours.
- Idle/ambient mode — after N minutes of no touch input, switch to a low-distraction
  clock + weather screen (reduces burn-in on an always-on panel).
- PIN lock on Settings, so leaving kiosk mode or changing the server connection
  requires a PIN.

### Media stack

Five independent, optional integrations for a self-hosted media server setup, each
connected separately from its own row under Settings → Media Services — the app works
fine with zero, some, or all five configured:

- **Jellyfin** — connect with a username/password, browse continue-watching/recently-
  added/libraries, and play through a built-in `media_kit` (libmpv) video player. The
  player negotiates a device profile with the server so playback decodes on the
  tablet and prefers Direct Play over server-side transcoding, keeping load off the
  Jellyfin server. Playback progress is reported back to Jellyfin so resume/continue-
  watching works.
- **Jellyseerr** — connect with a server URL + API key, search movies/TV, submit
  requests, and track request status ("My Requests").
- **Sonarr** / **Radarr** — connect each with a server URL + API key; view the
  upcoming release calendar and active download queue with progress; full search-
  and-add flow using each server's own lookup endpoint, with quality-profile and
  root-folder pickers before confirming.
- **qBittorrent** — connect with a server URL + username/password; view torrents with
  progress/speed/state, pause/resume/delete; add torrents via a pasted magnet link or
  by uploading a `.torrent` file from the device.
- **Bazarr** — connect with a server URL + API key; view movies and episodes missing
  subtitles, trigger a search-and-download per missing language.
- **Prowlarr** — connect with a server URL + API key; list configured indexers with an
  enable/disable toggle.
- **Lidarr** / **Readarr** — connect each with a server URL + API key; the same
  calendar/queue monitoring and search-and-add flow as Sonarr/Radarr, plus a
  metadata-profile picker alongside quality profile and root folder.

### Proxmox VE management

Reachable from Settings → Infrastructure — full management of a self-hosted Proxmox VE
server, independent of everything else in the app:

- Connect with host/port/realm/username/password (ticket-based session auth, the same
  model Proxmox's own web UI uses) and an "allow self-signed certificate" toggle, since
  a fresh Proxmox install ships one by default.
- Node list with CPU/RAM/disk usage bars, drilling into each node's VMs, containers,
  and storage.
- Power control — start/shutdown/stop/reboot/suspend/resume — through a status-aware
  action sheet that only shows actions valid for the guest's current state.
- Guest detail/edit screen: structured fields for name/hostname, CPU cores, memory, and
  start-on-boot, plus every other config key as a raw editable field.
- Create a new VM or container by cloning an existing template, with a target-storage
  picker and live task-progress polling.
- Storage and backup browsing, with an on-demand "back up now" action.
- An embedded interactive console — noVNC for VMs, xterm.js for containers — running
  inside a WebView against Proxmox's console WebSocket endpoints.

### Keenetic router management

Reachable from Settings → Infrastructure — a native client for Keenetic's unofficial
RCI HTTP API, going further than Home Assistant's own Keenetic integration (which only
exposes device-tracker presence):

- Connect with the router's admin URL and web-UI credentials (challenge/response
  session auth, the same model the router's own web interface uses).
- Connected-devices list with live/offline status.
- Wi-Fi access point list (including guest networks) with an enable/disable toggle.
- Read-only port-forwarding/static-NAT rule list.

## Status

Actively developed. Core dashboard, HA admin panel, kiosk/wall-panel behavior, the
Jellyfin/Jellyseerr/Sonarr/Radarr/Lidarr/Readarr/Bazarr/Prowlarr/qBittorrent media
stack, Proxmox VE management, and Keenetic router management are all implemented and
covered by CI (static analysis, unit/widget tests, debug Android build). Deferred for
later: OAuth2/PKCE login, true kiosk lock-task mode, push notifications, an Assist
voice satellite, multi-profile/guest-mode dashboards, room-based dashboard tabs, a
theme editor, and iOS build/signing (Apple does not allow third-party home-screen
launchers, so the eventual iOS build will be a single-app kiosk, not a true launcher).

## Development setup (macOS)

```sh
brew install --cask temurin@17 flutter android-commandlinetools
flutter doctor --android-licenses
flutter doctor -v
```

Then, from the repo root:

```sh
flutter pub get
dart run build_runner build
flutter run
```

Generated code (`*.g.dart`, `*.freezed.dart`) is not committed — regenerate it
with the `build_runner` command above after every checkout or after changing
any `@freezed`/`@riverpod`/`@JsonSerializable`-annotated file. If you hit
stale/conflicting generated output, run `dart run build_runner clean` first.

## Useful commands

```sh
flutter analyze              # static analysis
flutter test                 # unit + widget tests
flutter build apk --debug    # debug Android build
```
