# Larenor

*Unus Lar, omnem domum servat.*
*(One guardian spirit watches over the whole home.)*

A private, custom Home Assistant companion app built with Flutter. Larenor connects to
an existing self-hosted Home Assistant server over its REST and WebSocket APIs and
turns an Android tablet into a modern, drag-and-drop wall panel — plus an in-app admin
panel and a built-in media center for a self-hosted Jellyfin/*arr/qBittorrent stack.

This is not a fork of Home Assistant. It is a standalone client; you still need a
running Home Assistant instance on your network.

This repository and its contents are proprietary — see [LICENSE](LICENSE).

## Features

### Localization

- English and Turkish, following the device's system language automatically — no
  in-app language switch needed, and no language ever gets stuck after an update or
  reinstall since it just re-reads the OS setting. Falls back to English on any other
  device language.

### Home Assistant connection

- Connect with a server URL and a long-lived access token — no OAuth dance, just
  paste the token from your HA profile page.
- Automatic discovery of Home Assistant servers on the local network via mDNS/
  Zeroconf (HA's `zeroconf` integration), listed on the connect screen so you can
  tap one instead of typing the URL by hand.

### Dashboard

- Drag-to-move, corner-drag-to-resize tile grid — build a dashboard visually instead
  of hand-editing Lovelace YAML. Layout persists locally.
- Adding a tile is itself drag-and-drop: a widget gallery slides up from the bottom
  showing a live/illustrative preview card for every tile type, and dragging one onto
  the (still-visible) grid drops it at that exact spot — no menus or config dialogs.
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

Nine independent, optional integrations for a self-hosted media server setup — the app
works fine with zero, some, or all of them configured (see "Integrations management"
below for how they're toggled and surfaced). Each service's connect screen shows a
"Found on your network" list before you type anything: Jellyfin uses its own UDP
broadcast discovery protocol, and the rest are found by sweeping the local subnet for
a matching signature on their default port (no credentials needed for this — it's
purely a convenience to save typing an IP, tap a result to fill in the URL). Every
service also gets its real logo mark next to its name throughout the app instead of a
generic icon:

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

Full management of a self-hosted Proxmox VE server, independent of everything else in
the app:

- Connect with host/port/realm/username/password (ticket-based session auth, the same
  model Proxmox's own web UI uses) and an "allow self-signed certificate" toggle, since
  a fresh Proxmox install ships one by default. The connect screen also sweeps the
  local subnet for a matching host on Proxmox's default port beforehand.
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

A native client for Keenetic's unofficial RCI HTTP API, going further than Home
Assistant's own Keenetic integration (which only exposes device-tracker presence):

- Connect with the router's admin URL and web-UI credentials (challenge/response
  session auth, the same model the router's own web interface uses) — the URL field
  is pre-filled with the device's own default gateway, since that's almost always
  where the router actually is.
- Connected-devices list with live/offline status.
- Wi-Fi access point list (including guest networks) with an enable/disable toggle.
- Read-only port-forwarding/static-NAT rule list.

### Integrations management & dashboard widgets

All 11 optional integrations above (the 9 media services plus Proxmox and Keenetic)
are managed from one place — Settings → Manage Integrations — rather than as a flat
list, so the app stays uncluttered no matter how many services exist:

- Each service has its own on/off switch. Turning one off only hides it — it keeps its
  saved credentials, so turning it back on doesn't require reconnecting. Existing users
  are seeded as enabled for whatever they already had connected.
- The main Settings screen only shows a row for a service that's both switched on and
  actually connected, so an unused integration never shows up there at all.
- Every one of the 11 is also addable straight onto the dashboard as a live summary
  tile (continue watching, upcoming releases, active torrents, node CPU/RAM, connected
  devices, etc.) by dragging it from the widget gallery — no per-tile setup, since each
  tile just reads the service's existing app-wide connection. Tapping a tile opens that
  service's full screen.

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

Localization output (`lib/l10n/generated/`) is also not committed — it's
regenerated automatically by `flutter pub get`/`flutter run` (via
`flutter: generate: true` in `pubspec.yaml`), or manually with
`flutter gen-l10n`, from the source strings in `lib/l10n/app_en.arb` and
`lib/l10n/app_tr.arb`.

## Useful commands

```sh
flutter analyze                    # static analysis
flutter test                       # unit + widget tests
flutter build apk --debug          # debug Android build
dart run flutter_launcher_icons    # regenerate app icons after changing assets/icon/*.png
```
