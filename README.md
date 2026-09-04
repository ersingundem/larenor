# Larenor

<img src="assets/icon/app_icon.png" alt="Larenor" width="96" />

*Unus Lar, omnem domum servat.*

A private, custom Home Assistant companion app built with Flutter. Larenor connects to
an existing self-hosted Home Assistant server over its REST and WebSocket APIs and
turns an Android tablet into an Apple Home-inspired wall panel — plus an in-app admin
panel, a unified Netflix-style media hub over a self-hosted Jellyfin/*arr/qBittorrent
stack, and infrastructure management for Proxmox VE and Keenetic routers.

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

- Connect with a server URL and a long-lived access token from your HA profile.
  The REST client preserves reverse-proxy prefixes, validates API paths, rejects
  cross-server redirects and reports structured authentication/permission errors.
- Automatic discovery of Home Assistant servers on the local network via mDNS/
  Zeroconf (HA's `zeroconf` integration), listed on the connect screen so you can
  tap one instead of typing the URL by hand.

### Dashboard

- Apple Home-inspired Cupertino interface with adaptive light/dark backgrounds,
  rounded accessory cards and clear active, inactive and unavailable states. Wide
  tablets get a room sidebar; smaller screens get a horizontal room selector.
- An overview shows the number of displayed accessories, lights switched on and
  unavailable devices. Room selection and category chips (Lights / Climate /
  Security / Media) help narrow the view.
- Rooms are yours to create, rename, reorder and remove. Add multiple accessories
  to a room from the device picker; removing one from a room does not delete it
  from Home Assistant. Saved room layouts and favourites survive app restarts.
- **Import Home Assistant rooms** provides an optional starting point. It resolves
  an accessory's own `area_id`, then its device's area, and puts unassigned
  accessories in "Other". Importing merges matching room names without duplicate
  accessories; later HA registry updates do not overwrite your manual layout.
  Without registry access, eligible entities can still be selected manually or
  imported into "Other".
- The picker focuses on controllable domains and useful sensor device classes
  (temperature, humidity, motion, door…) rather than diagnostic entities. The
  dashboard displays the accessories you selected, not every entity automatically.
- Tap a supported accessory to toggle it; locks and covers open their detail sheet.
  Long-press for details, favourite/unfavourite, or removal from its room.
  Favourites appear at the top. Service-call failures are shown to the user.
- A "Services" section carries the 11 external-service summary tiles (continue
  watching, upcoming releases, active torrents, node CPU/RAM…), and a "Widgets"
  section holds the two hand-added kinds with no HA entity behind them: a fullscreen
  WebView (any URL, including the raw HA frontend) and a history/statistics graph.
- Tap-through "more info" popup on every accessory — full state, attributes, and
  controls, not just the inline toggle.
- Connection-status banner ("Home Assistant unreachable, retrying…") instead of a
  small status dot, with retry/pull-to-refresh controls and WebSocket reconnect
  with backoff. A fresh snapshot is fetched after reconnecting; updates arriving
  during a snapshot request are preserved, including entity removals. Heartbeats
  detect dead sockets; live tool subscriptions acknowledge setup and stop cleanly
  on disconnect. Timed-out device mutations are never automatically retried.
- Broad brand/device coverage: icons and controls for lights, switches, locks (state-
  aware), vacuums, humidifiers, valves, sirens, alarm panels, covers, fans, climate,
  media players, cameras, device trackers (e.g. Keenetic presence), water heaters,
  scenes, persons, timers, scripts, updates, numbers, selects, and buttons, plus
  device-class-aware sensor/binary_sensor icons (battery, power/energy, temperature,
  motion, connectivity, etc. — covers what integrations like Anker Solix, Xiaomi,
  Sonoff, Philips Hue, Apple HomeKit, and eWeLink commonly expose). Home Assistant's
  domain/device_class model is brand-agnostic, so rendering every domain and device
  class allows the same controls to serve many HA-supported brands, including
  entities exposed by HACS integrations. Actual support depends on each entity
  domain and the capabilities exposed by the server.

### Home Assistant actions, tools and administration

Settings → Home Assistant uses the same adaptive Cupertino layout as Home and Media.

- **Actions** discovers every action advertised by the connected server, including
  installed custom integrations. Search by domain, name or description; select
  entity targets or enter device/area/floor/label targets; edit typed fields; request
  and inspect service response data when supported. Required fields and numeric
  limits are validated. Advanced JSON supports additional and complex parameters.
  An accessory's details links directly to actions for that domain.
- **Device controls** in the accessory sheet include climate mode/temperature and
  dual setpoints, cover position/open/close/stop, lock/unlock with unlock confirmation, fan speed,
  number/select helpers and media transport/volume. Live action availability and
  entity features constrain what appears. Sliders submit on release; errors and
  duplicate-request guards apply to these controls.
- **Developer tools** provides server information, history/activity queries,
  calendars, templates, logs and configuration checks. Events can be listed or
  watched live; the viewer retains the latest 50 messages. The REST/WebSocket
  console supports additional server commands and explicit subscription mode.
- **Integrations** supports discovery/setup, options, reconfiguration, pending
  discovery/reauthentication flows, rename, enable/disable, reload and removal.
  Native fields cover text, numeric, boolean, select and entity/device/area pickers;
  other selectors use validated JSON. External authentication steps open their
  provided page and resume the server flow.
- **Devices / Areas / Entities** offers native registry editors: area creation,
  rename/removal; device name/area/enabled state; entity name/icon/area/ID and
  enabled/hidden state. Entity ID changes also migrate local room, favourite,
  hidden-entity and tile references.
- **Automations** supports listing, enabling/disabling, running, duplication and
  JSON configuration create/edit/delete. The full visual editor and traces remain
  available in Home Assistant's own frontend.
- **Cameras** provides live snapshot browsing and image expansion.
- **Home Assistant workspace** opens the official frontend inside the app for
  server-specific panels such as Energy, maps, backups, Assist and custom
  dashboards. It uses its own sign-in session; the app never injects its long-lived
  API token into web scripts or browser storage. Browser/platform-dependent
  functions such as microphone capture and downloads need separate device testing.

The [API coverage matrix](docs/home-assistant-api-coverage.md) distinguishes native
screens, Dart API methods, generic tools and the embedded frontend. A transport
method or a displayed action is **not** proof that every HA feature has a native
UI or that every device action was executed. State writes only change HA's state
representation; physical devices are controlled through actions.

### Kiosk / wall-panel mode

- Android `HOME` intent-filter so the app can be set as the tablet's default launcher.
- Always runs fullscreen (status/navigation bars hidden), reapplied automatically on
  every resume so it stays hidden after backgrounding, permission dialogs, etc.
- Keep-screen-on toggle (wakelock).
- Scheduled day/night screen brightness dimming and screen-off/do-not-disturb hours.
- Idle/ambient mode — after N minutes of no touch input, switch to a low-distraction
  clock + weather screen (reduces burn-in on an always-on panel).
- PIN lock on Settings, so leaving kiosk mode or changing the server connection
  requires a PIN.

### Media hub

One Netflix-style surface across every connected media service, instead of a screen
per service. Reachable from the dashboard's media shortcut or Settings → Integrations.
The hub follows the same light/dark appearance, page palette, navigation and
typography as Home and Settings, with a cinematic artwork area, poster rows and
All / Movies / TV filters. Netflix account login, Netflix's catalogue and direct
Netflix playback are not implemented; playback uses your connected Jellyfin server.

- **Browse** — a featured hero plus poster rows: Continue Watching and Recently Added
  from Jellyfin, Trending from Jellyseerr, Coming Soon from the merged Sonarr/Radarr
  calendars, and everything currently Downloading. A row hides itself when the service
  behind it isn't connected, so the hub works with any subset — Jellyfin alone,
  Jellyseerr alone, or all of them.
- **Search** — one box across your library and the requestable catalogue. Without
  Jellyseerr, connected Sonarr/Radarr lookup endpoints provide discovery and the
  add-to-library flow. Matching titles are deduplicated by known provider IDs;
  the result shows its availability.
- **One page per title** — the point of the whole thing. Its primary button resolves
  from actual state: **Play** if it's in Jellyfin, **Request** through Jellyseerr if it
  isn't, **Add to library** via Sonarr/Radarr if you don't run Jellyseerr, or live
  download progress if a grab is already underway. Below it: monitored state and
  Bazarr's missing-subtitle count for that exact title.
- **How the join works** — TMDB id is the key. Jellyseerr is TMDB-native, Radarr keys
  on `tmdbId`, Sonarr carries one alongside `tvdbId`, and Jellyfin exposes all three
  through `ProviderIds`. A single index is built once per refresh from the Jellyfin,
  Sonarr and Radarr libraries and stores each title under *every* id it knows, so a
  TVDB-only Sonarr entry still meets a TMDB-only Jellyseerr result. Films and TV
  sharing a numeric id never collide, since kind is part of the key. Episode IDs
  are kept separate from series IDs so continue-watching items resolve to the
  correct show. Jellyfin library indexing follows pagination beyond 2,000 items.
- **TV playback** — series open a season/episode browser with watched and resume
  progress; actual episodes are passed to the player. A continue-watching episode
  resumes that episode rather than attempting to play a series container.
- Posters are disk-cached and content-addressed by Jellyfin's own image tags, so
  artwork survives a cold start and is only re-fetched when it genuinely changes.

Lidarr and Readarr stay on their own screens — music and books need a different
identity scheme (MusicBrainz/Goodreads, not TMDB) and suit a poster-row layout poorly.

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
  added/libraries, and play through a built-in `media_kit` (libmpv) video player with
  fully custom Cupertino controls (no stock Material overlay). The player negotiates a
  device profile with the server so playback decodes on the tablet and prefers Direct
  Play over server-side transcoding, keeping load off the Jellyfin server; a manual
  quality/bitrate picker is available too, for capping playback to a lower ceiling on
  demand. Playback progress is reported back to Jellyfin so resume/continue-watching
  works. Subtitle and audio track pickers switch between a file's embedded tracks
  on the fly. iOS-style edge gestures: swipe up/down on the left half of the screen
  for brightness, right half for volume, double-tap either side to seek ±10s.
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

Management of nodes, guests, storage and tasks on a self-hosted Proxmox VE server:

- Connect with host/port/realm/username/password and an "allow self-signed
  certificate" preference. Pasted HTTPS URLs and explicit ports are accepted;
  local discovery can suggest hosts. Ticket sessions renew before expiry and
  recover once from an explicit authentication rejection.
- Node list with CPU/RAM usage, drilling into VMs, containers and storage usage.
- Power control — start/shutdown/stop/reboot/suspend/resume — through a
  status-aware action sheet. Templates have no power menu; paused VMs expose
  resume. The UI waits for the task result and displays failures.
- Guest editing has name/hostname, CPU cores, memory and start-on-boot controls,
  plus advanced configuration fields. Only changed values are submitted, with
  the original configuration digest to detect concurrent edits. Internal
  bookkeeping fields are excluded and the container privilege flag is read-only.
- Clone an existing VM/container template, with a cluster-wide next-ID suggestion,
  full/linked clone choice and a storage picker that matches the guest type.
  Linked clones use the source storage; task completion and errors are shown.
- Storage and backup browsing, with an on-demand "back up now" action that waits
  for the task result and refreshes storage/backup data after success.
- **Activity** lists recent tasks and their running/success/failure states. Open
  a task to read its log; running tasks refresh automatically. The log currently
  shows up to the first 500 lines.
- An authenticated in-app WebView loads the noVNC or xterm console served by the
  connected Proxmox version. This uses the server's own ticket handling and
  terminal protocol rather than the old bundled console wrappers. The same
  self-signed certificate preference applies to the console.

### Keenetic router management

A native client for Keenetic's unofficial RCI HTTP API, going further than Home
Assistant's own Keenetic integration (which only exposes device-tracker presence):

- Connect with the router's admin URL and web-UI credentials (challenge/response
  session auth, the same model the router's own web interface uses) — the URL field
  is pre-filled with the device's own default gateway, since that's almost always
  where the router actually is.
- Router summary with model, firmware, hostname, CPU/RAM usage and uptime when
  the firmware provides those values, plus device and Wi-Fi counts.
- Connected-devices list with online/offline status, online-only filtering and
  search by name, IP, MAC or interface. Device details show IP/MAC, interface and
  registration status; addresses can be copied.
- Wi-Fi access point list, including guest networks, with SSID/interface details.
  Enable/disable commands show pending/error states and save the router
  configuration. Disabling Wi-Fi asks for confirmation because it can disconnect
  the tablet.
- Read-only port-forwarding/static-NAT rule list; creating or changing rules is
  not implemented.
- Session cookies are retained across challenge/response exchanges and renewed
  after an explicit authentication rejection. Router command failures are
  checked even when the HTTP response is successful. RCI is an unofficial API,
  so firmware-specific behavior still needs testing on the actual router.

### Integrations management & dashboard widgets

All 11 optional integrations above (the 9 media services plus Proxmox and Keenetic)
are managed from one place — Settings → Manage Integrations — rather than as a flat
list, so the app stays uncluttered no matter how many services exist:

- Each service has its own on/off switch. Turning one off only hides it — it keeps its
  saved credentials, so turning it back on doesn't require reconnecting. Existing users
  are seeded as enabled for whatever they already had connected.
- The Settings → Integrations pane only shows a row for a service that's both switched
  on and actually connected, so an unused integration never shows up there at all.
- Every switched-on service also appears in the dashboard's Services section as a live
  summary tile (continue watching, upcoming releases, active torrents, node CPU/RAM,
  connected devices, etc.) — no per-tile setup, since each tile just reads the
  service's existing app-wide connection. Tapping a tile opens that service's full
  screen.

### Settings

- An iPad-style split view: the categories (Connection, Display & Brightness,
  Security, Backup and restore, Home Assistant, Integrations, About) stay listed down the left while the
  selected one fills the right half. Drilling into a category — say Integrations → a
  config flow — keeps the master list visible beside it.
- On a display too narrow for two useful panes it falls back to the plain iOS
  behaviour of pushing each category full-screen, so phones and portrait are
  unaffected. The switch is width-driven, not orientation-driven.

### Shared navigation and search

- Home, Media, Routines and System use persistent branch navigation: phone tabs
  become a sidebar in wider windows. Room selection and scroll survive a tab
  round trip and window resizing. Configuration stays behind the Settings PIN.
- Global local search finds rooms, member devices, scenes/scripts, cached media
  and configured services. Turkish matching, stable identifiers, media alias
  deduplication and virtualized results are tested with 5,000 entities.
- Search opens details without executing actions. Remote catalog search is an
  explicit choice. System rows distinguish a saved configuration from a live
  server read; opening the list alone does not log in to all servers.
- Room/entity/media/service routes handle missing items; daily service views send
  account configuration actions to protected Settings.

### Configuration backup and reinstall recovery

- Settings → Backup and restore saves a password-encrypted `.larenor-vault` file
  using the system file picker. Rooms/cards/favorites, preferences and optional
  service credentials can be restored from the fresh-install connection screen.
- Credentials default off; PIN, failed-attempt state, cookies, temporary sessions
  and Jellyfin installation identity are excluded. A separate 12+ character
  passphrase protects AES-256-GCM encryption; PBKDF2 runs off the UI isolate.
- Restore validates all content before writing, previews conflicts, preserves
  existing settings by default, and uses a secure journal to recover interrupted
  writes before clients start. Native file-picker return rechecks the Settings PIN.
- Normal updates should use the same release identity without uninstalling. The
  first transition from a differently signed debug installation needs a backup.
  [Vault details](docs/configuration-vault.md).

### Performance, stability and security

- Dashboard subscriptions isolate room structure, summary counts and individual
  accessories. Bursts of Home Assistant state changes are merged before UI
  publication; unrelated diagnostic changes do not redraw the room layout.
- Media requests start alongside library indexing, and Arr queue reads are shared
  within a refresh. Camera/task polling pauses in the background, avoids overlap,
  and rejects results from a previous entity or connection.
- Authenticated native integration HTTP clients reject redirects, foreign origins,
  proxy-path escapes and malformed authentication headers. Configure the final
  server URL directly. Proxmox's optional self-signed TLS exception is restricted
  to its configured host/port. Local HTTP remains supported.
- Settings PIN attempts are serialized and persisted in secure storage. Five wrong
  attempts cause a 30-second pause, escalating to five minutes; backgrounding
  relocks Settings and closes protected drilldown screens. New PINs require 4–12
  digits. This protects shared-tablet Settings, not HA server-side authorization.
- Android cloud backup and device-transfer rules exclude credentials, WebView
  sessions and local home metadata. Release builds require private signing keys;
  they never fall back to the debug key.
- CI pins external actions and Flutter, enforces the dependency lockfile, cancels
  superseded runs, limits job/test duration, preserves test logs/coverage, and
  tests Android backup policies and release-signing failure without private keys.

See the [hardening review and next improvements](docs/performance-security-review-2026-09-05.md)
for measured regression evidence, device-test limits and remaining transport work.

### Brand and design

- The single brand motto is **Unus Lar, omnem domum servat.**
- App branding and launcher icons share the house/guardian emblem. Android includes
  adaptive and monochrome vectors; iOS includes the generated icon sizes.
- Home, Settings and Media share an adaptive page surface and Inter/Cupertino type
  hierarchy. Phone/tablet, light/dark and larger-text layouts are checked in widget
  tests. [Design previews](docs/previews/) use synthetic fixture data.

## Status

Actively developed. The features described above have implemented client flows,
with unit/widget tests and CI workflows for formatting, static analysis and a debug
Android build. This is not a claim of complete coverage of every Home Assistant
entity, media configuration, Proxmox operation or Keenetic firmware. Live router, media playback,
server mutation and Android-device verification remains separate from mocked API tests.

The [4 September 2026 implementation review](docs/implementation-review-2026-09-04.md)
records the current changes, validation status and remaining limitations.
Read-only compatibility was checked against **HA 2026.8.3** with the actual Dart
clients: 294 actions / 384 fields, 360 state models, 94 devices, 8 areas, 668 registry
entries and 46 config entries. History and WebSocket subscription lifecycle also
passed. No live device action or server edit was performed. Calendar was absent
on that server; successful calendar behavior is verified with mocks.

The [next integration plan](docs/integration-roadmap-2026-09-04.md) compares other
GitHub projects and proposes Music Assistant, Frigate, AdGuard Home/Uptime Kuma,
Immich and Paperless-ngx in phases. These are proposals, not shipped integrations.

Deferred work includes OAuth2/PKCE login, true Android kiosk lock-task mode, push
notifications, an Assist voice satellite, multi-profile/guest-mode dashboards,
a theme editor, and iOS build/signing. Direct Netflix integration, Proxmox backup
restore/migration/snapshot management, and Keenetic port-forwarding edits are not
provided by the current UI. Release signing and distribution also require owner
configuration; the development build is a debug APK.

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
flutter test --coverage             # unit, widget, security + performance regressions
flutter build apk --debug          # debug Android build
dart run flutter_launcher_icons    # regenerate app icons after changing assets/icon/*.png
```

### Android release signing

Debug builds work without signing secrets. For a release, provide an ignored
`android/key.properties` with `storeFile` (absolute path to your keystore),
`storePassword`, `keyAlias`, and `keyPassword`, following the
[Flutter signing guide](https://docs.flutter.dev/deployment/android#sign-the-app).
Keep that file and the keystore private. `:app:validateReleaseSigning` fails when
keys are missing. Trusted `main` CI builds load the persistent identity from
GitHub Secrets, increment `versionCode`, and verify the resulting APK before
uploading the signed artifact. PR builds never receive signing secrets.
[Provisioning, update compatibility and artifact verification](docs/android-release-signing.md).

### Read-only Home Assistant audit

The manual audit uses the real Dart clients and blocks non-GET HTTP requests.
WebSocket operations are restricted to the read/subscription commands in the script.
It does not run device actions or edit the server. Store `baseUrl` and `token` in
an owner-readable JSON file **outside this repository**, then run:

```sh
dart run tool/ha_readonly_audit.dart --config /private/path/ha-readonly.json
```

Alternatively set `HA_URL` and `HA_TOKEN` in your local environment. Output contains
aggregate counts and error classifications; never commit the input file or token.
