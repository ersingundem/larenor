# Third-party notices

Larenor's original code is AGPL-3.0-only. This grant does not replace the
licenses of the components below. Preserve their notices when redistributing
source or application bundles.

| Component | Location / license | Source |
| --- | --- | --- |
| Inter font | `assets/fonts/Inter-Variable.ttf`; [SIL OFL 1.1](assets/fonts/OFL.txt), copyright The Inter Project Authors | [Inter](https://github.com/rsms/inter) |
| noVNC | `assets/console/novnc/`; [upstream license summary](assets/console/novnc/LICENSE.txt), [MPL 2.0 text](assets/console/novnc/docs/LICENSE.MPL-2.0). Individual files retain their additional notices. | [noVNC](https://github.com/novnc/noVNC) |
| pako, included with noVNC | [MIT license](assets/console/novnc/vendor/pako/LICENSE); source-file notices also apply | [pako](https://github.com/nodeca/pako) |
| xterm.js | `assets/console/xterm/`; [MIT license](assets/console/xterm/LICENSE) | [xterm.js](https://github.com/xtermjs/xterm.js) |
| AOSP apksig test fixture | Android host tests only; [provenance and exact source revision](android/app/src/test/resources/updater/NOTICE.md), [Apache 2.0](android/app/src/test/resources/updater/LICENSE.apksig) | [Android apksig](https://android.googlesource.com/platform/tools/apksig/) |

The noVNC source files in this repository are available in source form, including
any Larenor changes recorded in Git. License texts supplied with the source must
also accompany distributed bundles. Vendored files keep their upstream headers;
do not replace them with Larenor's AGPL header.

Flutter/Dart dependencies are versioned in `pubspec.lock`; Android dependencies
are declared in the Gradle build; Server dependencies and hashes are recorded
in `server/uv.lock`. Their upstream package licenses continue to apply. Flutter's
generated license registry covers registered package notices; it is supplemented
by the vendored assets listed here. Transitive native components retain their
own notices and source requirements as provided by their distributions.

Service names and identifying artwork under `assets/brand_icons/` refer to
Jellyfin, Jellyseerr, Sonarr, Radarr, Lidarr, Readarr, Prowlarr, Bazarr, qBittorrent
and Proxmox. These are third-party project marks, not Larenor artwork licensed
under AGPL. Their use identifies configured integrations and does not imply
affiliation or endorsement. A source-code license is not a trademark license.

Home Assistant, CasaOS and the independently deployed media servers are external
services. Larenor does not relicense their source or Docker images. A future fork
will preserve its own upstream license, source provenance and notices; installing
it through Larenor does not change those obligations.
