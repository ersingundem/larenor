# B5.1 automation list closure audit

This audit starts from `origin/main` at `b563586c` and treats queue progress as
**17/125** and selected-feature progress as **0/63**. It does not mark B5.1
complete or claim physical Huawei MatePad, Samsung DeX or TalkBack acceptance.

## Coverage inventory

The merged B5.1 slices already cover dashboard/playback, gallery/music/security,
navigation/Keenetic status, media/Core, kiosk/library/legal, settings panes,
Proxmox, admin editors, HA registry/connection, entities/devices/web panel,
camera/library/metrics, and home sync/local audio/About.

The pending integration preview combines the following independent tablet
packages without conflicts:

| Package | Production surfaces |
| --- | --- |
| #214 | HA integrations, Home Assistant settings and settings navigation |
| #219 | Energy/maintenance, HA tools and website data |
| #220 | Client updates, home source and screen program |
| #221 | Bazarr wanted, Jellyseerr requests and Prowlarr indexers |
| #222 | Ambient settings, intercom settings and window profile |
| #224 | Remote playback, Jellyfin detail and playback power |
| #225 | Keenetic root, Wi-Fi and port forwarding |

The exact temporary preview tree `516391ece43eac95d30a8463bac8c3f8b5e7e89a`
passed **284/284** changed tests, analysis over 45 changed Dart files, EN/TR ARB
JSON validation, queue/security/diff checks and a redacted 52-commit secret scan.
The preview was not pushed and does not include this audit's new source.

The inventory found one uncovered production route: `AutomationsScreen`. Its
JSON editor and pending-flow children were already accepted, but the list route
still used the old page shell, exposed provider exception text and dispatched
captured actions through whichever REST client happened to be current.

## Three acceptance criteria

1. **Tablet and accessibility.** The automation list uses the shared large-title
   service shell and grouped settings hierarchy. EN/TR at 600 and 1200 logical
   pixels with 200% text preserves native 44 dp navigation controls, 48 dp
   content actions, keyboard activation, TalkBack headings and explicit switch
   state.
2. **Truthful state and evidence.** Loading, empty, failure and expired-session
   states are separate live regions. Failure copy never includes provider or
   credential detail. The populated route passively distinguishes a saved HA
   connection, reachable service and current verified read without starting a
   probe.
3. **Exact authority.** Refresh, create, inspect, toggle, run and duplicate bind
   to the exact HA REST/admin clients, interaction epoch, current route and app
   lifecycle. A covered route, replacement account or late completion cannot
   dispatch, retry, navigate or publish an error into the next session.

## Automated evidence and closure order

`automations_tablet_accessibility_test.dart` supplies the EN/TR width matrix,
48 dp content targets, keyboard service dispatch, passive health evidence,
secret-free state grammar and stale account/route rejection. Existing subtitle,
automation editor and admin workflow tests remain the focused regressions.

B5.1 remains in progress. The safe close order is: merge and pass exact CI for
#214, #219, #220, #221, #222, #224 and #225; rebase this automation-list slice
once; run its focused tests and exact PR CI; then run one combined B5.1 source
and signed Android artifact gate. Physical MatePad/DeX/TalkBack checks remain in
the manual release matrix and must not be represented as automated evidence.
