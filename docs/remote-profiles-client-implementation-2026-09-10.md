# Personal remote target profiles — bounded Client delivery

10 September 2026. Base `origin/main` at task start:
`aee92b49d1855670674efac156a18603c7f38aae`.
Branch `codex/remote-session-profiles` is isolated from main and Keenetic work.

## Delivered behavior

Settings now has a visible **Remote access / Uzak erişim** category in the
existing tablet split view and narrow-window navigation. The existing local
Settings PIN gate protects the panel. Users can create, inspect, edit and
delete personal SSH, RDP or VNC targets. Deletion names the selected target
and requires a separate confirmation; cancelling cannot later reuse the old
confirmation callback. The explicit Copy address action copies only host:port,
with IPv6 brackets. No external application or URI is launched.

A profile contains a random ID, label, closed protocol enum, host, port and
optional username. Defaults are SSH22, RDP3389 and VNC5900; changing protocol
updates a default port while preserving a custom one. Validation accepts
strict dotted-decimal IPv4, IPv6 literals and ASCII DNS/punycode names; it
rejects URL schemes, embedded credentials/ports/paths, whitespace/control
characters, malformed addresses and ports outside1–65535. DNS is not resolved.
DNS case/trailing dot and IPv6 brackets/case are normalized. Unicode domain
conversion and IPv6 zone identifiers are not implemented; the form explicitly
asks for international names in their xn-- representation.

The profile does not contain a password, key, command, certificate exception
or trust decision. Unknown record keys are rejected. There is no SSH/RDP/VNC
session engine in this slice: the details explicitly say the connection was
not tested and in-app sessions are unavailable. Existing Proxmox console and
all HA/Server transports remain unchanged. No remote target is contacted.

## Storage and lifecycle

`RemoteProfilesStore` uses the existing FlutterSecureStorage plugin under the
separate `remote_profiles_private_v1` key, independent of Core/HA/Proxmox.
Profiles are device-personal, not per-Core-account records. The key is not
added to any backup, Vault or export allowlist. Unrelated secure records are
not changed, and no generic secure-store clear/readAll is called.

The envelope is versioned, bounded to32 profiles and32KiB, with unique IDs
and an incrementing revision. Each replacement copies the caller list before
queueing, enters ConfigurationWrites, rereads and compares the exact previous
raw envelope/revision, writes one complete envelope, then requires matching
readback. Corrupt, oversized or unknown data never becomes an empty successful
read or an automatic overwrite. Concurrent edits report a conflict. A storage
exception or different readback reports an unconfirmed save; only explicit
Reload reveals what was persisted, with no automatic write replay. Tests cover
write exceptions both before and after the platform effect. This does not
claim cross-process OS transactions or native Keystore verification.

The panel captures its provider container/store, Settings root/PIN gate and
interaction generation. Route/Ticker, window focus/PiP, native view and app
lifecycle checks fence read, write and copy callbacks. Drafts and visible data
are dropped on observed retirement. Each secure read/write continuation checks
current ownership. A dispatched platform write may already have persisted
before retirement; it is never reported as a new session's success. Successful
and failed refresh publications retire old row callbacks, preventing a removed
or unavailable profile from reappearing through a retained action.

## Validation and evidence

- Initial TDD checkpoint `d510667`:29 model/store scaffold failures plus one
  actual missing Settings-entry failure. Unimplemented API failures establish
  missing behavior, not that all later platform fault paths already executed.
- Actual MethodChannel tests then validated storage effects. Initial missing
  platform-instance reset, a missing dart:ui import, and a test-only Finder
  API mistake were fixture/compile issues, not product bugs.
- `bb6ca0f` retains a real UI refresh regression:10 PASS/1 FAIL; an old row
  could reopen a deleted profile after reload. Successful publication now
  advances its generation. `1bafed6` adds the matching failed-refresh RED;
  error publication now also advances generation and clears busy state.
- One background fixture used an invalid paused→resumed transition; it was
  stopped and reaped, then corrected to Flutter's full lifecycle sequence.
  This was not a runtime product failure. No timeout or assertion was relaxed.
- Six tablet tests: EN/TR ×320/600/1280 at2x, bundled Inter font, light/dark.
  Actual native Tab/Shift-Tab, Space save and Enter cancel; effective single
  button semantics ≥48×48 and visible focus ring. The two private screenshots
  `remote-tr-600-2x.png` and `remote-en-1280-2x.png` were opened and inspected.
  Existing fixed Settings keyboard-order tests now explicitly traverse the
  new category in both directions; their assertions remain strict.
- Final related gate: **221 PASS, 13s**, covering all Settings tests, the new
  profile tests and HomeSession runtime tests. Own focused cases:50, included
  in the related count; earlier49/220 runs are not added to it.
- Analyzer: **5 items, 0 issues**. Formatter:8 owned Dart files; no unrelated
  formatting/refactor. New-module line coverage: **464/491 = 94.50% (Dart lines only)**.

This is a partial REMOTE.COMMON software foundation, not completion of
REMOTE.COMMON/F61/F62/F63. Host-key/certificate trust, credentials, live
terminal/desktop, tunnels, SFTP, Core-managed profiles, reconnect and physical
Android/DeX acceptance remain separate work. No CI, push or PR was created.
Private logs, process outcomes, hashes and final commit are recorded in
`/private/tmp/larenor-remote-profiles-delivery-evidence.json`.
